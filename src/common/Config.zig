pub const Config = @This();

arena: heap.ArenaAllocator,
jobs: ArrayList(Program),
parsed: ?Programs,
fingerprint: u64 = 0,

pub const ParsingError = error{
    ParseError,
} || Io.Reader.LimitedAllocError || mem.Allocator.Error || json.ParseError(Job);

pub fn init(gpa: mem.Allocator) Config {
    return .{
        .arena = heap.ArenaAllocator.init(gpa),
        .jobs = ArrayList(Program).empty,
        .parsed = null,
    };
}

fn allocator(self: *Config) mem.Allocator {
    return self.arena.allocator();
}

const Programs = struct { programs: json.ArrayHashMap(Job) };

pub fn parse(config: *Config, file_reader: *Io.Reader) !void {
    if (config.parsed) |_| {
        _ = config.arena.reset(.retain_capacity);
        config.parsed = null;
    }

    const content = try file_reader.allocRemaining(config.allocator(), .unlimited);
    config.parsed = try json.parseFromSliceLeaky(
        Programs,
        config.allocator(),
        content,
        .{},
    );

    var it = config.parsed.?.programs.map.iterator();
    const len = config.parsed.?.programs.map.count();
    try config.jobs.ensureUnusedCapacity(config.allocator(), len);

    while (it.next()) |entry| {
        const program = try Program.createFromJob(config.allocator(), entry.key_ptr.*, entry.value_ptr.*);
        config.jobs.appendAssumeCapacity(program);
    }
}

pub fn getParsed(config: *const Config) []const Program {
    return config.jobs.items[0..];
}

pub fn deinit(self: *Config) void {
    self.arena.deinit();
}

pub const Program = struct {
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
        umask: usize,
    },

    pub fn createFromJob(arena: mem.Allocator, name: []const u8, job: Job) !Program {
        return .{
            .name = try arena.dupe(u8, name),
            .conf = .{ .cmd = blk: {
                if (job.cmd) |defined| {
                    const cmd = try arena.dupe(u8, defined);
                    break :blk cmd;
                } else {
                    return error.ParseError;
                }
            }, .numprocs = blk: {
                if (job.numprocs) |defined| {
                    break :blk defined;
                } else {
                    break :blk 1;
                }
            }, .stdout = blk: {
                if (job.stdout) |defined| {
                    const stdout = try arena.dupe(u8, defined);
                    break :blk stdout;
                } else {
                    const stdout = try arena.dupe(u8, "stdout");
                    break :blk stdout;
                }
            }, .stderr = blk: {
                if (job.stderr) |defined| {
                    const stderr = try arena.dupe(u8, defined);
                    break :blk stderr;
                } else {
                    const stderr = try arena.dupe(u8, "stderr");
                    break :blk stderr;
                }
            }, .autostart = blk: {
                if (job.autostart) |defined| {
                    break :blk defined;
                } else {
                    break :blk true;
                }
            }, .autorestart = blk: {
                if (job.autorestart) |defined| {
                    const restart = AutoRestart.autoRestartFromString(defined) orelse return error.ParseError;
                    break :blk restart;
                } else {
                    break :blk AutoRestart.always;
                }
            }, .exitcodes = blk: {
                if (job.exitcodes) |defined| {
                    var list = std.ArrayListUnmanaged(ExitCode).empty;
                    try list.ensureUnusedCapacity(arena, defined.len);
                    for (defined) |exit_code| {
                        list.appendAssumeCapacity(ExitCode.exitCodeFromInt(exit_code));
                    }
                    break :blk try list.toOwnedSlice(arena);
                } else {
                    var list = std.ArrayListUnmanaged(ExitCode).empty;
                    try list.ensureUnusedCapacity(arena, 1);
                    list.appendAssumeCapacity(ExitCode.exitCodeFromInt(0));
                    break :blk try list.toOwnedSlice(arena);
                }
            }, .starttime = blk: {
                if (job.starttime) |defined| {
                    break :blk defined;
                } else {
                    break :blk 3;
                }
            }, .startretries = blk: {
                if (job.startretries) |defined| {
                    break :blk defined;
                } else {
                    break :blk 3;
                }
            }, .stoptime = blk: {
                if (job.stoptime) |defined| {
                    break :blk defined;
                } else {
                    break :blk 3;
                }
            }, .stopsignal = blk: {
                if (job.stopsignal) |defined| {
                    const signal = Signal.signalFromString(defined) orelse return error.ParseError;
                    break :blk signal;
                } else {
                    break :blk Signal.signalFromString("TERM").?;
                }
            }, .umask = blk: {
                if (job.umask) |defined| {
                    const umask = try std.fmt.parseUnsigned(usize, defined, 8);
                    break :blk umask;
                } else {
                    break :blk 22;
                }
            }, .workingdir = blk: {
                if (job.workingdir) |defined| {
                    const workingdir = try arena.dupe(u8, defined);
                    break :blk workingdir;
                } else {
                    const workingdir = try arena.dupe(u8, "workingdir");
                    break :blk workingdir;
                }
            } },
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            \\Program {{
            \\  name       = {s}
            \\  cmd        = {s}
            \\  numprocs   = {d}
            \\  stdout     = {s}
            \\  stderr     = {s}
            \\  autostart  = {}
            \\  autorestart= {s}
            \\  exitcodes  = {any}
            \\  starttime  = {d}
            \\  startretries= {d}
            \\  stoptime   = {d}
            \\  stopsignal = {s}
            \\  workingdir = {s}
            \\  umask      = {o}
            \\}}
        ,
            .{
                self.name,
                self.conf.cmd,
                self.conf.numprocs,
                self.conf.stdout,
                self.conf.stderr,
                self.conf.autostart,
                self.conf.autorestart.stringFromAutoRestart(),
                self.conf.exitcodes,
                self.conf.starttime,
                self.conf.startretries,
                self.conf.stoptime,
                self.conf.stopsignal.stringFromSignal(),
                self.conf.workingdir,
                self.conf.umask,
            },
        );
    }
};

pub const Job = struct {
    cmd: ?[]const u8 = null,
    numprocs: ?usize = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    autostart: ?bool = null,
    autorestart: ?[]const u8 = null,
    exitcodes: ?[]const i32 = null,
    starttime: ?usize = null,
    startretries: ?usize = null,
    stoptime: ?usize = null,
    stopsignal: ?[]const u8 = null,
    workingdir: ?[]const u8 = null,
    umask: ?[]const u8 = null,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            "Job{{\n cmd={s}\n numprocs={d}\n autostart={}\n autorestart={s}\n stdout={s}\n stderr={s}\n workingdir={s}\n umask={s}\n exitcodes={any}\n starttime={d}\n startretries={d}\n stoptime={d}\n stopsignal={s}\n}}",
            .{
                self.cmd,
                self.numprocs,
                self.autostart,
                self.autorestart,
                self.stdout,
                self.stderr,
                self.workingdir,
                self.umask,
                self.exitcodes,
                self.starttime,
                self.startretries,
                self.stoptime,
                self.stopsignal,
            },
        );
    }
};

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const StringMap = std.StringArrayHashMapUnmanaged;
const EnumSet = std.EnumSet;
const ArrayList = std.ArrayListUnmanaged;
const json = std.json;
const Io = std.Io;
const Signal = @import("process.zig").Signal;
const AutoRestart = @import("process.zig").AutoRestart;
const hash = std.hash;
const ExitCode = @import("process.zig").ExitCode;
