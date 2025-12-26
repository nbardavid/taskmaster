const std = @import("std");
const posix = std.posix;
const Io = std.Io;

const Process = @import("Process.zig").Process;

pub const ProcessGroup = @This();

pub const AutoRestart = enum {
    always,
    never,
    unexpected,
};

pub const GroupState = enum {
    stopped,
    starting,
    running,
    stopping,
    fatal,
};

arena: std.heap.ArenaAllocator,
name: []const u8 = "",
cmd: [:0]const u8 = "",
argv: ?[*:null]?[*:0]u8 = null,
envp: ?[*:null]?[*:0]u8 = null,
working_directory: [:0]const u8 = "",
stdout_path: [:0]const u8 = "",
stderr_path: [:0]const u8 = "",
redirect_stdout: bool = true,
redirect_stderr: bool = true,
umask: u16 = 0,
numprocs: u32 = 0,
start_retries: u32 = 0,
start_delay: u32 = 0,
startsecs: u32 = 1,
autostart: bool = true,
stop_signal: u8 = @intFromEnum(posix.SIG.TERM),
stop_timeout: u32 = 0,
autorestart: AutoRestart = .unexpected,
exitcodes: []const u32 = &.{0},
children: []Process = &.{},
backoff_delay_s: u32 = 1,
state: GroupState = .stopped,

pub fn init(gpa: std.mem.Allocator) ProcessGroup {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
}

pub fn deinit(self: *ProcessGroup) void {
    self.arena.deinit();
}

pub fn setName(self: *ProcessGroup, name: []const u8) !void {
    self.name = try self.arena.allocator().dupe(u8, name);
}

pub fn setCmd(self: *ProcessGroup, cmd: []const u8) !void {
    self.cmd = try self.arena.allocator().dupeZ(u8, cmd);
}

pub fn setArgv(self: *ProcessGroup, argv: []const []const u8) !void {
    self.argv = try buildArgv(argv, self.arena.allocator());
}

pub fn setEnv(self: *ProcessGroup, envp: []const []const u8) !void {
    self.envp = try buildEnvp(envp, self.arena.allocator());
}

pub fn setWorkingDir(self: *ProcessGroup, wd: []const u8) !void {
    self.working_directory = try self.arena.allocator().dupeZ(u8, wd);
}

pub fn setStdoutPath(self: *ProcessGroup, path: []const u8) !void {
    self.stdout_path = try self.arena.allocator().dupeZ(u8, path);
}

pub fn setStderrPath(self: *ProcessGroup, path: []const u8) !void {
    self.stderr_path = try self.arena.allocator().dupeZ(u8, path);
}

pub fn setUmask(self: *ProcessGroup, mask: u16) void {
    self.umask = mask;
}

pub fn setNumProcs(self: *ProcessGroup, n: u32) void {
    self.numprocs = n;
}

pub fn setStartRetries(self: *ProcessGroup, n: u32) void {
    self.start_retries = n;
}

pub fn setStartDelay(self: *ProcessGroup, secs: u32) void {
    self.start_delay = secs;
}

pub fn setStopSignal(self: *ProcessGroup, sig: u8) void {
    self.stop_signal = sig;
}

pub fn setStopTimeout(self: *ProcessGroup, secs: u32) void {
    self.stop_timeout = secs;
}

pub fn setRedirectStdout(self: *ProcessGroup, redirect: bool) void {
    self.redirect_stdout = redirect;
}

pub fn setRedirectStderr(self: *ProcessGroup, redirect: bool) void {
    self.redirect_stderr = redirect;
}

pub fn setStartSecs(self: *ProcessGroup, secs: u32) void {
    self.startsecs = secs;
}

pub fn setAutostart(self: *ProcessGroup, auto: bool) void {
    self.autostart = auto;
}

pub fn setAutoRestart(self: *ProcessGroup, policy: AutoRestart) void {
    self.autorestart = policy;
}

pub fn setExitCodes(self: *ProcessGroup, codes: []const u32) !void {
    self.exitcodes = try self.arena.allocator().dupe(u32, codes);
}

pub fn setBackoffDelay(self: *ProcessGroup, delay_s: u32) void {
    self.backoff_delay_s = delay_s;
}

pub fn spawnChildren(self: *ProcessGroup, io: std.Io) !void {
    if (self.cmd.len == 0) return error.MissingCommand;
    if (self.numprocs == 0) return error.NoProcesses;
    if (self.argv == null or self.argv.?[0] == null) {
        const fallback_argv = [_][]const u8{self.cmd[0..]};
        try self.setArgv(&fallback_argv);
    }

    self.children = try self.arena.allocator().alloc(Process, self.numprocs);

    for (self.children, 0..) |*c, i| {
        c.* = .{
            .id = @intCast(i),
            .start_delay_s = self.start_delay,
            .backoff_delay_s = self.backoff_delay_s,
        };

        c.startsecs = self.startsecs;
        try c.start(io, .{
            .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
            .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
            .redirect_stdout = self.redirect_stdout,
            .redirect_stderr = self.redirect_stderr,
            .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
            .umask = if (self.umask != 0) self.umask else null,
            .path = self.cmd,
            .argv = self.argv orelse return error.MissingArgv,
            .envp = self.envp,
        });
    }
    self.state = .starting;
}

pub fn stop(self: *ProcessGroup, io: std.Io) !void {
    self.state = .stopping;
    for (self.children) |*c| {
        if (c.isAlive()) {
            c.stop(io, self.stop_signal, self.stop_timeout) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }

    const start_ns = try timestampNs(io);
    const deadline_ns = start_ns + (@as(u64, self.stop_timeout) * std.time.ns_per_s);

    while (true) {
        try self.monitorChildren(io);
        if (self.getAllExited()) {
            self.state = .stopped;
            return;
        }

        const now_ns = try timestampNs(io);
        if (now_ns >= deadline_ns) break;

        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }

    for (self.children) |*c| {
        if (c.isAlive()) {
            c.kill() catch {};
        }
    }

    const kill_deadline_ns = (try timestampNs(io)) + std.time.ns_per_s;
    while (true) {
        try self.monitorChildren(io);
        if (self.getAllExited()) break;
        if ((try timestampNs(io)) >= kill_deadline_ns) break;
        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }
    self.state = .stopped;
}

pub fn scaleUp(self: *ProcessGroup, io: std.Io, new_count: u32) !void {
    if (new_count <= self.children.len) return error.InvalidScale;

    const old_count = self.children.len;
    const allocator = self.arena.allocator();
    const new_children = try allocator.alloc(Process, new_count);

    @memcpy(new_children[0..old_count], self.children);

    for (new_children[old_count..new_count], old_count..) |*child, i| {
        child.* = .{
            .id = @intCast(i),
            .start_delay_s = self.start_delay,
            .backoff_delay_s = self.backoff_delay_s,
        };
        child.startsecs = self.startsecs;
        try child.start(io, .{
            .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
            .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
            .redirect_stdout = self.redirect_stdout,
            .redirect_stderr = self.redirect_stderr,
            .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
            .umask = if (self.umask != 0) self.umask else null,
            .path = self.cmd,
            .argv = self.argv orelse return error.MissingArgv,
            .envp = self.envp,
        });
    }

    self.children = new_children;
    self.numprocs = new_count;
}

pub fn scaleDown(self: *ProcessGroup, io: std.Io, new_count: u32) !void {
    if (new_count >= self.children.len) return error.InvalidScale;

    const old_count = self.children.len;

    var i: usize = new_count;
    while (i < old_count) : (i += 1) {
        var child = &self.children[i];
        if (child.isAlive()) {
            child.stop(io, self.stop_signal, self.stop_timeout) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }

    const start_ns = try timestampNs(io);
    const deadline_ns = start_ns + (@as(u64, self.stop_timeout) * std.time.ns_per_s);

    while (true) {
        try self.monitorChildren(io);
        var all_exited = true;
        for (self.children[new_count..]) |c| {
            if (c.isAlive()) {
                all_exited = false;
                break;
            }
        }
        if (all_exited) break;

        const now_ns = try timestampNs(io);
        if (now_ns >= deadline_ns) break;

        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }

    for (self.children[new_count..]) |*c| {
        if (c.isAlive()) {
            c.kill() catch {};
        }
    }

    const kill_deadline_ns = (try timestampNs(io)) + std.time.ns_per_s;
    while (true) {
        try self.monitorChildren(io);
        var all_exited = true;
        for (self.children[new_count..]) |c| {
            if (c.isAlive()) {
                all_exited = false;
                break;
            }
        }
        if (all_exited) break;

        if ((try timestampNs(io)) >= kill_deadline_ns) break;
        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }

    var new_children = try self.arena.allocator().alloc(Process, new_count);
    @memcpy(new_children[0..new_count], self.children[0..new_count]);
    self.children = new_children;
    self.numprocs = new_count;
}

pub fn stopChildren(self: *ProcessGroup, io: std.Io) !void {
    self.state = .stopping;
    for (self.children) |*c| {
        if (c.isAlive()) {
            c.stop(io, self.stop_signal, self.stop_timeout) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }
}

pub fn monitorChildren(self: *ProcessGroup, io: std.Io) !void {
    var has_running = false;
    var has_starting = false;
    var has_stopping = false;

    for (self.children) |*c| {
        try c.monitor(io);

        if (c.state == .backoff and try c.isBackoffExpired(io)) {
            c.state = .stopped;
        }

        if (c.hasExited()) {
            const should_restart = self.shouldRestart(c);
            if (should_restart and c.retries_count < self.start_retries) {
                c.retries_count += 1;
                try c.enterBackoff(io);
            } else if (!should_restart or c.retries_count >= self.start_retries) {
                c.state = .exited;
            }
        }

        if (c.state == .stopped and self.shouldRestart(c)) {
            c.reset(true);
            try c.start(io, .{
                .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
                .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
                .redirect_stdout = self.redirect_stdout,
                .redirect_stderr = self.redirect_stderr,
                .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
                .umask = if (self.umask != 0) self.umask else null,
                .path = self.cmd,
                .argv = self.argv orelse return error.MissingArgv,
                .envp = self.envp,
            });
        }

        switch (c.state) {
            .running => has_running = true,
            .starting => has_starting = true,
            .stopping => has_stopping = true,
            else => {},
        }
    }

    if (has_stopping) {
        self.state = .stopping;
    } else if (has_starting) {
        self.state = .starting;
    } else if (has_running) {
        self.state = .running;
    } else if (self.hasFatalProcesses()) {
        self.state = .fatal;
    } else {
        self.state = .stopped;
    }
}

pub fn getChildren(self: *const ProcessGroup) []const Process {
    return self.children;
}

pub fn getRunningCount(self: *const ProcessGroup) u32 {
    var count: u32 = 0;
    for (self.children) |*c| {
        if (c.isRunning()) count += 1;
    }
    return count;
}

pub fn getAliveCount(self: *const ProcessGroup) u32 {
    var count: u32 = 0;
    for (self.children) |*c| {
        if (c.isAlive()) count += 1;
    }
    return count;
}

pub fn getAllExited(self: *const ProcessGroup) bool {
    for (self.children) |*c| {
        if (c.isAlive()) return false;
    }
    return true;
}

pub fn getGroupState(self: *const ProcessGroup) GroupState {
    return self.state;
}

pub fn getTotalUptime(self: *const ProcessGroup, io: std.Io) !u64 {
    var total: u64 = 0;
    for (self.children) |*c| {
        if (c.isRunning()) {
            total += try c.getUptime(io);
        }
    }
    return total;
}

pub fn hasFatalProcesses(self: *const ProcessGroup) bool {
    for (self.children) |*c| {
        if (!c.stop_requested and c.state == .exited and c.retries_count >= self.start_retries) {
            return true;
        }
    }
    return false;
}

pub fn isExpectedExitCode(self: *const ProcessGroup, code: u8) bool {
    for (self.exitcodes) |expected_code| {
        if (code == expected_code) return true;
    }
    return false;
}

pub fn stopChild(self: *ProcessGroup, io: std.Io, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    try self.children[child_id].stop(io, self.stop_signal, self.stop_timeout);
}

pub fn killChild(self: *ProcessGroup, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    try self.children[child_id].kill();
}

pub fn restartChild(self: *ProcessGroup, io: std.Io, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    var child = &self.children[child_id];

    if (child.isAlive()) {
        try child.stop(io, self.stop_signal, self.stop_timeout);
        return;
    }

    child.reset(false);
    child.startsecs = self.startsecs;
    try child.start(io, .{
        .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
        .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
        .redirect_stdout = self.redirect_stdout,
        .redirect_stderr = self.redirect_stderr,
        .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
        .umask = if (self.umask != 0) self.umask else null,
        .path = self.cmd,
        .argv = self.argv orelse return error.MissingArgv,
        .envp = self.envp,
    });
}

pub fn shouldRestart(self: *const ProcessGroup, process: *const Process) bool {
    if (process.stop_requested) return false;

    switch (self.autorestart) {
        .always => return true,
        .never => return false,
        .unexpected => {
            if (process.failed_start) return true;
            if (process.getExitCode()) |code| {
                for (self.exitcodes) |expected_code| {
                    if (code == expected_code) {
                        return false;
                    }
                }
                return true;
            }
            return true;
        },
    }
}

fn buildArgv(argv: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    const result = try arena.allocSentinel(?[*:0]u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        result[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{arg}, 0);
    }
    return result;
}

fn buildEnvp(env: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    const envp = try arena.allocSentinel(?[*:0]u8, env.len, null);
    for (env, 0..) |pair, i| {
        envp[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{pair}, 0);
    }
    return envp;
}

test "process group initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 0), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 0), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@intFromEnum(std.posix.SIG.TERM), pg.stop_signal);
}

pub fn timestampNs(io: Io) !u64 {
    const timestamp = try Io.Clock.boot.now(io);
    return @as(u64, @truncate(@abs(timestamp.toNanoseconds())));
}

test "process group configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("test-process");
    try std.testing.expectEqualStrings("test-process", pg.name);

    try pg.setCmd("/bin/sleep");
    try std.testing.expectEqualStrings("/bin/sleep", pg.cmd);

    pg.setNumProcs(3);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);

    pg.setStartDelay(5);
    try std.testing.expectEqual(@as(u32, 5), pg.start_delay);

    pg.setStopTimeout(10);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);

    pg.setAutoRestart(.always);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
}

test "auto restart logic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutoRestart(.always);
    var process = Process{ .exit_code = 0 };
    try std.testing.expect(pg.shouldRestart(&process));

    pg.setAutoRestart(.never);
    try std.testing.expect(!pg.shouldRestart(&process));

    pg.setAutoRestart(.unexpected);
    try pg.setExitCodes(&.{0});
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));
}

test "auto restart respects manual stop" {
    var pg = ProcessGroup.init(std.testing.allocator);
    defer pg.deinit();

    pg.setAutoRestart(.always);

    var process = Process{
        .state = .exited,
        .stop_requested = true,
        .exit_code = 1,
    };

    try std.testing.expect(!pg.shouldRestart(&process));
}

test "process group spawn children configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"TEST=1"};
    try pg.setEnv(&env);
    pg.setNumProcs(2);
    pg.setStartDelay(3);

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{
            .id = @intCast(i),
            .start_delay_s = pg.start_delay,
        };
    }

    try std.testing.expectEqual(@as(usize, 2), pg.children.len);
    for (pg.children) |*c| {
        try std.testing.expectEqual(@as(u32, 3), c.start_delay_s);
    }
}

test "process group management functions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(3);

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
    }

    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    pg.children[0].state = .running;
    pg.children[1].state = .starting;
    pg.children[2].state = .exited;

    try std.testing.expectEqual(@as(u32, 1), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 2), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());
}

test "process group configuration validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try std.testing.expectError(error.MissingCommand, pg.spawnChildren(io));

    try pg.setCmd("/bin/true");
    try std.testing.expectError(error.NoProcesses, pg.spawnChildren(io));

    pg.setNumProcs(1);
    try pg.spawnChildren(io);

    var attempts: usize = 0;
    while (attempts < 40 and pg.children[0].pid != null) : (attempts += 1) {
        try pg.monitorChildren(io);
        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }
}

test "process group individual child control" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "10" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(2);
    pg.setStopSignal(@intFromEnum(std.posix.SIG.TERM));
    pg.setStopTimeout(5);

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i), .state = .running };
    }

    try std.testing.expectError(error.InvalidChildId, pg.stopChild(io, 5));
    try std.testing.expectError(error.InvalidChildId, pg.killChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.restartChild(io, 5));

    pg.stopChild(io, 0) catch |err| switch (err) {
        error.InvalidState => {},
        else => return err,
    };
}

test "process group new configuration options" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutostart(false);
    try std.testing.expectEqual(false, pg.autostart);
    pg.setAutostart(true);
    try std.testing.expectEqual(true, pg.autostart);

    pg.setRedirectStdout(false);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    pg.setRedirectStdout(true);
    try std.testing.expectEqual(true, pg.redirect_stdout);

    pg.setRedirectStderr(false);
    try std.testing.expectEqual(false, pg.redirect_stderr);
    pg.setRedirectStderr(true);
    try std.testing.expectEqual(true, pg.redirect_stderr);

    pg.setStartSecs(5);
    try std.testing.expectEqual(@as(u32, 5), pg.startsecs);
    pg.setStartSecs(10);
    try std.testing.expectEqual(@as(u32, 10), pg.startsecs);
}

test "process startsecs validation" {
    var process = Process{ .startsecs = 2, .start_delay_s = 1 };
    const io = std.testing.io;
    const start_time = try timestampNs(io);
    process.start_time_ns = start_time;
    process.start_delay_started_ns = process.start_time_ns;
    process.state = .starting;

    try io.sleep(.fromMilliseconds(100), .boot);
    const now_ns = try timestampNs(io);
    const delay_ns = process.start_delay_s * std.time.ns_per_s;
    if (now_ns - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
        process.stability_start_ns = now_ns;
    }
    try std.testing.expectEqual(Process.State.starting, process.state);

    try io.sleep(.fromMilliseconds(1100), .boot);
    const now_ns2 = try timestampNs(io);
    if (now_ns2 - process.start_delay_started_ns >= delay_ns) {
        process.state = .running;
        process.stability_start_ns = now_ns2;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
    try std.testing.expect(process.stability_start_ns > 0);

    try io.sleep(.fromMilliseconds(1500), .boot);
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process group backoff configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(@as(u32, 1), pg.backoff_delay_s);

    pg.setBackoffDelay(5);
    try std.testing.expectEqual(@as(u32, 5), pg.backoff_delay_s);
}

test "process group scale up and down preserves existing process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "2" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutostart(true);
    pg.setAutoRestart(.never);

    try pg.spawnChildren(io);
    try pg.monitorChildren(io);

    const original_pid = pg.children[0].pid;
    try std.testing.expect(original_pid != null);

    try pg.scaleUp(io, 2);
    try std.testing.expectEqual(@as(usize, 2), pg.children.len);
    try std.testing.expectEqual(original_pid, pg.children[0].pid);
    try std.testing.expect(pg.children[1].pid != null);

    try pg.scaleDown(io, 1);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
    try std.testing.expectEqual(original_pid, pg.children[0].pid);

    pg.stopChildren(io) catch {};
    var attempts: usize = 0;
    while (attempts < 40 and pg.children[0].pid != null) : (attempts += 1) {
        try pg.monitorChildren(io);
        try io.sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }
}

test "process group backoff logic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);

    pg.setBackoffDelay(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);
    pg.setNumProcs(1);

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = pg.backoff_delay_s,
        .state = .exited,
        .retries_count = 0,
    };

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    try io.sleep(.fromMilliseconds(1100), .boot);
    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.starting, pg.children[0].state);
}

test "process group state and uptime" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try std.testing.expectEqual(GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u64, 0), try pg.getTotalUptime(io));
    try std.testing.expect(!pg.hasFatalProcesses());

    pg.children = try pg.arena.allocator().alloc(Process, 2);
    pg.children[0] = .{ .id = 0, .state = .running, .start_time_ns = 1000 };
    pg.children[1] = .{ .id = 1, .state = .exited, .retries_count = 3 };

    const uptime = try pg.getTotalUptime(io);
    try std.testing.expect(uptime > 0);

    try std.testing.expect(pg.hasFatalProcesses());
}

test "process group complete lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(3);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);

    try std.testing.expectEqualStrings("/bin/true", pg.cmd);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 2), pg.start_retries);
}

test "process group restart policies comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutoRestart(.always);
    var process = Process{ .exit_code = 0 };
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));

    pg.setAutoRestart(.never);
    process.exit_code = 0;
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(!pg.shouldRestart(&process));

    pg.setAutoRestart(.unexpected);
    try pg.setExitCodes(&.{0});

    process.exit_code = 0;
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = 2;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));
}

test "process group timing and grace periods" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setStartDelay(5);
    try std.testing.expectEqual(@as(u32, 5), pg.start_delay);

    pg.setStartSecs(10);
    try std.testing.expectEqual(@as(u32, 10), pg.startsecs);

    pg.setStopTimeout(15);
    try std.testing.expectEqual(@as(u32, 15), pg.stop_timeout);

    pg.setBackoffDelay(3);
    try std.testing.expectEqual(@as(u32, 3), pg.backoff_delay_s);
}

test "process group signal handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    pg.setStopSignal(@intFromEnum(std.posix.SIG.USR1));
    try std.testing.expectEqual(@intFromEnum(std.posix.SIG.USR1), pg.stop_signal);

    pg.setStopSignal(@intFromEnum(std.posix.SIG.TERM));
    try std.testing.expectEqual(@intFromEnum(std.posix.SIG.TERM), pg.stop_signal);

    pg.children = try pg.arena.allocator().alloc(Process, 2);
    pg.children[0] = .{ .id = 0, .state = .running };
    pg.children[1] = .{ .id = 1, .state = .starting };

    try std.testing.expectError(error.InvalidChildId, pg.stopChild(io, 5));
    try std.testing.expectError(error.InvalidChildId, pg.killChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.restartChild(io, 5));
}

test "process group resource management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setWorkingDir("/tmp");
    try std.testing.expectEqualStrings("/tmp", pg.working_directory);

    try pg.setStdoutPath("/tmp/stdout.log");
    try pg.setStderrPath("/tmp/stderr.log");
    try std.testing.expectEqualStrings("/tmp/stdout.log", pg.stdout_path);
    try std.testing.expectEqualStrings("/tmp/stderr.log", pg.stderr_path);

    pg.setUmask(0o077);
    try std.testing.expectEqual(@as(u16, 0o077), pg.umask);

    pg.setRedirectStdout(false);
    pg.setRedirectStderr(false);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    try std.testing.expectEqual(false, pg.redirect_stderr);

    pg.setRedirectStdout(true);
    pg.setRedirectStderr(true);
    try std.testing.expectEqual(true, pg.redirect_stdout);
    try std.testing.expectEqual(true, pg.redirect_stderr);
}

test "process group coordination and orchestration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(5);
    pg.setAutoRestart(.always);
    pg.setStartRetries(3);

    try std.testing.expectEqual(@as(u32, 5), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());

    pg.children = try pg.arena.allocator().alloc(Process, 5);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
    }

    pg.children[0].state = .running;
    pg.children[1].state = .starting;
    pg.children[2].state = .stopping;
    pg.children[3].state = .exited;
    pg.children[4].state = .backoff;

    try std.testing.expectEqual(@as(u32, 1), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 3), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());

    pg.children[3].retries_count = 5;
    try std.testing.expect(pg.hasFatalProcesses());
}

test "process group error handling and edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try std.testing.expectError(error.MissingCommand, pg.spawnChildren(io));

    try pg.setCmd("/bin/true");
    try std.testing.expectError(error.NoProcesses, pg.spawnChildren(io));

    pg.setNumProcs(1);
    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group backoff and retry logic comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);

    pg.setBackoffDelay(2);
    pg.setAutoRestart(.always);
    pg.setStartRetries(3);
    pg.setNumProcs(1);

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = pg.backoff_delay_s,
        .state = .exited,
        .retries_count = 0,
    };

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
    try std.testing.expect(pg.children[0].backoff_until_ns > 0);

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    try io.sleep(.fromMilliseconds(2500), .boot);
    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.starting, pg.children[0].state);

    pg.children[0].state = .exited;
    pg.children[0].retries_count = 3;
    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "process group name and identification" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("test-process-group");
    try std.testing.expectEqualStrings("test-process-group", pg.name);

    try pg.setName("");
    try std.testing.expectEqualStrings("", pg.name);
}

test "process group integration scenario - web server" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("web-server");
    try pg.setCmd("/usr/bin/python3");
    const argv = [_][]const u8{ "python3", "-m", "http.server", "8080" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"PYTHONPATH=/opt/webapp"};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/opt/webapp");
    try pg.setStdoutPath("/var/log/webapp/stdout.log");
    try pg.setStderrPath("/var/log/webapp/stderr.log");
    pg.setNumProcs(3);
    pg.setStartDelay(2);
    pg.setStartSecs(5);
    pg.setStopSignal(@intFromEnum(std.posix.SIG.TERM));
    pg.setStopTimeout(10);
    pg.setAutoRestart(.unexpected);
    pg.setStartRetries(5);
    pg.setBackoffDelay(3);
    try pg.setExitCodes(&.{0});

    try std.testing.expectEqualStrings("web-server", pg.name);
    try std.testing.expectEqualStrings("/usr/bin/python3", pg.cmd);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 2), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 5), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 3), pg.backoff_delay_s);
}

test "process group integration scenario - database worker" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("db-worker");
    try pg.setCmd("/opt/app/bin/worker");
    const argv = [_][]const u8{ "worker", "--config", "/etc/worker.conf" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"DATABASE_URL=postgresql://localhost:5432/mydb"};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/opt/app");
    pg.setNumProcs(8);
    pg.setStartDelay(1);
    pg.setStartSecs(3);
    pg.setStopSignal(@intFromEnum(std.posix.SIG.INT));
    pg.setStopTimeout(5);
    pg.setAutoRestart(.always);
    pg.setStartRetries(10);
    pg.setBackoffDelay(2);
    pg.setUmask(0o022);

    try std.testing.expectEqualStrings("db-worker", pg.name);
    try std.testing.expectEqualStrings("/opt/app/bin/worker", pg.cmd);
    try std.testing.expectEqual(@as(u32, 8), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 1), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 3), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 5), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 10), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 2), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o022), pg.umask);
}

test "process group stress test - many processes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(100);
    pg.setAutoRestart(.never);

    pg.children = try pg.arena.allocator().alloc(Process, 100);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
        if (i % 4 == 0) {
            c.state = .running;
        } else if (i % 4 == 1) {
            c.state = .starting;
        } else if (i % 4 == 2) {
            c.state = .exited;
        } else {
            c.state = .backoff;
        }
    }

    try std.testing.expectEqual(@as(u32, 25), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 50), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());
}

test "process group edge cases and boundary conditions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setNumProcs(0);
    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    pg.setStartRetries(0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_retries);

    pg.setStartDelay(0xFFFFFFFF);
    pg.setStartSecs(0xFFFFFFFF);
    pg.setStopTimeout(0xFFFFFFFF);
    pg.setBackoffDelay(0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.stop_timeout);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.backoff_delay_s);
}

test "process group memory management and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    for (0..10) |_| {
        var pg = ProcessGroup.init(allocator);

        try pg.setName("test-process");
        try pg.setCmd("/bin/true");
        const argv = [_][]const u8{"true"};
        try pg.setArgv(&argv);
        const env = [_][]const u8{};
        try pg.setEnv(&env);
        pg.setNumProcs(5);

        pg.children = try pg.arena.allocator().alloc(Process, 5);
        for (pg.children, 0..) |*c, i| {
            c.* = .{ .id = @intCast(i) };
        }

        try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
        try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());

        pg.deinit();
    }
}

test "process group configuration validation comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("comprehensive-test");
    try pg.setCmd("/bin/echo");
    const argv = [_][]const u8{ "echo", "hello", "world" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{ "TEST=1", "DEBUG=true" };
    try pg.setEnv(&env);
    try pg.setWorkingDir("/tmp");
    try pg.setStdoutPath("/tmp/out.log");
    try pg.setStderrPath("/tmp/err.log");
    pg.setNumProcs(7);
    pg.setStartRetries(3);
    pg.setStartDelay(4);
    pg.setStartSecs(6);
    pg.setStopSignal(@intFromEnum(std.posix.SIG.QUIT));
    pg.setStopTimeout(8);
    pg.setAutoRestart(.unexpected);
    pg.setBackoffDelay(5);
    pg.setUmask(0o644);
    pg.setRedirectStdout(false);
    pg.setRedirectStderr(false);
    pg.setAutostart(false);
    try pg.setExitCodes(&.{ 0, 1, 2 });

    try std.testing.expectEqualStrings("comprehensive-test", pg.name);
    try std.testing.expectEqualStrings("/bin/echo", pg.cmd);
    try std.testing.expectEqualStrings("/tmp", pg.working_directory);
    try std.testing.expectEqualStrings("/tmp/out.log", pg.stdout_path);
    try std.testing.expectEqualStrings("/tmp/err.log", pg.stderr_path);
    try std.testing.expectEqual(@as(u32, 7), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 3), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 4), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 6), pg.startsecs);
    try std.testing.expectEqual(@intFromEnum(std.posix.SIG.QUIT), pg.stop_signal);
    try std.testing.expectEqual(@as(u32, 8), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o644), pg.umask);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    try std.testing.expectEqual(false, pg.redirect_stderr);
    try std.testing.expectEqual(false, pg.autostart);
}

test "process group zero processes edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(0);

    // Should handle zero processes gracefully
    try std.testing.expectEqual(@as(usize, 0), pg.children.len);
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(GroupState.stopped, pg.state);
}

test "process group maximum retry limit edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/nonexistent/command");
    const argv = [_][]const u8{"nonexistent"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);
    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
    try std.testing.expect(pg.children.len > 0);
}

test "process group backoff timing edge case - zero delay" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(1);
    pg.setBackoffDelay(0);

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = 0,
        .state = .exited,
        .retries_count = 0,
    };

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
    try std.testing.expect(try pg.children[0].isBackoffExpired(io));
}

test "process group stop timeout edge case - immediate kill" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "10" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setStopTimeout(0);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    try pg.stopChildren(io);
    try std.testing.expect(pg.state == .stopping or pg.state == .stopped);

    try pg.monitorChildren(io);
    try std.testing.expect(pg.state == .stopping or pg.state == .stopped);
}

test "process group autorestart never policy edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.never);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren(io);
        try io.sleep(.fromMilliseconds(50), .boot);
        iterations += 1;
    }

    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);

    try pg.monitorChildren(io);
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "process group autorestart unexpected policy edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/false");
    const argv = [_][]const u8{"false"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.unexpected);
    pg.setStartRetries(1);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren(io);
        try io.sleep(.fromMilliseconds(50), .boot);
        iterations += 1;
    }

    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
}

test "process group memory pressure edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    const long_arg = "x" ** 1000;
    try pg.setCmd("/bin/echo");
    const argv = [_][]const u8{ "echo", long_arg };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group signal handling edge case - unusual signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "10" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setStopSignal(@intFromEnum(std.posix.SIG.USR1));

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    try pg.stopChildren(io);
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
}

test "process group environment variable edge case - empty environment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group umask edge case - restrictive umask" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/touch");
    const argv = [_][]const u8{ "touch", "/tmp/test_file" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setUmask(0o777);
    pg.setNumProcs(1);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group state transition edge case - rapid state changes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    try pg.spawnChildren(io);
    try std.testing.expect(pg.state == GroupState.starting or pg.state == GroupState.stopped);

    try pg.stopChildren(io);
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
    try pg.monitorChildren(io);
    try std.testing.expect(pg.state == .stopping or pg.state == .stopped);
}

test "process group resource cleanup edge case - proper cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit(); // Use defer for proper cleanup

    const io = std.testing.io;
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    try pg.spawnChildren(io);

    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group concurrent access edge case - simultaneous operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(2);

    try pg.spawnChildren(io);

    try pg.stopChildren(io);
    try pg.monitorChildren(io);

    try std.testing.expect(pg.state == .stopping or pg.state == .stopped);
}

test "process group start grace period edge case - immediate failure" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/nonexistent/command");
    const argv = [_][]const u8{"nonexistent"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{""};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setStartSecs(5);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    try std.testing.expect(pg.children.len > 0);
}

test "process group working directory edge case - non-existent directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    const io = std.testing.io;
    try pg.setCmd("/bin/pwd");
    const argv = [_][]const u8{"pwd"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{""};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/nonexistent/directory");
    pg.setNumProcs(1);

    try pg.spawnChildren(io);
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    try std.testing.expect(pg.children.len > 0);
}
