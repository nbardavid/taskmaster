const ProcessStatus = @This();
const std = @import("std");
const Color = @import("color.zig");
const log = @import("log.zig");
const Program = @import("program.zig");

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub const StatusEnum = enum {
    running,
    starting,
    stopping,
    stopped,
    killed,
};

need_restart: bool = false,
pid: c_int = 0,
status: StatusEnum = StatusEnum.stopped,
// running: bool = false,
// starting: bool = false,

nstart: u32 = 0,
exitno: c_int = 0,
stdout_fd: c_int = -1,
stdin_fd: c_int = -1,
time_since_started: std.time.Timer = undefined,
time_since_stopping: std.time.Timer = undefined,

pub fn needRestart(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !bool {
    _ = allocator;
    _ = nproc;

    if (self.nstart <= program.config.startretries and self.status == StatusEnum.starting) {
        return true;
    }
    if (program.config.autorestart == Program.restartEnum.never)
        return false;
    if (program.config.autorestart == Program.restartEnum.always)
        return true;

    for (program.config.exitcodes) |exitcode| {
        if (exitcode == self.exitno)
            return false;
    }
    return true; //restartEnum.unexpected
}

fn watchStarting(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    if (self.status == StatusEnum.starting and program.config.starttime > 0) {
        const time_in_seconds = self.time_since_started.read() / @as(u64, @intFromFloat(@as(f64, 1_000_000_000.0)));
        if (time_in_seconds >= program.config.starttime) {
            try self.logStart(allocator, program, nproc);
            self.status = StatusEnum.stopped;
            return;
        }
    }
}

fn RestartIfNeeded(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    if (self.need_restart == true) {
        self.need_restart = false;
        try self.logRestarting(allocator, program, nproc);
        try self.startProcess(allocator, program, nproc);
    }
}

fn afterStopped(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    try self.logExit(allocator, program, nproc);
    self.need_restart = try self.needRestart(allocator, program, nproc);

    self.status = StatusEnum.stopped;
}

fn killingIfNeeded(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    if (self.status == StatusEnum.stopping and program.config.stoptime > 0) {
        const time_in_seconds = self.time_since_stopping.read() / @as(u64, @intFromFloat(@as(f64, 1_000_000_000.0)));
        if (time_in_seconds >= program.config.stoptime) {
            try self.goodbye(allocator, program, nproc);
            self.status = StatusEnum.killed;
        }
    }
}

pub fn watchMySelf(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    try self.watchStarting(allocator, program, nproc); //starttime
    try self.RestartIfNeeded(allocator, program, nproc); //autorestart
    try self.killingIfNeeded(allocator, program, nproc);

    if (self.status == StatusEnum.stopped) return;

    const err = c.waitpid(self.pid, &self.exitno, c.WNOHANG);
    if (err == -1) { // waitpid error salope
        std.debug.print("salope\n", .{});
        return;
    }
    if (err > 0) try self.afterStopped(allocator, program, nproc); // if Process is detected as stopped
}

pub fn stopProcess(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    _ = allocator;
    if (self.status == StatusEnum.starting or self.status == StatusEnum.running) {
        _ = c.kill(self.pid, c.SIGTERM);
        try log.time();
        try log.file.print("Sending SIGTERM to {s} #{d}\n", .{ program.config.name, nproc });
        self.status = StatusEnum.stopping;
        self.time_since_stopping = try std.time.Timer.start();
    }
}

pub fn goodbye(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    _ = allocator;
    if (self.status == StatusEnum.stopping) {
        _ = c.kill(self.pid, c.SIGKILL);
        try log.time();
        try log.file.print("Sending SIGKILL to {s} #{d}\n", .{ program.config.name, nproc });
        self.status = StatusEnum.stopped;
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

        const stderr_filename: []u8 = try Program.cstrFromzstr(allocator, program.config.stderr);
        const stdout_filename: []u8 = try Program.cstrFromzstr(allocator, program.config.stdout);

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
    self.time_since_started = try std.time.Timer.start();

    if (program.config.starttime > 0) {
        self.status = StatusEnum.starting;
    } else {
        self.status = StatusEnum.running;
    }
    try self.logStart(allocator, program, nproc);
}

pub fn logStart(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    _ = allocator;

    if (self.status == StatusEnum.starting) {
        try log.logBoth("{s}[{s}~{s}]{s} #{d} {s}\n", .{
            Color.gray,  Color.orange, Color.gray,
            Color.reset, nproc,        program.config.name,
        });
    } else {
        try log.logBoth("{s}[{s}+{s}]{s} #{d} {s}\n", .{
            Color.gray,  Color.green, Color.gray,
            Color.reset, nproc,       program.config.name,
        });
    }
}

pub fn logRestarting(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    _ = self;
    _ = allocator;

    try log.logBoth("Restarting {s} #{d}\n", .{ program.config.name, nproc });
}

pub fn logExit(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
    _ = allocator;

    if (self.status == StatusEnum.starting) {
        try log.logBoth("{s}[{s}-{s}]{s} {s} #{d} {s} has exited on startup with status code {s}{d}{s}\n", .{
            Color.gray,          Color.red,   Color.gray, Color.reset,
            program.config.name, nproc,       Color.gray, Color.red,
            self.exitno,         Color.reset,
        });
        return;
    }

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
