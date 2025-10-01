const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const atomic = std.atomic;
const Logger = @import("common").Logger;

const SignalHandler = @This();

const SignalType = enum {
    sighup,
    sigterm,
    sigint,
    sigchld,
    sigquit,
    sigusr1,
    sigusr2,
};

const SignalFlags = packed struct {
    sighup: bool = false,
    sigterm: bool = false,
    sigint: bool = false,
    sigchld: bool = false,
    sigquit: bool = false,
    sigusr1: bool = false,
    sigusr2: bool = false,
    _padding: u1 = 0,

    pub fn hasAnySignal(self: *const @This()) bool {
        return self.sighup or self.sigterm or self.sigint or
            self.sigchld or self.sigquit or self.sigusr1 or self.sigusr2;
    }

    pub fn clear(self: *@This()) void {
        self.* = .{};
    }

    pub fn fromU8(value: u8) @This() {
        return @bitCast(value);
    }

    pub fn toU8(self: *const @This()) u8 {
        return @bitCast(self.*);
    }
};

logger: *Logger,
flags: atomic.Value(u8),
old_handlers: [7]posix.Sigaction,
initialized: bool,

pub fn init(logger: *Logger) SignalHandler {
    return .{
        .logger = logger,
        .flags = atomic.Value(u8).init(0),
        .old_handlers = std.mem.zeroes([7]posix.Sigaction),
        .initialized = false,
    };
}

pub fn deinit(self: *SignalHandler) void {
    if (self.initialized) {
        self.restoreDefaultHandlers() catch |err| {
            self.logger.err("failed to restore signal handlers: {}", .{err});
        };
    }
}

pub fn setup(self: *SignalHandler) !void {
    if (self.initialized) return;

    const signals = [_]u8{
        @intCast(posix.SIG.HUP),
        @intCast(posix.SIG.TERM),
        @intCast(posix.SIG.INT),
        @intCast(posix.SIG.CHLD),
        @intCast(posix.SIG.QUIT),
        @intCast(posix.SIG.USR1),
        @intCast(posix.SIG.USR2),
    };

    var action = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };

    for (signals, 0..) |sig, i| {
        posix.sigaction(sig, &action, &self.old_handlers[i]);
    }

    self.initialized = true;
    self.logger.info("signal handlers installed for HUP, TERM, INT, CHLD, QUIT, USR1, USR2", .{});
}

fn restoreDefaultHandlers(self: *SignalHandler) !void {
    const signals = [_]u8{
        @intCast(posix.SIG.HUP),
        @intCast(posix.SIG.TERM),
        @intCast(posix.SIG.INT),
        @intCast(posix.SIG.CHLD),
        @intCast(posix.SIG.QUIT),
        @intCast(posix.SIG.USR1),
        @intCast(posix.SIG.USR2),
    };

    for (signals, 0..) |sig, i| {
        _ = posix.sigaction(sig, &self.old_handlers[i], null);
    }

    self.initialized = false;
    self.logger.info("signal handlers restored to defaults", .{});
}

pub fn checkSignals(self: *SignalHandler) SignalFlags {
    const current_u8 = self.flags.load(.acquire);
    const current = SignalFlags.fromU8(current_u8);
    if (current.hasAnySignal()) {
        self.flags.store(0, .release);
        return current;
    }
    return .{};
}

pub fn waitForSignal(self: *SignalHandler, timeout_ms: u32) SignalFlags {
    const start_time = std.time.milliTimestamp();

    while (true) {
        const signals = self.checkSignals();
        if (signals.hasAnySignal()) {
            return signals;
        }

        if (timeout_ms > 0) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= timeout_ms) {
                return .{};
            }
        }

        std.Thread.yield() catch {};
    }
}

fn signalHandler(sig: c_int) callconv(.c) void {

    // We can't access the instance directly in a C signal handler,
    // so we use a global variable. This is not ideal but necessary for signal handling.
    if (global_signal_handler) |handler| {
        const current_u8 = handler.flags.load(.monotonic);
        var current = SignalFlags.fromU8(current_u8);

        // Convert sig to the same type for comparison
        const sig_u8: u8 = @intCast(sig);
        const sighup: u8 = @intCast(posix.SIG.HUP);
        const sigterm: u8 = @intCast(posix.SIG.TERM);
        const sigint: u8 = @intCast(posix.SIG.INT);
        const sigchld: u8 = @intCast(posix.SIG.CHLD);
        const sigquit: u8 = @intCast(posix.SIG.QUIT);
        const sigusr1: u8 = @intCast(posix.SIG.USR1);
        const sigusr2: u8 = @intCast(posix.SIG.USR2);

        if (sig_u8 == sighup) {
            current.sighup = true;
        } else if (sig_u8 == sigterm) {
            current.sigterm = true;
        } else if (sig_u8 == sigint) {
            current.sigint = true;
        } else if (sig_u8 == sigchld) {
            current.sigchld = true;
        } else if (sig_u8 == sigquit) {
            current.sigquit = true;
        } else if (sig_u8 == sigusr1) {
            current.sigusr1 = true;
        } else if (sig_u8 == sigusr2) {
            current.sigusr2 = true;
        }

        handler.flags.store(current.toU8(), .release);
    }
}

// Global variable to allow signal handler to access the instance
var global_signal_handler: ?*SignalHandler = null;

pub fn setGlobalHandler(handler: *SignalHandler) void {
    global_signal_handler = handler;
}

pub fn clearGlobalHandler() void {
    global_signal_handler = null;
}
