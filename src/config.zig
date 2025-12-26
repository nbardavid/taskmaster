const std = @import("std");
const posix = std.posix;

const ProcessGroup = @import("process/ProcessGroup.zig").ProcessGroup;

pub const ProgramConfig = struct {
    cmd: []const u8 = &.{},
    argv: [][]const u8 = &.{},
    numprocs: u32 = 1,
    autostart: bool = true,
    autorestart: []const u8 = "unexpected",
    exitcodes: []const u32 = &[_]u32{0},
    starttime: u32 = 1,
    startsecs: u32 = 1,
    startretries: u32 = 3,
    stopsignal: []const u8 = "TERM",
    stoptime: u32 = 10,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    env: ?std.json.ArrayHashMap([]const u8) = null,
    workingdir: ?[]const u8 = null,
    umask: ?u16 = null,
};

pub const Config = struct {
    programs: std.json.ArrayHashMap(ProgramConfig),

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.programs.deinit(allocator);
    }
};

pub const ConfigParser = struct {
    allocator: std.mem.Allocator,
    parsed: ?std.json.Parsed(Config) = null,

    pub fn init(gpa: std.mem.Allocator) ConfigParser {
        return .{ .allocator = gpa };
    }

    pub fn deinit(self: *ConfigParser) void {
        if (self.parsed) |*parsed| {
            parsed.deinit();
        }
    }

    pub fn parseFromFile(self: *ConfigParser, path: []const u8) !void {
        if (self.parsed) |*parsed| {
            parsed.deinit();
            self.parsed = null;
        }

        const content = try std.fs.cwd().readFileAlloc(path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(content);

        self.parsed = try std.json.parseFromSlice(Config, self.allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn parseFromSlice(self: *ConfigParser, json_content: []const u8) !void {
        if (self.parsed) |*parsed| {
            parsed.deinit();
            self.parsed = null;
        }

        self.parsed = try std.json.parseFromSlice(Config, self.allocator, json_content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn getConfig(self: *const ConfigParser) !*const Config {
        return if (self.parsed) |*parsed| &parsed.value else error.NoConfigLoaded;
    }

    pub fn parseAutoRestart(restart_str: []const u8) !ProcessGroup.AutoRestart {
        if (std.mem.eql(u8, restart_str, "always")) return .always;
        if (std.mem.eql(u8, restart_str, "never")) return .never;
        if (std.mem.eql(u8, restart_str, "unexpected")) return .unexpected;
        return error.InvalidAutoRestart;
    }

    pub fn parseSignal(signal_str: []const u8) !u8 {
        const sig = std.meta.stringToEnum(posix.SIG, signal_str) orelse return error.InvalidSignal;
        return @intCast(@intFromEnum(sig));
    }

    pub fn configureProcessGroup(
        program_config: *const ProgramConfig,
        process_group: *ProcessGroup,
        program_name: []const u8,
    ) !void {
        try process_group.setName(program_name);
        try process_group.setCmd(program_config.cmd);
        if (program_config.argv.len > 0) {
            try process_group.setArgv(program_config.argv);
        } else {
            const fallback_argv = [_][]const u8{program_config.cmd};
            try process_group.setArgv(&fallback_argv);
        }

        process_group.setNumProcs(program_config.numprocs);
        process_group.autostart = program_config.autostart;
        process_group.setStartRetries(program_config.startretries);
        process_group.setStartDelay(program_config.starttime);
        process_group.setStartSecs(program_config.startsecs);
        process_group.stop_timeout = program_config.stoptime;

        const autorestart = try parseAutoRestart(program_config.autorestart);
        process_group.autorestart = autorestart;

        const stop_signal = try parseSignal(program_config.stopsignal);
        process_group.setStopSignal(stop_signal);

        const allocator = process_group.arena.allocator();
        process_group.exitcodes = try allocator.dupe(u32, program_config.exitcodes);

        if (program_config.stdout) |stdout_path| {
            try process_group.setStdoutPath(stdout_path);
            process_group.redirect_stdout = true;
        } else {
            process_group.redirect_stdout = false;
        }

        if (program_config.stderr) |stderr_path| {
            try process_group.setStderrPath(stderr_path);
            process_group.redirect_stderr = true;
        } else {
            process_group.redirect_stderr = false;
        }

        if (program_config.env) |*env_map| {
            var env_list: std.ArrayList([]const u8) = .empty;
            defer env_list.deinit(allocator);

            var iter = env_map.map.iterator();
            while (iter.next()) |entry| {
                const env_str = try std.fmt.allocPrint(
                    allocator,
                    "{s}={s}",
                    .{ entry.key_ptr.*, entry.value_ptr.* },
                );
                try env_list.append(allocator, env_str);
            }

            try process_group.setEnv(env_list.items);
        }

        if (program_config.workingdir) |wd| {
            try process_group.setWorkingDir(wd);
        }

        if (program_config.umask) |mask| {
            process_group.setUmask(mask);
        }
    }
};

test "parse config from json" {
    const json_content =
        \\{
        \\  "programs": {
        \\    "ping": {
        \\      "cmd": "/usr/bin/ping",
        \\      "argv": ["www.google.com"],
        \\      "numprocs": 1,
        \\      "autostart": false,
        \\      "autorestart": "never",
        \\      "exitcodes": [0],
        \\      "starttime": 2,
        \\      "startsecs": 4,
        \\      "startretries": 2,
        \\      "stopsignal": "TERM",
        \\      "stoptime": 3,
        \\      "stdout": "/tmp/eval_env.stdout",
        \\      "stderr": "/tmp/eval_env.stderr",
        \\      "workingdir": "/tmp",
        \\      "umask": 18,
        \\      "env": {
        \\        "TEST_VAR1": "test_value_1",
        \\        "TEST_VAR2": "test_value_2"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var parser = ConfigParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.parseFromSlice(json_content);

    const config = try parser.getConfig();

    try std.testing.expectEqual(@as(usize, 1), config.programs.map.count());

    const ping_entry = config.programs.map.get("ping");
    try std.testing.expect(ping_entry != null);

    const ping = ping_entry.?;
    try std.testing.expectEqualStrings("/usr/bin/ping", ping.cmd);
    try std.testing.expectEqual(@as(usize, 1), ping.argv.len);
    try std.testing.expectEqualStrings("www.google.com", ping.argv[0]);
    try std.testing.expectEqual(@as(u32, 1), ping.numprocs);
    try std.testing.expectEqual(false, ping.autostart);
    try std.testing.expectEqualStrings("never", ping.autorestart);
    try std.testing.expectEqual(@as(u32, 2), ping.starttime);
    try std.testing.expectEqual(@as(u32, 4), ping.startsecs);
    try std.testing.expectEqual(@as(u32, 2), ping.startretries);
    try std.testing.expectEqualStrings("/tmp", ping.workingdir.?);
    try std.testing.expectEqual(@as(u16, 18), ping.umask.?);
}

test "parse autorestart values" {
    try std.testing.expectEqual(ProcessGroup.AutoRestart.always, try ConfigParser.parseAutoRestart("always"));
    try std.testing.expectEqual(ProcessGroup.AutoRestart.never, try ConfigParser.parseAutoRestart("never"));
    try std.testing.expectEqual(ProcessGroup.AutoRestart.unexpected, try ConfigParser.parseAutoRestart("unexpected"));
    try std.testing.expectError(error.InvalidAutoRestart, ConfigParser.parseAutoRestart("invalid"));
}

test "parse signal values" {
    try std.testing.expectEqual(@intFromEnum(posix.SIG.TERM), try ConfigParser.parseSignal("TERM"));
    try std.testing.expectEqual(@intFromEnum(posix.SIG.KILL), try ConfigParser.parseSignal("KILL"));
    try std.testing.expectEqual(@intFromEnum(posix.SIG.INT), try ConfigParser.parseSignal("INT"));
    try std.testing.expectError(error.InvalidSignal, ConfigParser.parseSignal("INVALID"));
}

test "configure process group from config" {
    const json_content =
        \\{
        \\  "programs": {
        \\    "test": {
        \\      "cmd": "/bin/echo",
        \\      "argv": ["hello", "world"],
        \\      "numprocs": 2,
        \\      "autostart": true,
        \\      "autorestart": "always",
        \\      "exitcodes": [0, 1],
        \\      "starttime": 5,
        \\      "startsecs": 6,
        \\      "startretries": 3,
        \\      "stopsignal": "KILL",
        \\      "stoptime": 10,
        \\      "stdout": "/tmp/test.out",
        \\      "stderr": "/tmp/test.err",
        \\      "workingdir": "/tmp",
        \\      "umask": 63
        \\    }
        \\  }
        \\}
    ;

    var parser = ConfigParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.parseFromSlice(json_content);

    const config = try parser.getConfig();
    const test_config = config.programs.map.get("test").?;

    var pg = ProcessGroup.init(std.testing.allocator);
    defer pg.deinit();

    try ConfigParser.configureProcessGroup(&test_config, &pg, "test");

    try std.testing.expectEqualStrings("test", pg.name);
    try std.testing.expectEqualStrings("/bin/echo", pg.cmd);
    try std.testing.expectEqual(@as(u32, 2), pg.numprocs);
    try std.testing.expectEqual(true, pg.autostart);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.start_delay);
    try std.testing.expectEqual(@as(u32, 6), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 3), pg.start_retries);
    try std.testing.expectEqual(@intFromEnum(posix.SIG.KILL), pg.stop_signal);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);
    try std.testing.expectEqualStrings("/tmp/test.out", pg.stdout_path);
    try std.testing.expectEqualStrings("/tmp", pg.working_directory);
    try std.testing.expectEqual(@as(u16, 63), pg.umask);
    try std.testing.expectEqualStrings("/tmp/test.err", pg.stderr_path);
    try std.testing.expectEqual(@as(usize, 2), pg.exitcodes.len);
}
