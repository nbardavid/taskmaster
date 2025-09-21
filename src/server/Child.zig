const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const time = std.time;
const Process = @import("Process.zig");

pub const Child = @This();

const Status = enum {
    stopped,
    starting,
    running,
    stopping,
    exited,
    backoff,
    fatal,
};

pid: ?posix.pid_t = null,
status: Status = .stopped,
retries: usize = 0,
last_start_time: u64 = 0,
backoff_until: ?u64 = null,
exit_code: ?u32 = null,
exit_signal: ?u32 = null,

pub fn init() Child {
    return .{};
}

pub fn start(
    self: *Child,
    cfg: *const Process.Config,
    arena: std.mem.Allocator,
) !void {
    const now = time.milliTimestamp();
    if (self.status == .backoff) {
        if (self.backoff_until) |until| {
            if (now < until) return error.BackoffActive;
        }
    }

    std.debug.print("[child.start] cmd={s}\n", .{cfg.conf.cmd});
    for (cfg.conf.env) |e| {
        std.debug.print("[child.start] env={s}\n", .{e});
    }

    const argv = try buildArgv(cfg.conf.cmd, arena);
    const envp = try buildEnvp(cfg.conf.env, arena);

    std.debug.print("[child.start] argv[0]={s}\n", .{argv.ptr[0].?});

    const pid = try posix.fork();
    if (pid == 0) {
        std.debug.print("[child.start] in child, about to setup wd/umask/logs\n", .{});
        if (cfg.conf.workingdir.len > 0) {
            std.debug.print("[child.start] workingdir={s}\n", .{cfg.conf.workingdir});
        }
        try setupWorkingDir(cfg.conf.workingdir);
        std.debug.print("[child.start] umask={d}\n", .{cfg.conf.umask});
        try setupUmask(cfg.conf.umask);
        try redirectLogs(cfg);

        std.debug.print("[child.start] execveZ path={s}\n", .{argv.ptr[0].?});
        const e = posix.execveZ(argv.ptr[0].?, argv.ptr, envp.ptr);
        {
            std.debug.print("execve failed: {any}\n", .{e});
            std.posix.exit(127);
        }
    }

    self.pid = pid;
    self.status = .starting;
    self.last_start_time = @intCast(now);
    self.exit_code = null;
    self.exit_signal = null;
    self.backoff_until = null;
}

fn buildArgv(cmd: []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    std.debug.print("[buildArgv] cmd={s}\n", .{cmd});
    var tokens = std.mem.tokenizeScalar(u8, cmd, ' ');
    var count: usize = 0;
    while (tokens.next()) |_| count += 1;
    std.debug.print("[buildArgv] token count={d}\n", .{count});

    const argv = try arena.allocSentinel(?[*:0]u8, count, null);

    tokens = std.mem.tokenizeScalar(u8, cmd, ' ');
    var i: usize = 0;
    while (tokens.next()) |t| {
        argv[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{t}, 0);
        std.debug.print("[buildArgv] argv[{d}]={s}\n", .{ i, argv[i].? });
        i += 1;
    }
    return argv;
}

fn buildEnvp(env: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    const envp = try arena.allocSentinel(?[*:0]u8, env.len, null);
    for (env, 0..) |pair, i| {
        envp[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{pair}, 0);
        std.debug.print("[buildEnvp] envp[{d}]={s}\n", .{ i, envp[i].? });
    }
    return envp;
}

fn setupWorkingDir(path: []const u8) !void {
    if (path.len == 0) return;
    std.debug.print("[setupWorkingDir] chdir to {s}\n", .{path});
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    @memset(buf[0..], 0x00);
    @memcpy(buf[0..path.len :0], path);
    try std.posix.chdirZ(buf[0..path.len :0]);
}

fn setupUmask(mask: usize) !void {
    std.debug.print("[setupUmask] umask={d}\n", .{mask});
    _ = std.c.umask(@intCast(mask));
}

fn redirectLogs(cfg: *const Process.Config) !void {
    if (cfg.conf.stdout.len > 0) {
        std.debug.print("[redirectLogs] stdout path={s}\n", .{cfg.conf.stdout});
        const file = try std.fs.cwd().createFile(cfg.conf.stdout, .{ .truncate = false });
        const fd = file.handle;
        try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
        file.close();
    }

    if (cfg.conf.stderr.len > 0) {
        std.debug.print("[redirectLogs] stderr path={s}\n", .{cfg.conf.stderr});
        const file = try std.fs.cwd().createFile(cfg.conf.stderr, .{ .truncate = false });
        const fd = file.handle;
        try std.posix.dup2(fd, std.posix.STDERR_FILENO);
        file.close();
    }
}

pub fn stop(self: *Child, sig: i32, timeout_ms: usize) !void {
    if (self.pid) |pid| {
        self.status = .stopping;

        _ = posix.kill(pid, @intCast(sig)) catch |err| switch (err) {
            error.PermissionDenied, error.ProcessNotFound, error.Unexpected => {
                self.finalizeExit(null, null);
                return;
            },
            else => return err,
        };

        const t0 = time.milliTimestamp();
        while (true) {
            const res = posix.waitpid(pid, posix.W.NOHANG);
            if (res.pid != 0) {
                const exit = decodeWaitStatus(res.status);
                self.finalizeExit(exit.code, exit.signal);
                return;
            }
            if ((time.milliTimestamp() - t0) > timeout_ms) break;
            std.Thread.sleep(50 * time.ns_per_ms);
        }

        _ = posix.kill(pid, posix.SIG.KILL) catch {};
        const kill_deadline = time.milliTimestamp() + 1500;
        while (true) {
            const res2 = posix.waitpid(pid, posix.W.NOHANG);
            if (res2.pid != 0) {
                const exit = decodeWaitStatus(res2.status);
                self.finalizeExit(exit.code, exit.signal);
                return;
            }
            if (time.milliTimestamp() > kill_deadline) break;
            std.Thread.sleep(20 * time.ns_per_ms);
        }
    }

    self.finalizeExit(null, null);
}

pub fn kill(self: *Child) void {
    if (self.pid) |pid| {
        _ = posix.kill(pid, posix.SIG.KILL) catch {};
    }
    self.finalizeExit(null, null);
}

pub fn poll(self: *Child) !?void {
    if (self.pid) |pid| {
        const res = posix.waitpid(pid, posix.W.NOHANG) catch |err| switch (err) {
            error.NoChildProcesses, error.ProcessNotFound => {
                self.finalizeExit(null, null);
                return {};
            },
            error.ChildStillAlive => return null,
            else => return err,
        };
        if (res.pid != 0) {
            const exit = decodeWaitStatus(res.status);
            self.finalizeExit(exit.code, exit.signal);
            return {};
        }
    }
    return null;
}

pub fn restart(self: *Child, cfg: *const Process.Config, arena: std.mem.Allocator) !void {
    const now = time.milliTimestamp();
    self.retries += 1;

    if (self.retries >= 3 and (now - self.last_start_time) < 5000) {
        self.status = .backoff;
        self.backoff_until = now + 10_000;
        return;
    }

    try self.stop(posix.SIG.TERM, cfg.conf.stoptime * 1000);
    try self.start(cfg, arena);
}

fn finalizeExit(self: *Child, exit_code: ?u32, exit_signal: ?u32) void {
    self.pid = null;
    self.exit_code = exit_code;
    self.exit_signal = exit_signal;
    self.status = .exited;
}

fn decodeWaitStatus(status: u32) struct { code: ?u32, signal: ?u32 } {
    if (posix.W.IFEXITED(status)) {
        return .{ .code = posix.W.EXITSTATUS(status), .signal = null };
    } else if (posix.W.IFSIGNALED(status)) {
        return .{ .code = null, .signal = posix.W.TERMSIG(status) };
    } else {
        return .{ .code = null, .signal = null };
    }
}
