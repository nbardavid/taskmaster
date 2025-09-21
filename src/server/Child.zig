const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const time = std.time;
const Process = @import("Process.zig");
pub const Child = @This();

const Status = enum {
    none,
    stopped,
    starting,
    running,
    stopping,
    exited,
    fatal,
};

pid: ?posix.pid_t,
status: Status,
retries: usize,
last_start_time: u64,
exit_code: ?i32,
stdout_file: ?fs.File,
stderr_file: ?fs.File,

pub fn init() Child {
    return .{
        .pid = null,
        .status = .stopped,
        .retries = 0,
        .last_start_time = 0,
        .exit_code = null,
        .stdout_file = null,
        .stderr_file = null,
    };
}

pub fn start(
    self: *Child,
    cfg: *const Process.Config,
    arena: std.mem.Allocator,
) !void {
    const argv = try buildArgv(cfg.conf.cmd, arena);
    const envp = try buildEnvp(cfg.conf.env, arena);

    const pid = try posix.fork();
    if (pid == 0) {
        try setupWorkingDir(cfg.conf.workingdir);
        try setupUmask(cfg.conf.umask);
        try redirectLogs(cfg, &self.stdout_file, &self.stderr_file);

        posix.execveZ(argv.ptr, argv.ptr, envp.ptr) catch |err| {
            std.debug.print("execve failed: {}\n", .{err});
            posix.exit(127);
        };
    }

    self.pid = pid;
    self.status = .starting;
    self.last_start_time = @intCast(time.milliTimestamp());
    self.exit_code = null;
}

pub fn stop(self: *Child, sig: i32, timeout_ms: usize) !void {
    if (self.pid) |pid| {
        _ = posix.kill(pid, sig) catch |err| switch (err) {
            error.Invalid => return,
            else => return err,
        };

        const start_time = time.milliTimestamp();
        while (true) {
            const waited = posix.waitpid(pid, 0) catch |err| switch (err) {
                error.ChildExited => break,
                error.ChildStillAlive => null,
                else => return err,
            };
            if (waited != null) break;

            if ((time.milliTimestamp() - start_time) > timeout_ms) {
                _ = posix.kill(pid, posix.SIG.KILL) catch {};
                break;
            }
            std.time.sleep(50 * time.ns_per_ms);
        }
    }

    self.status = .stopped;
    self.pid = null;
    self.closeLogs();
}

pub fn kill(self: *Child) void {
    if (self.pid) |pid| {
        _ = posix.kill(pid, posix.SIG.KILL) catch {};
        self.pid = null;
        self.status = .stopped;
        self.closeLogs();
    }
}

pub fn poll(self: *Child) !?i32 {
    if (self.pid) |pid| {
        const result = posix.waitpid(pid, posix.WNOHANG) catch |err| switch (err) {
            error.ChildExited => null,
            error.ChildStillAlive => return null,
            else => return err,
        };
        if (result != null) {
            self.exit_code = result.status;
            self.pid = null;
            self.status = .exited;
            self.closeLogs();
            return self.exit_code;
        }
    }
    return null;
}

pub fn restart(self: *Child, cfg: *const Process.Config, arena: std.mem.Allocator) !void {
    try self.stop(posix.SIG.TERM, cfg.conf.stoptime * 1000);
    try self.start(cfg, arena);
}

fn closeLogs(self: *Child) void {
    if (self.stdout_file) |*f| f.close();
    if (self.stderr_file) |*f| f.close();
    self.stdout_file = null;
    self.stderr_file = null;
}

fn buildArgv(cmd: []const u8, arena: std.mem.Allocator) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(arena);
    defer list.deinit();

    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |token| {
        try list.append(token);
    }
    try list.append("");
    return try list.toOwnedSlice();
}

fn buildEnvp(env: [][]const u8, arena: std.mem.Allocator) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(arena);
    defer list.deinit();

    for (env) |pair| {
        try list.append(pair);
    }

    try list.append("");

    return try list.toOwnedSlice();
}
fn setupWorkingDir(path: []const u8) !void {
    if (path.len == 0) return;
    try std.posix.chdirZ(path);
}

fn setupUmask(mask: usize) !void {
    _ = std.posix.umask(@intCast(mask));
}

fn redirectLogs(cfg: *const Process.Config, out: *?fs.File, err: *?fs.File) !void {
    if (cfg.conf.stdout.len > 0) {
        const file = try std.fs.cwd().createFile(cfg.conf.stdout, .{
            .truncate = false,
            .append = true,
        });
        const fd = file.handle;
        try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
        out.* = file;
    }

    if (cfg.conf.stderr.len > 0) {
        const file = try std.fs.cwd().createFile(cfg.conf.stderr, .{
            .truncate = false,
            .append = true,
        });
        const fd = file.handle;
        try std.posix.dup2(fd, std.posix.STDERR_FILENO);
        err.* = file;
    }
}
