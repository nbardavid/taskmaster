const Program = @This();
const std = @import("std");
const Color = @import("color.zig");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub const restartEnum = enum {
    always,
    never,
    unexpected,
};

fn cstrFromzstr(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    const cstring = try allocator.alloc(u8, slice.len + 1);
    @memcpy(cstring[0..slice.len], slice);
    cstring[slice.len] = 0;
    return cstring;
}

pub const ProcessStatus = struct {
    need_restart: bool = false,
    pid: c_int = 0,
    running: bool = false,
    nstart: u32 = 0,
    exitno: c_int = 0,
    stdout_fd: c_int = -1,
    stdin_fd: c_int = -1,

    pub fn needRestart(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !bool {
        _ = allocator;
        _ = nproc;

        if (program.config.autorestart == restartEnum.never)
            return false;
        if (program.config.autorestart == restartEnum.always)
            return true;

        for (program.config.exitcodes) |exitcode| {
            if (exitcode == self.exitno)
                return false;
        }
        return true; //restartEnum.unexpected
    }

    pub fn watchMySelf(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        if (self.need_restart == true) {
            try self.logRestarting(allocator, program, nproc);
            try self.startProcess(allocator, program, nproc);
        }
        if (self.running == false) {
            return;
        }
        const err = c.waitpid(self.pid, &self.exitno, c.WNOHANG);
        if (err == -1) {
            std.debug.print("salope\n", .{});
            return;
        }
        if (err > 0) {
            try self.logExit(allocator, program, nproc);
            self.need_restart = self.needRestart(allocator, program, nproc);

            program.nprocess_running -= 1;
            self.running = false;
        }
    }

    pub fn stopProcess(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        _ = allocator;
        if (self.running == true) {
            _ = c.kill(self.pid, c.SIGTERM);
            try log.time();
            try log.file.print("Sending SIGTERM to {s} #{d}\n", .{ program.config.name, nproc });
        }
    }

    pub fn startProcess(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {

        // Build argv
        var it_cmd = std.mem.tokenizeScalar(u8, program.config.cmd, ' ');

        var argv_list = std.ArrayList(?[*:0]const u8).init(allocator);
        var argv_ptr_list = std.ArrayList([]u8).init(allocator);

        while (it_cmd.next()) |slice| {
            const dup = try allocator.alloc(u8, slice.len + 1);
            @memcpy(dup[0..slice.len], slice);
            dup[slice.len] = 0;
            try argv_list.append(@as([*:0]const u8, @ptrCast(dup.ptr)));
            try argv_ptr_list.append(dup);
        }

        defer {
            for (argv_ptr_list.items) |item| {
                allocator.free(item);
            }
            argv_ptr_list.deinit();
            argv_list.deinit();
        }

        // const null_ptr: [*:0]const u8 = null;
        try argv_list.append(null);
        // ──────────────────────────────────────────────────────────────────────

        const pid = std.c.fork();

        if (pid == 0) {
            const path = @as([*:0]const u8, @ptrCast(argv_list.items[0]));
            const argv = @as([*:null]const ?[*:0]const u8, @ptrCast(argv_list.items.ptr));

            const stderr_filename: []u8 = try cstrFromzstr(allocator, program.config.stderr);
            const stdout_filename: []u8 = try cstrFromzstr(allocator, program.config.stdout);

            const stdout_fd: c_int = c.open(stdout_filename.ptr, c.O_WRONLY | c.O_CREAT, @as(c_int, @intCast(0o664)));
            const stderr_fd: c_int = c.open(stderr_filename.ptr, c.O_WRONLY | c.O_CREAT, @as(c_int, @intCast(0o664)));
            if (stdout_fd == -1 or stderr_fd == -1) {
                std.log.err("cantOpenOutputFiles", .{});
                return error.cantOpenOutputFiles;
            }

            if (std.c.dup2(stdout_fd, std.c.STDOUT_FILENO) == -1 or std.c.dup2(stderr_fd, std.c.STDERR_FILENO) == -1) {
                return error.Dup2Failed;
            }

            // std.log.err("execve failed", .{});
            // std.prin
            _ = std.c.execve(path, argv, std.c.environ);
            std.log.err("execve failed", .{});
            std.process.exit(1);
        }

        self.pid = pid;
        self.nstart += 1;
        self.running = true;
        program.nprocess_running += 1;
        try self.logStart(allocator, program, nproc);
    }

    pub fn logStart(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        _ = self;
        _ = allocator;

        try log.logBoth("{s}[{s}+{s}]{s} #{d} {s}\n", .{
            Color.gray,  Color.green, Color.gray,
            Color.reset, nproc,       program.config.name,
        });
    }
    pub fn logRestarting(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        _ = self;
        _ = allocator;

        try log.logBoth("Restarting {s} #{d}\n", .{ program.config.name, nproc });
    }

    pub fn logExit(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        _ = allocator;

        for (program.config.exitcodes) |exitcode| {
            if (exitcode == self.exitno) {
                try log.logBoth("{s}[{s}-{s}]{s} {s} #{d} {s} has exited successfully with status code {s}{d}{s}\n", .{
                    Color.gray,          Color.red,   Color.gray, Color.reset,
                    program.config.name, nproc,       Color.gray, Color.green,
                    self.exitno,         Color.reset,
                });
                return;
            }
        }
        try log.logBoth("{s}[{s}-{s}]{s} {s} #{d} {s} has exited unexpectedlly with status code {s}{d}{s}\n", .{
            Color.gray,          Color.red,   Color.gray, Color.reset,
            program.config.name, nproc,       Color.gray, Color.red,
            self.exitno,         Color.reset,
        });
    }
};

pub const ProgramConfig = struct {
    name: []const u8,
    cmd: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    numprocs: u32 = 1,
    autostart: bool = false,
    exitcodes: []const i32 = &[_]i32{0},
    autorestart: restartEnum,
};

config: ProgramConfig,
process: std.ArrayList(ProcessStatus) = undefined,
hash: u64 = 0,
nprocess_running: u32 = 0,

pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
    allocator.free(self.config.name);
    allocator.free(self.config.cmd);
    allocator.free(self.config.stdout);
    allocator.free(self.config.stderr);
    allocator.free(self.config.exitcodes);
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

pub fn clone(self: Program, allocator: std.mem.Allocator) !Program {
    const new_program: Program = Program{
        .config = ProgramConfig{
            .name = try allocator.dupe(u8, self.config.name),
            .cmd = try allocator.dupe(u8, self.config.cmd),
            .stderr = try allocator.dupe(u8, self.config.stderr),
            .stdout = try allocator.dupe(u8, self.config.stdout),
            .numprocs = self.config.numprocs,
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
    try log.logBuffer("Program: {s} has {d}/{d} process running\n", .{ self.config.name, self.nprocess_running, self.config.numprocs });
    for (self.process.items, 0..) |process, i| {
        if (i == self.config.numprocs - 1) {
            try log.logBuffer("╰ ", .{});
        } else {
            try log.logBuffer("├ ", .{});
        }
        if (process.running) {
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
    if (self.nprocess_running > 0) {
        try log.logBuffer("{s}There are {d} processes still running; stop them before starting new ones.{s}\n", .{ Color.red, self.nprocess_running, Color.reset });
        return;
    }
    try log.logBoth("{s}: starting {d} process\n", .{ self.config.name, self.config.numprocs - self.nprocess_running });
    try self.ForEachProcess(allocator, ProcessStatus.startProcess);
}
