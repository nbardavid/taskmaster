const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const Io = std.Io;
const utils = @import("utils.zig");

pub const Process = @This();

fn redirectFd(redirect: bool, path: ?[:0]const u8, target_fd: i32) !void {
    if (redirect and path != null) {
        const dirname = fs.path.dirname(path.?) orelse ".";
        fs.cwd().makePath(dirname) catch {};
        const fd = try posix.openZ(path.?, posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        defer posix.close(fd);
        try posix.dup2(fd, target_fd);
    } else {
        const fd = try fs.cwd().openFile("/dev/null", .{ .mode = .write_only });
        defer fd.close();
        try posix.dup2(fd.handle, target_fd);
    }
}

pub const ProcessParams = struct {
    stdout_path: ?[:0]const u8 = null,
    stderr_path: ?[:0]const u8 = null,
    redirect_stdout: bool = true,
    redirect_stderr: bool = true,
    working_directory: ?[:0]const u8 = null,
    umask: ?u16 = null,
    path: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8 = null,
};

pid: ?posix.pid_t = null,
state: State = .stopped,
start_time_ns: u64 = 0,
stop_deadline_ns: u64 = 0,
exit_code: ?u8 = null,
exit_signal: ?u8 = null,
failed_start: bool = false,
sent_kill: bool = false,
stop_requested: bool = false,
fatal_logged: bool = false,
retries_count: u32 = 0,
id: u32 = 0,
start_delay_s: u32 = 1,
start_delay_started_ns: u64 = 0,
startsecs: u32 = 1,
stability_start_ns: u64 = 0,
is_stable: bool = false,
backoff_until_ns: u64 = 0,
backoff_delay_s: u32 = 1,

pub fn start(self: *Process, io: Io, exec: ProcessParams) !void {
    if (self.state != .stopped) {
        return error.InvalidState;
    }

    self.exit_code = null;
    self.exit_signal = null;
    self.failed_start = false;
    self.sent_kill = false;
    self.stop_requested = false;
    self.fatal_logged = false;
    self.is_stable = false;

    const pid = try posix.fork();
    if (pid == 0) {
        posix.setpgid(0, 0) catch {};

        if (exec.umask) |m| {
            _ = std.c.umask(m);
        }

        if (exec.working_directory) |wd| {
            posix.chdirZ(wd) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            };
        }

        const stdin_fd = try fs.cwd().openFile("/dev/null", .{ .mode = .read_only });
        defer stdin_fd.close();
        try posix.dup2(stdin_fd.handle, posix.STDIN_FILENO);

        try redirectFd(exec.redirect_stdout, exec.stdout_path, posix.STDOUT_FILENO);
        try redirectFd(exec.redirect_stderr, exec.stderr_path, posix.STDERR_FILENO);

        const envp = exec.envp orelse @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
        posix.execveZ(exec.path, exec.argv, envp) catch {
            std.posix.exit(1);
        };
    } else {
        const now = try utils.timestampNs(io);
        self.pid = pid;
        self.state = .starting;
        self.start_time_ns = now;
        self.start_delay_started_ns = now;
    }
}

pub fn stop(self: *Process, io: Io, sig: u8, timeout_s: u32) !void {
    if (self.state != .running and self.state != .starting) {
        return error.InvalidState;
    }

    self.stop_requested = true;

    if (self.pid) |p| {
        posix.kill(-p, @enumFromInt(sig)) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(p, @enumFromInt(sig)) catch {};
            },
            else => return err,
        };
        const now = try utils.timestampNs(io);
        self.state = .stopping;
        const timeout_ns = @as(u64, @intCast(timeout_s)) * std.time.ns_per_s;
        self.stop_deadline_ns = now + timeout_ns;
    }
}

pub fn sendSignal(self: *Process, signal: u8) !void {
    if (self.state != .running) {
        return error.InvalidState;
    }

    if (self.pid) |p| {
        posix.kill(-p, @enumFromInt(signal)) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(p, @enumFromInt(signal)) catch {};
            },
            else => return err,
        };
    }
}

pub fn kill(self: *Process) !void {
    if (self.state == .exited or self.state == .killed) {
        return error.InvalidState;
    }

    self.stop_requested = true;

    if (self.pid) |p| {
        posix.kill(-p, posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(p, posix.SIG.KILL) catch {};
            },
            else => return err,
        };
        self.state = .killed;
    }
}

pub fn monitor(self: *Process, io: Io) !void {
    const now_ns = try utils.timestampNs(io);

    if (self.state == .starting) {
        if (self.pid) |p| {
            posix.kill(p, @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => {
                    self.failed_start = true;
                    self.state = .exited;
                    self.pid = null;
                    return;
                },
                else => return err,
            };
        }

        const delay_ns = self.start_delay_s * std.time.ns_per_s;
        if (now_ns - self.start_delay_started_ns >= delay_ns) {
            self.state = .running;
            self.stability_start_ns = now_ns;
            if (self.startsecs == 0) {
                self.is_stable = true;
            }
        }
    }

    if (self.state == .running and self.stability_start_ns > 0) {
        const stability_ns = self.startsecs * std.time.ns_per_s;
        if (!self.is_stable and now_ns - self.stability_start_ns >= stability_ns) {
            self.is_stable = true;
        }
    }

    if (self.state == .stopping and now_ns >= self.stop_deadline_ns and !self.sent_kill) {
        try self.kill();
        self.sent_kill = true;
    }

    if (self.pid) |p| {
        const result = posix.waitpid(p, posix.W.NOHANG);
        if (result.pid != 0) {
            const status = result.status;
            if (posix.W.IFEXITED(status)) {
                self.exit_code = posix.W.EXITSTATUS(status);
            } else if (posix.W.IFSIGNALED(status)) {
                self.exit_signal = @as(u8, @intCast(posix.W.TERMSIG(status)));
            }

            if (self.state == .starting) {
                self.failed_start = true;
            }
            if (self.state == .running and !self.is_stable and self.startsecs > 0) {
                self.failed_start = true;
            }

            self.state = .exited;
            self.pid = null;
        }
    }
}

pub fn isAlive(self: *const Process) bool {
    return self.state == .running or self.state == .starting or self.state == .stopping;
}

pub fn isRunning(self: *const Process) bool {
    return self.state == .running;
}

pub fn hasExited(self: *const Process) bool {
    return self.state == .exited or self.state == .killed;
}

pub fn getExitCode(self: *const Process) ?u8 {
    return self.exit_code;
}

pub fn getExitSignal(self: *const Process) ?u8 {
    return self.exit_signal;
}

pub fn reset(self: *Process, keep_retry_count: bool) void {
    self.pid = null;
    self.state = .stopped;
    self.start_time_ns = 0;
    self.stop_deadline_ns = 0;
    self.exit_code = null;
    self.exit_signal = null;
    self.failed_start = false;
    self.sent_kill = false;
    self.stop_requested = false;
    self.fatal_logged = false;
    self.is_stable = false;
    self.start_delay_started_ns = 0;
    self.stability_start_ns = 0;
    self.backoff_until_ns = 0;
    if (!keep_retry_count) {
        self.retries_count = 0;
    }
}

pub fn enterBackoff(self: *Process, io: Io) !void {
    self.state = .backoff;
    const now_ns = try utils.timestampNs(io);
    self.backoff_until_ns = now_ns +% (@as(u64, self.backoff_delay_s) * std.time.ns_per_s);
}

pub fn isBackoffExpired(self: *const Process, io: Io) !bool {
    if (self.state != .backoff) return true;
    const now_ns = try utils.timestampNs(io);
    return now_ns >= self.backoff_until_ns;
}

pub fn getUptime(self: *const Process, io: Io) !u64 {
    if (self.start_time_ns == 0) return 0;
    const now_ns = try utils.timestampNs(io);
    return now_ns - self.start_time_ns;
}

pub const State = enum(u8) {
    none,
    stopped,
    starting,
    running,
    stopping,
    exited,
    killed,
    backoff,
};

test "process start gate timing" {
    const testing_io = std.testing.io;
    var process = Process{ .start_delay_s = 1 };
    const start_time = try utils.timestampNs(testing_io);
    process.start_time_ns = start_time;
    process.start_delay_started_ns = process.start_time_ns;
    process.state = .starting;

    try std.testing.expectEqual(Process.State.starting, process.state);

    try testing_io.sleep(.fromMilliseconds(100), .boot);
    const now_ns = try utils.timestampNs(testing_io);
    const delay_ns = process.start_delay_s * std.time.ns_per_s;
    if (now_ns - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.starting, process.state);

    try testing_io.sleep(.fromMilliseconds(1000), .boot);
    const now_ns2 = try utils.timestampNs(testing_io);
    if (now_ns2 - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process state transitions" {
    var process = Process{};

    try std.testing.expectEqual(Process.State.stopped, process.state);

    process.state = .starting;
    try std.testing.expectEqual(Process.State.starting, process.state);

    process.state = .running;
    try std.testing.expectEqual(Process.State.running, process.state);

    process.state = .stopping;
    try std.testing.expectEqual(Process.State.stopping, process.state);

    process.state = .exited;
    try std.testing.expectEqual(Process.State.exited, process.state);
}

test "process retry counting" {
    var process = Process{};

    try std.testing.expectEqual(@as(u32, 0), process.retries_count);

    process.retries_count += 1;
    try std.testing.expectEqual(@as(u32, 1), process.retries_count);

    process.retries_count = 0;
    try std.testing.expectEqual(@as(u32, 0), process.retries_count);
}

test "process utility functions" {
    var process = Process{};

    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());
    try std.testing.expect(process.getExitCode() == null);
    try std.testing.expect(process.getExitSignal() == null);

    process.state = .running;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(process.isRunning());
    try std.testing.expect(!process.hasExited());

    process.state = .exited;
    process.exit_code = 42;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 42), process.getExitCode().?);

    process.state = .killed;
    process.exit_signal = 9;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 9), process.getExitSignal().?);
}

test "process reset function" {
    var process = Process{};

    process.pid = 12345;
    process.state = .running;
    process.exit_code = 1;
    process.exit_signal = 9;
    process.failed_start = true;
    process.sent_kill = true;

    process.reset(false);

    try std.testing.expect(process.pid == null);
    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expect(process.exit_code == null);
    try std.testing.expect(process.exit_signal == null);
    try std.testing.expect(!process.failed_start);
    try std.testing.expect(!process.sent_kill);
    try std.testing.expect(!process.stop_requested);
    try std.testing.expect(!process.fatal_logged);
    try std.testing.expect(!process.is_stable);
}

test "process state validation" {
    var process = Process{};
    const io = std.testing.io;

    process.state = .running;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(&[_]?[*:0]const u8{null});
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[_]?[*:0]const u8{null});
    try std.testing.expectError(error.InvalidState, process.start(io, .{
        .path = "/bin/true",
        .argv = argv,
        .envp = envp,
    }));

    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.stop(io, @intFromEnum(std.posix.SIG.TERM), 5));

    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.sendSignal(@intFromEnum(std.posix.SIG.USR1)));

    process.state = .exited;
    try std.testing.expectError(error.InvalidState, process.kill());
}

test "process backoff logic" {
    var process = Process{ .backoff_delay_s = 1 };
    const io = std.testing.io;

    try process.enterBackoff(io);
    try std.testing.expectEqual(Process.State.backoff, process.state);
    try std.testing.expect(process.backoff_until_ns > 0);

    try std.testing.expect(!(try process.isBackoffExpired(io)));

    try io.sleep(.fromMilliseconds(100), .boot);
    try std.testing.expect(!(try process.isBackoffExpired(io)));

    try io.sleep(.fromMilliseconds(1100), .boot);
    try std.testing.expect(try process.isBackoffExpired(io));
}

test "process startsecs confirmation" {
    var process = Process{ .start_delay_s = 0, .startsecs = 1 };
    const io = std.testing.io;

    process.state = .starting;
    process.start_delay_started_ns = try utils.timestampNs(io);

    try process.monitor(io);
    try std.testing.expectEqual(Process.State.running, process.state);
    try std.testing.expect(process.stability_start_ns > 0);
    try std.testing.expect(!process.is_stable);

    try io.sleep(.fromMilliseconds(1100), .boot);
    try process.monitor(io);
    try std.testing.expect(process.is_stable);
}

test "process failed_start when exiting before startsecs" {
    var process = Process{ .start_delay_s = 0, .startsecs = 2 };
    const io = std.testing.io;

    const argv = [_]?[*:0]const u8{ "/bin/false", null };
    const envp = [_]?[*:0]const u8{null};

    try process.start(io, .{
        .path = "/bin/false",
        .argv = @ptrCast(&argv),
        .envp = @ptrCast(&envp),
    });

    var i: usize = 0;
    while (i < 50 and process.state != .exited) : (i += 1) {
        try process.monitor(io);
        try io.sleep(.fromMilliseconds(50), .boot);
    }

    try std.testing.expect(process.failed_start);
}

test "process uptime calculation" {
    var process = Process{};

    const io = std.testing.io;
    try std.testing.expectEqual(@as(u64, 0), try process.getUptime(io));

    const start_time = try utils.timestampNs(io);
    process.start_time_ns = @truncate(@abs(start_time));

    try io.sleep(.fromMilliseconds(10), .boot);
    const uptime = try process.getUptime(io);
    try std.testing.expect(uptime > 0);
    try std.testing.expect(uptime < 100 * std.time.ns_per_ms);
}

test "process complete lifecycle" {
    var process = Process{};
    const io = std.testing.io;

    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());

    process.state = .starting;
    process.pid = 12345;
    process.start_time_ns = @truncate(@abs(try utils.timestampNs(io)));
    try std.testing.expect(process.isAlive());
    try std.testing.expect(!process.isRunning());

    process.state = .running;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(process.isRunning());

    process.state = .stopping;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(!process.isRunning());

    process.state = .exited;
    process.exit_code = 0;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    process.state = .killed;
    process.exit_signal = 9;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 9), process.getExitSignal().?);
}

test "process state transitions validation" {
    var process = Process{};

    try std.testing.expectEqual(Process.State.stopped, process.state);
    process.state = .starting;
    try std.testing.expectEqual(Process.State.starting, process.state);

    process.state = .running;
    try std.testing.expectEqual(Process.State.running, process.state);

    process.state = .stopping;
    try std.testing.expectEqual(Process.State.stopping, process.state);

    process.state = .exited;
    try std.testing.expectEqual(Process.State.exited, process.state);

    process.state = .backoff;
    try std.testing.expectEqual(Process.State.backoff, process.state);
}

test "process retry counting and limits" {
    var process = Process{};

    try std.testing.expectEqual(@as(u32, 0), process.retries_count);

    process.retries_count += 1;
    try std.testing.expectEqual(@as(u32, 1), process.retries_count);

    process.retries_count = 0;
    try std.testing.expectEqual(@as(u32, 0), process.retries_count);

    for (0..5) |_| {
        process.retries_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), process.retries_count);
}

test "process start gate timing edge cases" {
    const io = std.testing.io;
    var process = Process{ .start_delay_s = 0 };
    const start_time = try utils.timestampNs(io);
    process.start_time_ns = start_time;
    process.start_delay_started_ns = process.start_time_ns;
    process.state = .starting;

    const now_ns = try utils.timestampNs(io);
    const delay_ns = process.start_delay_s * std.time.ns_per_s;
    if (now_ns - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process start gate timing with longer period" {
    const io = std.testing.io;
    var process = Process{ .start_delay_s = 3 };
    const start_time = try utils.timestampNs(io);
    process.start_time_ns = start_time;
    process.start_delay_started_ns = process.start_time_ns;
    process.state = .starting;

    try io.sleep(.fromSeconds(1), .boot);
    const now_ns = try utils.timestampNs(io);
    const delay_ns = process.start_delay_s * std.time.ns_per_s;
    if (now_ns - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.starting, process.state);

    try io.sleep(.fromSeconds(2), .boot);
    const now_ns2 = try utils.timestampNs(io);
    if (now_ns2 - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process stop timeout and force kill" {
    var process = Process{};
    const io = std.testing.io;
    process.state = .stopping;
    process.stop_deadline_ns = @as(u64, @truncate(@abs(try utils.timestampNs(io)))) + 1000 * std.time.ns_per_ms;

    const now_ns = try utils.timestampNs(io);
    if (now_ns >= process.stop_deadline_ns and !process.sent_kill) {
        process.state = .killed;
        process.sent_kill = true;
    }
    try std.testing.expectEqual(Process.State.stopping, process.state);

    try io.sleep(.fromMilliseconds(1100), .boot);
    const now_ns2 = try utils.timestampNs(io);
    if (now_ns2 >= process.stop_deadline_ns and !process.sent_kill) {
        process.state = .killed;
        process.sent_kill = true;
    }
    try std.testing.expectEqual(Process.State.killed, process.state);
    try std.testing.expect(process.sent_kill);
}

test "process exit code and signal handling" {
    var process = Process{};

    process.exit_code = 42;
    try std.testing.expectEqual(@as(u8, 42), process.getExitCode().?);

    process.exit_signal = 15;
    try std.testing.expectEqual(@as(u8, 15), process.getExitSignal().?);

    process.exit_code = null;
    process.exit_signal = null;
    try std.testing.expect(process.getExitCode() == null);
    try std.testing.expect(process.getExitSignal() == null);
}

test "process backoff edge cases" {
    var process = Process{ .backoff_delay_s = 0 };
    const io = std.testing.io;

    try process.enterBackoff(io);
    try std.testing.expectEqual(Process.State.backoff, process.state);
    try std.testing.expect(try process.isBackoffExpired(io));

    process.backoff_delay_s = 3600;
    try process.enterBackoff(io);
    try std.testing.expectEqual(Process.State.backoff, process.state);
    try std.testing.expect(!try process.isBackoffExpired(io));
}

test "process uptime edge cases" {
    var process = Process{};
    const io = std.testing.io;

    process.start_time_ns = 0;
    try std.testing.expectEqual(@as(u64, 0), try process.getUptime(io));

    process.start_time_ns = 1;
    const uptime = try process.getUptime(io);
    try std.testing.expect(uptime > 0);
}

test "process state consistency" {
    var process = Process{};

    process.state = .running;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(process.isRunning());
    try std.testing.expect(!process.hasExited());

    process.state = .exited;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());

    process.state = .killed;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
}

test "process reset comprehensive" {
    var process = Process{};

    process.pid = 12345;
    process.state = .running;
    process.start_time_ns = 1000;
    process.stop_deadline_ns = 2000;
    process.exit_code = 1;
    process.exit_signal = 9;
    process.failed_start = true;
    process.sent_kill = true;
    process.retries_count = 5;
    process.id = 42;
    process.start_delay_s = 10;
    process.start_delay_started_ns = 3000;
    process.startsecs = 20;
    process.stability_start_ns = 4000;
    process.backoff_until_ns = 5000;
    process.backoff_delay_s = 30;

    process.reset(false);

    try std.testing.expect(process.pid == null);
    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expectEqual(@as(u64, 0), process.start_time_ns);
    try std.testing.expectEqual(@as(u64, 0), process.stop_deadline_ns);
    try std.testing.expect(process.exit_code == null);
    try std.testing.expect(process.exit_signal == null);
    try std.testing.expect(!process.failed_start);
    try std.testing.expect(!process.sent_kill);
    try std.testing.expectEqual(@as(u64, 0), process.start_delay_started_ns);
    try std.testing.expectEqual(@as(u64, 0), process.stability_start_ns);
    try std.testing.expectEqual(@as(u64, 0), process.backoff_until_ns);
}
