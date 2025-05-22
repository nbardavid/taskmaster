const Program = @This();
const std = @import("std");
const Color = @import("color.zig");
const log = @import("log.zig");
const ProcessStatus = @import("process.zig");
const StatusEnum = ProcessStatus.StatusEnum;
const Signal = @import("signal.zig");

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
});

config: ProgramConfig,
process: std.ArrayList(ProcessStatus) = undefined,
hash: u64 = 0,

pub const restartEnum = enum {
    always,
    never,
    unexpected,
};

pub fn cstrFromzstr(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    const cstring = try allocator.alloc(u8, slice.len + 1);
    @memcpy(cstring[0..slice.len], slice);
    cstring[slice.len] = 0;
    return cstring;
}

pub const ProgramConfig = struct {
    name: []const u8,
    cmd: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    workingdir: []const u8,
    numprocs: u32 = 1,
    autostart: bool = false,
    exitcodes: []const i32 = &[_]i32{0},
    autorestart: restartEnum,
    starttime: u32 = 0,
    stoptime: u32 = 0,
    startretries: u32 = 0,
    stopsignal: i32 = 15,
    umask: u32 = 22,
};

pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
    allocator.free(self.config.name);
    allocator.free(self.config.cmd);
    allocator.free(self.config.stdout);
    allocator.free(self.config.stderr);
    allocator.free(self.config.exitcodes);
    allocator.free(self.config.workingdir);
    self.process.deinit();
}

pub fn computeHash(self: *Program) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(self.config.name);
    hasher.update(self.config.cmd);
    hasher.update(self.config.stdout);
    hasher.update(self.config.stdout);
    // self.status.hash = hasher.final();
    return hasher.final();
}

pub fn howManyProcessAre(self: Program, status: StatusEnum) u32 {
    var n: u32 = 0;
    for (self.process.items) |process| {
        if (process.status == status) n += 1;
    }
    return n;
}

pub fn clone(self: Program, allocator: std.mem.Allocator) !Program {
    const new_program: Program = Program{
        .config = ProgramConfig{
            .name = try allocator.dupe(u8, self.config.name),
            .cmd = try allocator.dupe(u8, self.config.cmd),
            .stderr = try allocator.dupe(u8, self.config.stderr),
            .stdout = try allocator.dupe(u8, self.config.stdout),
            .exitcodes = try allocator.dupe(i32, self.config.exitcodes),
            .autostart = self.config.autostart,
            .autorestart = self.config.autorestart,
            .numprocs = self.config.numprocs,
            .starttime = self.config.starttime,
            .startretries = self.config.startretries,
            .stoptime = self.config.stoptime,
            .stopsignal = self.config.stopsignal,
            .umask = self.config.umask,
            .workingdir = self.config.workingdir,
        },
        .process = try self.process.clone(),
    };
    return new_program;
}

pub fn format(
    self: *const Program,
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;

    try writer.print("===== Config =====\n", .{});
    try writer.print("name      : {s}\n", .{self.config.name});
    try writer.print("cmd       : {s}\n", .{self.config.cmd});
    try writer.print("stdout    : {s}\n", .{self.config.stdout});
    try writer.print("stderr    : {s}\n", .{self.config.stderr});
    try writer.print("numprocs  : {d}\n", .{self.config.numprocs});
    try writer.print("autostart : {}\n", .{self.config.autostart});

    try writer.print("exitcodes : ", .{});
    for (self.config.exitcodes, 0..) |code, i| {
        if (i != 0) try writer.print(", ", .{});
        try writer.print("{}", .{code});
    }
    try writer.print("\n", .{});
}

pub fn logIsRunning(self: *Program, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try log.logBuffer("Program: {s} has {d}/{d} process running\n", .{ self.config.name, self.howManyProcessAre(StatusEnum.running), self.config.numprocs });
    for (self.process.items, 0..) |process, i| {
        if (i == self.config.numprocs - 1) {
            try log.logBuffer("╰ ", .{});
        } else {
            try log.logBuffer("├ ", .{});
        }
        if (process.status == StatusEnum.running) {
            try log.logBuffer("#{d}: {s}running{s}\n", .{ i, Color.green, Color.reset });
        } else {
            try log.logBuffer("#{d}: {s}stopped{s}\n", .{ i, Color.red, Color.reset });
        }
    }
}

pub fn ForEachProcess(self: *Program, allocator: std.mem.Allocator, comptime function: fn (*ProcessStatus, std.mem.Allocator, *Program, usize) anyerror!void) !void {
    for (self.process.items, 0..) |*process, i| {
        try function(process, allocator, self, i);
    }
}

pub fn startAllProcess(self: *Program, allocator: std.mem.Allocator) !void {
    if (self.howManyProcessAre(StatusEnum.running) > 0) {
        try log.logBuffer("{s}There are {d} processes still running; stop them before starting new ones.{s}\n", .{ Color.red, self.howManyProcessAre(StatusEnum.running), Color.reset });
        return;
    }
    try log.logBoth("{s}: starting {d} process\n", .{ self.config.name, self.config.numprocs - self.howManyProcessAre(StatusEnum.running) });
    try self.ForEachProcess(allocator, ProcessStatus.startProcess);
}
