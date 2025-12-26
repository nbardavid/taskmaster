const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const config = @import("../config.zig");
const Config = config.Config;
const ProgramConfig = config.ProgramConfig;
const ConfigParser = config.ConfigParser;
const config_observer = @import("../config_observer.zig");
const ConfigDiff = config_observer.ConfigDiff;
const ProgramChange = config_observer.ProgramChange;
const ChangeType = config_observer.ChangeType;
const Process = @import("../process/Process.zig").Process;
const ProcessGroup = @import("../process/ProcessGroup.zig").ProcessGroup;
const Logger = @import("Logger.zig").Logger;

pub const ProcessGroupManager = @This();

gpa: std.mem.Allocator,
groups: std.StringHashMap(*ProcessGroup),
io: Io,
logger: *Logger,

pub fn init(gpa: std.mem.Allocator, io: Io, logger: *Logger) ProcessGroupManager {
    return .{
        .gpa = gpa,
        .groups = std.StringHashMap(*ProcessGroup).init(gpa),
        .io = io,
        .logger = logger,
    };
}

pub fn deinit(self: *ProcessGroupManager) void {
    var iter = self.groups.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const group = entry.value_ptr.*;
        group.deinit();
        self.gpa.destroy(group);
        self.gpa.free(key);
    }
    self.groups.deinit();
}

pub fn createGroup(self: *ProcessGroupManager, name: []const u8, program_config: *const ProgramConfig) !void {
    const group = try self.gpa.create(ProcessGroup);
    errdefer self.gpa.destroy(group);

    group.* = ProcessGroup.init(self.gpa);
    errdefer group.deinit();

    try ConfigParser.configureProcessGroup(program_config, group, name);

    const name_copy = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(name_copy);

    try self.groups.put(name_copy, group);

    self.logger.info("Created process group '{s}' (numprocs: {})", .{ name, program_config.numprocs });
}

pub fn removeGroup(self: *ProcessGroupManager, name: []const u8) !void {
    const entry = self.groups.fetchRemove(name) orelse return error.GroupNotFound;
    const group = entry.value;

    try group.stop(self.io);

    self.logger.info("Removed process group '{s}'", .{name});

    group.deinit();
    self.gpa.destroy(group);
    self.gpa.free(entry.key);
}

pub fn updateGroup(self: *ProcessGroupManager, name: []const u8, change: *const ProgramChange) !void {
    const group = self.groups.get(name) orelse return error.GroupNotFound;
    const field_changes = &change.field_changes;
    const new_config = change.new_config orelse return error.MissingNewConfig;

    if (field_changes.requires_respawn) {
        self.logger.info("Process group '{s}' requires respawn due to configuration changes", .{name});

        try group.stop(self.io);
        try ConfigParser.configureProcessGroup(new_config, group, name);

        if (group.autostart) {
            try group.spawnChildren(self.io);
            self.logger.info("Process group '{s}' respawned with {d} processes", .{ name, group.numprocs });
        }
    } else if (field_changes.numprocs_changed) {
        const old_count = field_changes.numprocs_old;
        const new_count = field_changes.numprocs_new;

        self.logger.info("Process group '{s}' scaling from {d} to {d} processes", .{ name, old_count, new_count });

        if (new_count > old_count) {
            try group.scaleUp(self.io, new_count);
        } else {
            try group.scaleDown(self.io, new_count);
        }
    } else if (field_changes.can_update_in_place) {
        self.logger.info("Process group '{s}' updating configuration in-place", .{name});

        if (field_changes.autorestart_changed) {
            group.autorestart = try ConfigParser.parseAutoRestart(new_config.autorestart);
        }

        if (field_changes.stopsignal_changed) {
            group.setStopSignal(try ConfigParser.parseSignal(new_config.stopsignal));
        }

        if (field_changes.stoptime_changed) {
            group.stop_timeout = new_config.stoptime;
        }

        if (field_changes.starttime_changed) {
            group.setStartDelay(new_config.starttime);
        }

        if (field_changes.startsecs_changed) {
            group.setStartSecs(new_config.startsecs);
        }

        if (field_changes.startretries_changed) {
            group.setStartRetries(new_config.startretries);
        }

        if (field_changes.autostart_changed) {
            group.autostart = new_config.autostart;
            if (group.autostart and group.getAliveCount() == 0) {
                try group.spawnChildren(self.io);
                self.logger.info("Auto-started process group '{s}' following config update", .{name});
            }
        }

        if (field_changes.exitcodes_changed) {
            group.exitcodes = try group.arena.allocator().dupe(u32, new_config.exitcodes);
        }

        if (field_changes.stdout_changed) {
            if (new_config.stdout) |path| {
                try group.setStdoutPath(path);
                group.redirect_stdout = true;
            } else {
                group.redirect_stdout = false;
            }
        }

        if (field_changes.stderr_changed) {
            if (new_config.stderr) |path| {
                try group.setStderrPath(path);
                group.redirect_stderr = true;
            } else {
                group.redirect_stderr = false;
            }
        }
    }
}

pub fn reloadConfig(self: *ProcessGroupManager, old_config: *const Config, new_config: *const Config) !void {
    self.logger.info("Starting config reload", .{});

    var diff = try ConfigDiff.compute(old_config, new_config, self.gpa);
    defer diff.deinit();

    var changes_applied: usize = 0;

    var iter = diff.iterator();
    while (iter.next()) |entry| {
        const change = entry.value_ptr;

        switch (change.change_type) {
            .added => {
                if (change.new_config) |new_prog_config| {
                    try self.createGroup(change.program_name, new_prog_config);

                    if (new_prog_config.autostart) {
                        const group = self.groups.get(change.program_name).?;
                        try group.spawnChildren(self.io);
                        self.logger.info("Auto-started process group '{s}'", .{change.program_name});
                    }

                    changes_applied += 1;
                }
            },
            .removed => {
                try self.removeGroup(change.program_name);
                changes_applied += 1;
            },
            .modified => {
                try self.updateGroup(change.program_name, change);
                changes_applied += 1;
            },
            .unchanged => {
                self.logger.debug("Process group '{s}' unchanged", .{change.program_name});
            },
        }
    }

    self.logger.info("Config reload complete ({} changes applied)", .{changes_applied});
}

pub fn monitor(self: *ProcessGroupManager) !void {
    const Snapshot = struct {
        state: Process.State,
        pid: ?posix.pid_t,
        retries_count: u32,
        stop_requested: bool,
        exit_code: ?u8,
        exit_signal: ?u8,
        fatal_logged: bool,
    };

    var iter = self.groups.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const group = entry.value_ptr.*;

        if (group.children.len == 0) {
            continue;
        }

        var snapshots = try self.gpa.alloc(Snapshot, group.children.len);
        defer self.gpa.free(snapshots);

        for (group.children, 0..) |*child, i| {
            snapshots[i] = .{
                .state = child.state,
                .pid = child.pid,
                .retries_count = child.retries_count,
                .stop_requested = child.stop_requested,
                .exit_code = child.exit_code,
                .exit_signal = child.exit_signal,
                .fatal_logged = child.fatal_logged,
            };
        }

        try group.monitorChildren(self.io);

        for (group.children, 0..) |*child, i| {
            const snap = snapshots[i];

            if (snap.state != .running and child.state == .running) {
                const pid = @as(i32, @intCast(child.pid orelse 0));
                if (snap.state == .starting and snap.retries_count == 0) {
                    self.logger.logProgramStarted(name, pid);
                } else {
                    self.logger.logProgramRestarted(name, pid);
                }
            }

            if (snap.pid != null and child.pid == null and child.state == .exited) {
                const pid = @as(i32, @intCast(snap.pid.?));
                if (child.stop_requested or snap.stop_requested) {
                    self.logger.logProgramStopped(name, pid);
                } else if (child.exit_signal) |signal| {
                    self.logger.logProgramKilled(name, pid, @as(i32, @intCast(signal)));
                } else if (child.exit_code) |code| {
                    if (group.isExpectedExitCode(code)) {
                        self.logger.logProgramStopped(name, pid);
                    } else {
                        self.logger.logProgramDied(name, pid, @as(i32, @intCast(code)));
                    }
                } else {
                    self.logger.logProgramDied(name, pid, -1);
                }
            }

            if (child.state == .exited and group.shouldRestart(child) and
                child.retries_count >= group.start_retries and !child.fatal_logged)
            {
                self.logger.logProgramFatal(name);
                child.fatal_logged = true;
            }
        }
    }
}

pub fn startAll(self: *ProcessGroupManager) !void {
    self.logger.info("Starting all autostart process groups", .{});

    var started: usize = 0;
    var iter = self.groups.valueIterator();
    while (iter.next()) |group_ptr| {
        const group = group_ptr.*;
        if (group.autostart) {
            try group.spawnChildren(self.io);
            started += 1;
            self.logger.info("Started process group '{s}' ({} processes)", .{ group.name, group.numprocs });
        }
    }

    self.logger.info("Started {} process groups", .{started});
}

pub fn stopAll(self: *ProcessGroupManager) !void {
    self.logger.info("Stopping all process groups", .{});

    var iter = self.groups.valueIterator();
    while (iter.next()) |group_ptr| {
        const group = group_ptr.*;
        try group.stop(self.io);
        self.logger.info("Stopped process group '{s}'", .{group.name});
    }
}

pub const GroupStatus = struct {
    name: []const u8,
    running: u32,
    alive: u32,
    total: u32,
    uptime_s: u64,
    fatal_count: u32,
};

pub fn getStatus(self: *ProcessGroupManager, allocator: std.mem.Allocator) ![]GroupStatus {
    var status_list: std.ArrayList(GroupStatus) = .empty;
    errdefer status_list.deinit(allocator);

    var iter = self.groups.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const group = entry.value_ptr.*;

        const uptime_ns = try group.getTotalUptime(self.io);
        const uptime_s: u64 = uptime_ns / std.time.ns_per_s;

        var fatal_count: u32 = 0;
        for (group.children) |*child| {
            if (child.state == .exited and child.retries_count >= group.start_retries) {
                fatal_count += 1;
            }
        }

        try status_list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .running = group.getRunningCount(),
            .alive = group.getAliveCount(),
            .total = group.numprocs,
            .uptime_s = uptime_s,
            .fatal_count = fatal_count,
        });
    }

    return status_list.toOwnedSlice(allocator);
}

pub fn getGroup(self: *ProcessGroupManager, name: []const u8) ?*ProcessGroup {
    return self.groups.get(name);
}

test "ProcessGroupManager init and deinit" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/pgm_test.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.groups.count());

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "ProcessGroupManager create and remove group" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/pgm_create_test.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    var argv_slice = [_][]const u8{"hello"};
    const prog_config = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .numprocs = 1,
    };

    try manager.createGroup("test", &prog_config);
    try std.testing.expectEqual(@as(usize, 1), manager.groups.count());

    const group = manager.getGroup("test");
    try std.testing.expect(group != null);
    try std.testing.expectEqualStrings("test", group.?.name);

    try manager.removeGroup("test");
    try std.testing.expectEqual(@as(usize, 0), manager.groups.count());

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "ProcessGroupManager monitor logs fatal on repeated failure" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "pgm_monitor_test.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    const env_map = std.json.ArrayHashMap([]const u8){ .map = .empty };
    var argv_slice = [_][]const u8{"false"};
    const prog_config = ProgramConfig{
        .cmd = "/bin/false",
        .argv = @constCast(argv_slice[0..]),
        .numprocs = 1,
        .autostart = true,
        .autorestart = "always",
        .starttime = 0,
        .startretries = 0,
        .env = env_map,
    };

    try manager.createGroup("fail", &prog_config);
    try manager.startAll();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try manager.monitor();
        try io.io().sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }

    const content = try std.fs.cwd().readFileAlloc(log_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "exited unexpectedly") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "fatal") != null);

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "ProcessGroupManager config reload - add program" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/pgm_reload_test.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    var argv_slice = [_][]const u8{"hello"};
    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .autostart = false,
        .autorestart = "never",
        .numprocs = 1,
    };

    try new_config.programs.map.put(std.testing.allocator, "test", prog);

    try manager.reloadConfig(&old_config, &new_config);

    try std.testing.expectEqual(@as(usize, 1), manager.groups.count());
    const group = manager.getGroup("test");
    try std.testing.expect(group != null);

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "ProcessGroupManager config reload - remove program" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/pgm_remove_test.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    var argv_slice = [_][]const u8{"hello"};
    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    try old_config.programs.map.put(std.testing.allocator, "test", prog);

    try manager.createGroup("test", &prog);
    try std.testing.expectEqual(@as(usize, 1), manager.groups.count());

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    try manager.reloadConfig(&old_config, &new_config);

    try std.testing.expectEqual(@as(usize, 0), manager.groups.count());

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "ProcessGroupManager config reload - unchanged program not respawned" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/pgm_reload_unchanged.log";
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    var manager = ProcessGroupManager.init(std.testing.allocator, io.io(), &logger);
    defer manager.deinit();

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    const env_map = std.json.ArrayHashMap([]const u8){ .map = .empty };
    var argv_slice = [_][]const u8{ "sleep", "2" };
    const prog = ProgramConfig{
        .cmd = "/bin/sleep",
        .argv = @constCast(argv_slice[0..]),
        .autostart = true,
        .autorestart = "never",
        .numprocs = 1,
        .starttime = 0,
        .startretries = 0,
        .env = env_map,
    };

    try old_config.programs.map.put(std.testing.allocator, "sleepy", prog);
    try new_config.programs.map.put(std.testing.allocator, "sleepy", prog);

    try manager.createGroup("sleepy", &prog);
    try manager.startAll();

    try manager.monitor();

    const group = manager.getGroup("sleepy").?;
    const original_pid = group.children[0].pid;
    try std.testing.expect(original_pid != null);

    try manager.reloadConfig(&old_config, &new_config);

    const same_pid = group.children[0].pid;
    try std.testing.expectEqual(original_pid, same_pid);

    manager.stopAll() catch {};
    var i: usize = 0;
    while (i < 20 and group.children[0].pid != null) : (i += 1) {
        try manager.monitor();
        try io.io().sleep(Io.Duration.fromMilliseconds(50), Io.Clock.boot);
    }

    std.fs.cwd().deleteFile(log_path) catch {};
}
