pub const Signal = enum(i32) {
    block,
    unblock,
    setmask,
    hup,
    int,
    quit,
    ill,
    trap,
    abrt,
    poll,
    iot,
    emt,
    fpe,
    kill,
    bus,
    segv,
    sys,
    pipe,
    alrm,
    term,
    urg,
    stop,
    tstp,
    cont,
    chld,
    ttin,
    ttou,
    io,
    xcpu,
    xfsz,
    vtalrm,
    prof,
    winch,
    info,
    usr1,
    usr2,

    pub fn signalFromString(string: []const u8) ?Signal {
        return signal_from_string.get(string);
    }

    pub fn stringFromSignal(signal: Signal) []const u8 {
        return @tagName(signal);
    }

    const signal_from_string: std.StaticStringMap(Signal) = .initComptime(&.{
        .{ "HUP", Signal.hup },
        .{ "INT", Signal.int },
        .{ "TRAP", Signal.trap },
        .{ "ABRT", Signal.abrt },
        .{ "IOT", Signal.abrt },
        .{ "EMT", Signal.poll },
        .{ "POLL", Signal.poll },
        .{ "FPE", Signal.fpe },
        .{ "KILL", Signal.kill },
        .{ "BUS", Signal.bus },
        .{ "SEGV", Signal.segv },
        .{ "SYS", Signal.sys },
        .{ "PIPE", Signal.pipe },
        .{ "ALRM", Signal.alrm },
        .{ "TERM", Signal.term },
        .{ "URG", Signal.urg },
        .{ "STOP", Signal.stop },
        .{ "TSTP", Signal.tstp },
        .{ "CONT", Signal.cont },
        .{ "CHLD", Signal.chld },
        .{ "TTIN", Signal.ttin },
        .{ "TTOU", Signal.ttou },
        .{ "IO", Signal.io },
        .{ "XCPU", Signal.xcpu },
        .{ "XFSZ", Signal.xfsz },
        .{ "VTALRM", Signal.vtalrm },
        .{ "PROF", Signal.prof },
        .{ "WINCH", Signal.winch },
        .{ "INFO", Signal.info },
        .{ "USR1", Signal.usr1 },
        .{ "USR2", Signal.usr2 },
    });

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.stringFromSignal()});
    }
};

pub const ExitCode = enum(i32) {
    _,

    pub fn exitCodeFromInt(number: anytype) ExitCode {
        return @enumFromInt(@as(i32, @intCast(number)));
    }

    pub fn intFromExitCode(code: ExitCode) i32 {
        return @as(i32, @intFromEnum(code));
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("exit code : {d}", .{self.intFromExitCode()});
    }
};

pub const AutoRestart = enum(u8) {
    always = 0,
    never = 1,
    unexpected = 2,

    pub fn autoRestartFromString(string: []const u8) ?AutoRestart {
        if (std.mem.eql(u8, "always", string)) {
            return .always;
        }
        if (std.mem.eql(u8, "never", string)) {
            return .never;
        }
        if (std.mem.eql(u8, "unexpected", string)) {
            return .unexpected;
        }
        return null;
    }

    pub fn stringFromAutoRestart(autorestart: AutoRestart) []const u8 {
        return @tagName(autorestart);
    }
};

pub const Process = struct {
    config: Program,
    fingerprint: u64,

    pub fn init(config: *const Program, gpa: mem.Allocator, fingerprint: u64) !Process {
        const cloned = try config.clone(gpa);
        return .{
            .config = cloned,
            .fingerprint = fingerprint,
        };
    }
};

const std = @import("std");
const mem = std.mem;
const Program = @import("Config.zig").Program;
