const std = @import("std");

const config = @import("config.zig");
const Config = config.Config;
const ProgramConfig = config.ProgramConfig;

pub const FieldChangeType = enum {
    unchanged,
    config_updated,
    requires_respawn,
    scale_changed,
};

pub const ProgramFieldChanges = struct {
    cmd_changed: bool = false,
    argv_changed: bool = false,
    env_changed: bool = false,

    numprocs_old: u32 = 0,
    numprocs_new: u32 = 0,
    numprocs_changed: bool = false,

    autostart_changed: bool = false,
    autorestart_changed: bool = false,
    exitcodes_changed: bool = false,
    starttime_changed: bool = false,
    startsecs_changed: bool = false,
    startretries_changed: bool = false,
    stopsignal_changed: bool = false,
    stoptime_changed: bool = false,
    stdout_changed: bool = false,
    stderr_changed: bool = false,
    workingdir_changed: bool = false,
    umask_changed: bool = false,

    requires_respawn: bool = false,
    can_update_in_place: bool = false,

    pub fn computeFlags(self: *ProgramFieldChanges) void {
        self.requires_respawn = self.cmd_changed or self.argv_changed or self.env_changed or
            self.workingdir_changed or self.umask_changed;
        self.can_update_in_place = !self.requires_respawn and (self.autostart_changed or
            self.autorestart_changed or
            self.exitcodes_changed or
            self.starttime_changed or
            self.startsecs_changed or
            self.startretries_changed or
            self.stopsignal_changed or
            self.stoptime_changed or
            self.stdout_changed or
            self.stderr_changed);
    }
};

pub const ChangeType = enum {
    added,
    removed,
    modified,
    unchanged,
};

pub const ProgramChange = struct {
    program_name: []const u8,
    change_type: ChangeType,
    old_config: ?*const ProgramConfig = null,
    new_config: ?*const ProgramConfig = null,
    field_changes: ProgramFieldChanges = .{},
};

pub const ConfigDiff = struct {
    arena: std.heap.ArenaAllocator,
    changes: std.StringArrayHashMap(ProgramChange),

    pub fn init(gpa: std.mem.Allocator) ConfigDiff {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .changes = std.StringArrayHashMap(ProgramChange).init(gpa),
        };
    }

    pub fn deinit(self: *ConfigDiff) void {
        self.changes.deinit();
        self.arena.deinit();
    }

    pub fn getChange(self: *const ConfigDiff, name: []const u8) ?*const ProgramChange {
        return if (self.changes.getPtr(name)) |ptr| ptr else null;
    }

    pub fn iterator(self: *const ConfigDiff) std.StringArrayHashMap(ProgramChange).Iterator {
        return self.changes.iterator();
    }

    pub fn compute(
        old_config: *const Config,
        new_config: *const Config,
        gpa: std.mem.Allocator,
    ) !ConfigDiff {
        var diff = ConfigDiff.init(gpa);
        errdefer diff.deinit();

        const allocator = diff.arena.allocator();

        var new_iter = new_config.programs.map.iterator();
        while (new_iter.next()) |new_entry| {
            const name = new_entry.key_ptr.*;
            const new_prog_ptr = new_entry.value_ptr;

            const name_copy = try allocator.dupe(u8, name);

            if (old_config.programs.map.get(name)) |old_prog| {
                const field_changes = try compareProgramConfig(&old_prog, new_prog_ptr, allocator);

                const change_type: ChangeType = if (field_changes.requires_respawn or
                    field_changes.numprocs_changed or
                    field_changes.can_update_in_place) .modified else .unchanged;

                try diff.changes.put(name_copy, .{
                    .program_name = name_copy,
                    .change_type = change_type,
                    .old_config = &old_prog,
                    .new_config = new_prog_ptr,
                    .field_changes = field_changes,
                });
            } else {
                try diff.changes.put(name_copy, .{
                    .program_name = name_copy,
                    .change_type = .added,
                    .new_config = new_prog_ptr,
                });
            }
        }

        var old_iter = old_config.programs.map.iterator();
        while (old_iter.next()) |old_entry| {
            const name = old_entry.key_ptr.*;
            const old_prog = old_entry.value_ptr.*;

            if (!new_config.programs.map.contains(name)) {
                const name_copy = try allocator.dupe(u8, name);
                try diff.changes.put(name_copy, .{
                    .program_name = name_copy,
                    .change_type = .removed,
                    .old_config = &old_prog,
                });
            }
        }

        return diff;
    }
};

pub fn compareProgramConfig(
    old: *const ProgramConfig,
    new: *const ProgramConfig,
    allocator: std.mem.Allocator,
) !ProgramFieldChanges {
    _ = allocator;

    var changes = ProgramFieldChanges{};

    changes.cmd_changed = !std.mem.eql(u8, old.cmd, new.cmd);
    changes.argv_changed = !slicesEqual([]const u8, old.argv, new.argv);
    changes.env_changed = !envMapsEqual(old.env, new.env);

    changes.numprocs_old = old.numprocs;
    changes.numprocs_new = new.numprocs;
    changes.numprocs_changed = old.numprocs != new.numprocs;

    changes.autostart_changed = old.autostart != new.autostart;
    changes.autorestart_changed = !std.mem.eql(u8, old.autorestart, new.autorestart);
    changes.exitcodes_changed = !slicesEqual(u32, old.exitcodes, new.exitcodes);
    changes.starttime_changed = old.starttime != new.starttime;
    changes.startsecs_changed = old.startsecs != new.startsecs;
    changes.startretries_changed = old.startretries != new.startretries;
    changes.stopsignal_changed = !std.mem.eql(u8, old.stopsignal, new.stopsignal);
    changes.stoptime_changed = old.stoptime != new.stoptime;
    changes.stdout_changed = !optionalEqual([]const u8, old.stdout, new.stdout);
    changes.stderr_changed = !optionalEqual([]const u8, old.stderr, new.stderr);
    changes.workingdir_changed = !optionalEqual([]const u8, old.workingdir, new.workingdir);
    changes.umask_changed = !optionalEqual(u16, old.umask, new.umask);

    changes.computeFlags();

    return changes;
}

fn slicesEqual(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_val, b_val| {
        if (T == []const u8) {
            if (!std.mem.eql(u8, a_val, b_val)) return false;
        } else {
            if (a_val != b_val) return false;
        }
    }
    return true;
}

fn optionalEqual(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    if (T == []const u8) {
        return std.mem.eql(u8, a.?, b.?);
    }
    return a.? == b.?;
}

fn envMapsEqual(
    a: ?std.json.ArrayHashMap([]const u8),
    b: ?std.json.ArrayHashMap([]const u8),
) bool {
    if (a == null and b == null) return true;

    if (a == null or b == null) return false;

    const a_map = &a.?.map;
    const b_map = &b.?.map;

    if (a_map.count() != b_map.count()) return false;

    var iter = a_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const a_value = entry.value_ptr.*;

        const b_value = b_map.get(key) orelse return false;

        if (!std.mem.eql(u8, a_value, b_value)) return false;
    }

    return true;
}

test "slicesEqual - u32 slices" {
    const a = [_]u32{ 0, 1, 2 };
    const b = [_]u32{ 0, 1, 2 };
    const c = [_]u32{ 0, 1, 3 };
    const d = [_]u32{0};

    try std.testing.expect(slicesEqual(u32, &a, &b));
    try std.testing.expect(!slicesEqual(u32, &a, &c));
    try std.testing.expect(!slicesEqual(u32, &a, &d));
}

test "slicesEqual - string slices" {
    const a = [_][]const u8{ "hello", "world" };
    const b = [_][]const u8{ "hello", "world" };
    const c = [_][]const u8{ "hello", "zig" };

    try std.testing.expect(slicesEqual([]const u8, &a, &b));
    try std.testing.expect(!slicesEqual([]const u8, &a, &c));
}

test "optionalEqual" {
    try std.testing.expect(optionalEqual([]const u8, null, null));
    try std.testing.expect(optionalEqual([]const u8, "hello", "hello"));
    try std.testing.expect(!optionalEqual([]const u8, "hello", "world"));
    try std.testing.expect(!optionalEqual([]const u8, "hello", null));
    try std.testing.expect(!optionalEqual([]const u8, null, "world"));
    try std.testing.expect(optionalEqual(u16, null, null));
    try std.testing.expect(optionalEqual(u16, 42, 42));
    try std.testing.expect(!optionalEqual(u16, 42, 24));
}

test "compareProgramConfig - unchanged" {
    var argv_slice = [_][]const u8{"hello"};
    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .numprocs = 1,
    };

    const changes = try compareProgramConfig(&prog, &prog, std.testing.allocator);

    try std.testing.expect(!changes.cmd_changed);
    try std.testing.expect(!changes.argv_changed);
    try std.testing.expect(!changes.numprocs_changed);
    try std.testing.expect(!changes.requires_respawn);
}

test "compareProgramConfig - cmd changed" {
    var argv_slice = [_][]const u8{"hello"};
    const old = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    const new = ProgramConfig{
        .cmd = "/usr/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    const changes = try compareProgramConfig(&old, &new, std.testing.allocator);

    try std.testing.expect(changes.cmd_changed);
    try std.testing.expect(!changes.argv_changed);
    try std.testing.expect(changes.requires_respawn);
}

test "compareProgramConfig - numprocs changed" {
    var argv_slice = [_][]const u8{"hello"};
    const old = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .numprocs = 2,
    };

    const new = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .numprocs = 5,
    };

    const changes = try compareProgramConfig(&old, &new, std.testing.allocator);

    try std.testing.expect(!changes.cmd_changed);
    try std.testing.expect(changes.numprocs_changed);
    try std.testing.expectEqual(@as(u32, 2), changes.numprocs_old);
    try std.testing.expectEqual(@as(u32, 5), changes.numprocs_new);
    try std.testing.expect(!changes.requires_respawn);
}

test "compareProgramConfig - config fields changed" {
    var argv_slice = [_][]const u8{"hello"};
    const old = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .autorestart = "never",
        .stopsignal = "TERM",
        .startsecs = 1,
    };

    const new = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .autorestart = "always",
        .stopsignal = "KILL",
        .startsecs = 5,
    };

    const changes = try compareProgramConfig(&old, &new, std.testing.allocator);

    try std.testing.expect(!changes.cmd_changed);
    try std.testing.expect(changes.autorestart_changed);
    try std.testing.expect(changes.stopsignal_changed);
    try std.testing.expect(changes.startsecs_changed);
    try std.testing.expect(!changes.requires_respawn);
    try std.testing.expect(changes.can_update_in_place);
}

test "compareProgramConfig - workingdir requires respawn" {
    var argv_slice = [_][]const u8{"hello"};
    const old = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .workingdir = "/tmp",
    };

    const new = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
        .workingdir = "/var",
    };

    const changes = try compareProgramConfig(&old, &new, std.testing.allocator);

    try std.testing.expect(changes.workingdir_changed);
    try std.testing.expect(changes.requires_respawn);
}

test "ConfigDiff - program added" {
    var argv_slice = [_][]const u8{"hello"};

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    try new_config.programs.map.put(std.testing.allocator, "test", prog);

    var diff = try ConfigDiff.compute(&old_config, &new_config, std.testing.allocator);
    defer diff.deinit();

    const change = diff.getChange("test");
    try std.testing.expect(change != null);
    try std.testing.expectEqual(ChangeType.added, change.?.change_type);
}

test "ConfigDiff - program removed" {
    var argv_slice = [_][]const u8{"hello"};

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    try old_config.programs.map.put(std.testing.allocator, "test", prog);

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    var diff = try ConfigDiff.compute(&old_config, &new_config, std.testing.allocator);
    defer diff.deinit();

    const change = diff.getChange("test");
    try std.testing.expect(change != null);
    try std.testing.expectEqual(ChangeType.removed, change.?.change_type);
}

test "ConfigDiff - program unchanged" {
    var argv_slice = [_][]const u8{"hello"};

    var old_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer old_config.deinit(std.testing.allocator);

    const prog = ProgramConfig{
        .cmd = "/bin/echo",
        .argv = @constCast(argv_slice[0..]),
    };

    try old_config.programs.map.put(std.testing.allocator, "test", prog);

    var new_config = Config{
        .programs = std.json.ArrayHashMap(ProgramConfig){ .map = .empty },
    };
    defer new_config.deinit(std.testing.allocator);

    try new_config.programs.map.put(std.testing.allocator, "test", prog);

    var diff = try ConfigDiff.compute(&old_config, &new_config, std.testing.allocator);
    defer diff.deinit();

    const change = diff.getChange("test");
    try std.testing.expect(change != null);
    try std.testing.expectEqual(ChangeType.unchanged, change.?.change_type);
}
