pub const Process = @This();

arena: heap.ArenaAllocator,
config: Config,
fingerprint: ?u64,
instances: []Child,
retries: usize = 0,
backoff_until: ?u64 = null,
logger: *Logger,

pub fn init(self: *Process, gpa: mem.Allocator, logger: *Logger) void {
    self.* = .{
        .arena = heap.ArenaAllocator.init(gpa),
        .config = undefined,
        .fingerprint = null,
        .instances = &.{},
        .retries = 0,
        .backoff_until = null,
        .logger = logger,
    };
}

pub fn create(gpa: mem.Allocator, logger: *Logger) !*Process {
    const self = try gpa.create(Process);
    self.init(gpa, logger);
    return self;
}

pub fn destroy(self: *Process, gpa: mem.Allocator) void {
    self.deinit();
    gpa.destroy(self);
}

pub fn currentStatus(self: *Process) Status {
    var all_stopped = true;
    var all_exited = true;

    for (self.instances) |*inst| {
        switch (inst.status) {
            .fatal => return .fatal,
            .running => return .running,
            .backoff => return .backoff,
            .stopped => {},
            .exited => {},
            else => {
                all_stopped = false;
                all_exited = false;
            },
        }
        if (inst.status != .stopped) all_stopped = false;
        if (inst.status != .exited) all_exited = false;
    }

    if (all_stopped) {
        return .stopped;
    }

    if (all_exited and self.config.conf.autorestart == .never) {
        return .exited;
    }

    return .none;
}

pub fn startAll(self: *Process) !void {
    const logger = self.logger;
    const now = time.milliTimestamp();
    if (self.backoff_until) |until| {
        if (now < until) return error.BackoffActive;
    }

    const arena = self.arena.allocator();
    for (self.instances) |*inst| {
        // Only start instances that are stopped or in fatal state
        if (inst.status == .stopped or inst.status == .fatal) {
            try inst.start(&self.config, arena);
        }
    }

    logger.info("process {s}: started all children", .{self.config.name});
}

pub fn stopAll(self: *Process) !void {
    const logger = self.logger;
    for (self.instances) |*inst| {
        if (inst.pid != null) {
            try inst.stop(@intFromEnum(self.config.conf.stopsignal), self.config.conf.stoptime * 1000);
        }
    }

    logger.info("process {s}: stopped all children", .{self.config.name});
}

pub fn restartAll(self: *Process) !void {
    try self.stopAll();
    try self.startAll();
    log.info("process {s}: restarted all children", .{self.config.name});
}

// Process-level backoff removed - handled at child level now

pub fn resetRetriesIfStable(self: *Process) void {
    const now = time.milliTimestamp();
    for (self.instances) |*inst| {
        if (inst.status == .running and
            (now - inst.last_start_time) >= (self.config.conf.starttime * 1000))
        {
            self.retries = 0;
            inst.retries = 0;
        }
    }
}

pub fn hash(self: *Process) u64 {
    if (self.fingerprint) |fp| return fp;

    var hasher = std.hash.Wyhash.init(0);
    const c = &self.config.conf;
    const ar = c.autorestart.stringFromAutoRestart();
    const sig = c.stopsignal.stringFromSignal();

    hasher.update(self.config.name);
    hasher.update(std.mem.asBytes(&c.numprocs));
    hasher.update(std.mem.asBytes(&c.autostart));
    hasher.update(std.mem.asBytes(&c.starttime));
    hasher.update(std.mem.asBytes(&c.startretries));
    hasher.update(std.mem.asBytes(&c.stoptime));
    hasher.update(std.mem.asBytes(&c.umask));
    hasher.update(c.cmd);
    hasher.update(c.stdout);
    hasher.update(c.stderr);
    hasher.update(c.workingdir);
    hasher.update(ar);
    hasher.update(sig);

    for (c.exitcodes) |ec| {
        const v: i32 = ExitCode.intFromExitCode(ec);
        hasher.update(std.mem.asBytes(&v));
    }

    for (c.env) |entry| {
        hasher.update(entry);
    }

    const fp = hasher.final();
    self.fingerprint = fp;
    return fp;
}

pub fn deinit(self: *Process) void {
    for (self.instances) |*inst| {
        if (inst.pid != null) {
            inst.kill();
        }
    }
    defer self.* = undefined;
    self.arena.deinit();
}

pub fn isExpectedExitCode(self: *Process, code: u32) bool {
    const ecode = ExitCode.exitCodeFromInt(code);
    return for (self.config.conf.exitcodes) |c| {
        break c == ecode;
    } else false;
}

pub fn configure(self: *Process, process_name: []const u8, process_config: *RawProcessConfig) !void {
    _ = self.arena.reset(.free_all);
    self.fingerprint = null;
    const arena = self.arena.allocator();

    const cmd = process_config.cmd orelse return error.MissingCommand;
    const name = try arena.dupe(u8, process_name);
    const cmd_copy = try arena.dupe(u8, cmd);
    const stdout_copy = try arena.dupe(u8, process_config.stdout orelse "/dev/null");
    const stderr_copy = try arena.dupe(u8, process_config.stderr orelse "/dev/null");
    const wd_copy = try arena.dupe(u8, process_config.workingdir orelse ".");
    const numprocs = process_config.numprocs orelse 1;
    const autostart = process_config.autostart orelse false;
    const starttime = process_config.starttime orelse 1;
    const startretries = process_config.startretries orelse 3;
    const stoptime = process_config.stoptime orelse 5;
    const umask_val = if (process_config.umask) |u|
        try std.fmt.parseInt(usize, u, 10)
    else
        0o022;

    const autorestart = AutoRestart.autoRestartFromString(
        process_config.autorestart orelse "unexpected",
    ) orelse .unexpected;

    const stopsignal = Signal.signalFromString(process_config.stopsignal orelse "TERM") orelse .term;

    var exitcodes_slice: []ExitCode = &.{};
    if (process_config.exitcodes) |raw_list| {
        var tmp = try arena.alloc(ExitCode, raw_list.len);
        for (raw_list, 0..) |val, i| {
            tmp[i] = ExitCode.exitCodeFromInt(val);
        }
        exitcodes_slice = tmp;
    }

    var env_slice: [][]const u8 = &.{};
    if (process_config.env) |map| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.ensureUnusedCapacity(arena, map.map.count());
        var it = map.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ key, val });
            list.appendAssumeCapacity(pair);
        }
        env_slice = list.items;
    }

    self.config = .{
        .name = name,
        .conf = .{
            .cmd = cmd_copy,
            .numprocs = numprocs,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .autostart = autostart,
            .autorestart = autorestart,
            .exitcodes = exitcodes_slice,
            .starttime = starttime,
            .startretries = startretries,
            .stoptime = stoptime,
            .stopsignal = stopsignal,
            .workingdir = wd_copy,
            .env = env_slice,
            .umask = umask_val,
        },
    };

    self.instances = try arena.alloc(Child, numprocs);
    for (self.instances) |*inst| {
        inst.* = Child.init(self.logger);
    }
}

pub const Config = struct {
    name: []const u8,
    conf: struct {
        cmd: []const u8,
        numprocs: usize,
        stdout: []const u8,
        stderr: []const u8,
        autostart: bool,
        autorestart: AutoRestart,
        exitcodes: []ExitCode,
        starttime: usize,
        startretries: usize,
        stoptime: usize,
        stopsignal: Signal,
        workingdir: []const u8,
        env: []const []const u8,
        umask: usize,
    },
};

pub const Status = enum {
    none,
    stopped,
    starting,
    running,
    stopping,
    backoff,
    exited,
    fatal,
};

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

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const process = std.process;
const time = std.time;
const log = std.log;

const common = @import("common");
const ParsedConfig = common.Config;
const RawProcess = common.RawProcess;
const RawProcessConfig = common.RawProcessConfig;
const Child = @import("Child.zig").Child;
const Logger = common.Logger;
