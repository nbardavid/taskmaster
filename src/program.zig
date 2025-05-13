const Program = @This();
const std = @import("std");
const Color = @import("color.zig");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

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

    pub fn watchMySelf(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
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
            program.nprocess_running -= 1;
            self.running = false;
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
            std.debug.print("argv:\n", .{});
            var i: usize = 0;
            while (argv_list.items[i] != null) : (i += 1) {
                std.debug.print("  argv[{d}] = '{?s}'\n", .{ i, argv_list.items[i] });
            }

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

        try log.time();
        std.debug.print("{s}[{s}+{s}]{s} #{d} {s}\n", .{
            Color.gray,  Color.green, Color.gray,
            Color.reset, nproc,       program.config.name,
        });
    }

    pub fn logExit(self: *ProcessStatus, allocator: std.mem.Allocator, program: *Program, nproc: usize) !void {
        _ = allocator;

        try log.time();
        std.debug.print("{s}[{s}-{s}]{s} {s} #{d} {s} has exited with status code {s}{d}{s}\n", .{
            Color.gray,          Color.red,   Color.gray, Color.reset,
            program.config.name, nproc,       Color.gray, Color.green,
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
};

config: ProgramConfig,
process: std.ArrayList(ProcessStatus) = undefined,
hash: u64 = 0,
nprocess_running: u32 = 0,

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

pub fn format(self: *const Program, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    try writer.print("===== Config =====\n", .{});
    try writer.print("name: {s}\ncmd: {s}\nstdout: {s}\nstderr: {s}\n", .{ self.config.name, self.config.cmd, self.config.stdout, self.config.stderr });
    // try writer.print("===== Status =====\n", .{});
    // try writer.print(
    //     \\hash: {d}
    //     \\need_restart: {}
    //     \\pid: {d}
    //     \\running: {}
    //     \\nstart: {}
    //     \\exitno: {d}
    //     \\stdout_fd: {d}
    //     \\stdin_fd: {d}
    //     \\
    // ,
    //     .{
    //         self.status.hash,
    //         self.status.need_restart,
    //         self.status.pid,
    //         self.status.running,
    //         self.status.nstart,
    //         self.status.exitno,
    //         self.status.stdout_fd,
    //         self.status.stdin_fd,
    //     },
    // );
}

pub fn logProgramStart(self: Program, nproc: u32) void {
    std.log.info("{s}[{s}+{s}]{s} {s}:{d}", .{
        Color.gray,  Color.green,      Color.gray,
        Color.reset, self.config.name, nproc,
    });
}

pub fn logIsRunning(self: *Program, allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("Program: {s} has {d}/{d} process running\n", .{ self.config.name, self.nprocess_running, self.config.numprocs });
    for (self.process.items, 0..) |process, i| {
        if (i == self.config.numprocs - 1) {
            std.debug.print("╰ ", .{});
        } else {
            std.debug.print("├ ", .{});
        }
        if (process.running) {
            std.debug.print("#{d}: {s}running{s}\n", .{ i, Color.green, Color.reset });
        } else {
            std.debug.print("#{d}: {s}stopped{s}\n", .{ i, Color.red, Color.reset });
        }
    }
}

pub fn ForEachProcess(self: *Program, allocator: std.mem.Allocator, comptime function: fn (*ProcessStatus, std.mem.Allocator, *Program, usize) anyerror!void) !void {
    for (self.process.items, 0..) |*process, i| {
        try function(process, allocator, self, i);
    }
}

pub fn startAllProcess(self: *Program, allocator: std.mem.Allocator) !void {
    try log.time();
    try log.file.print("{s}: starting {d} process\n", .{ self.config.name, self.config.numprocs });
    // std.debug.print("{s}: starting {d} process\n", .{ self.config.name, self.config.numprocs });
    try self.ForEachProcess(allocator, ProcessStatus.startProcess);
}
