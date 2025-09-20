pub const Config = @This();

config_file: fs.File,

pub fn init() Config {
    return .{
        .config_file = undefined,
    };
}

pub fn open(self: *Config, config_file_path: []const u8) !void {
    self.config_file = try fs.cwd().openFile(config_file_path, .{ .mode = .read_only });
}

pub fn parseLeaky(self: *Config, gpa: mem.Allocator) !ParsedResult {
    var file_content_hasher = std.hash.Wyhash.init(0);

    var arena_instance: heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();

    var file_buffer: [1024]u8 = undefined;
    var file_reader: fs.File.Reader = self.config_file.reader(&file_buffer);
    const reader: *Io.Reader = file_reader.interface();

    const file_content = try reader.allocRemaining(arena_instance.allocator(), .unlimited);
    file_content_hasher.update(file_content);
    const parsed: json.Parsed(RawConfig) = try json.parseFromSliceLeaky(RawConfig, arena_instance.allocator(), file_content, .{});
    return ParsedResult.init(
        arena_instance,
        parsed,
        file_content,
        file_content_hasher.final(),
    );
}

pub fn reload(self: *Config) !void {
    try self.config_file.seekTo(0);
}

pub fn deinit(self: *Config) void {
    self.config_file.close();
}

pub const ParsedResult = struct {
    arena: heap.ArenaAllocator,
    parsed: json.Parsed(RawConfig),
    file_hash: u64,
    file_content: []u8,

    pub fn init(arena: heap.ArenaAllocator, parsed: json.Parsed(RawConfig), file_content: []u8, file_hash: u64) ParsedResult {
        return .{
            .arena = arena,
            .parsed = parsed,
            .file_content = file_content,
            .file_hash = file_hash,
        };
    }

    pub fn deinit(self: *ParsedResult) void {
        self.arena.deinit();
    }

    pub fn getResultMap(self: *ParsedResult) *json.ArrayHashMap(RawProcess) {
        return &self.parsed.value.processes;
    }
};

pub const RawConfig = struct {
    processes: json.ArrayHashMap(RawProcess),
};

pub const RawProcess = struct {
    name: []const u8,
    conf: RawProcessConfig,
};

pub const RawProcessConfig = struct {
    cmd: ?[]const u8 = null,
    numprocs: ?usize = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    autostart: ?bool = null,
    autorestart: ?[]const u8 = null,
    exitcodes: ?[]const i32 = null,
    starttime: ?usize = null,
    startretries: ?usize = null,
    stoptime: ?usize = null,
    stopsignal: ?[]const u8 = null,
    workingdir: ?[]const u8 = null,
    env: ?json.ArrayHashMap([]const u8),
    umask: ?[]const u8 = null,
};

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const fs = std.fs;
const json = std.json;
const Io = std.Io;
const hash = std.hash;
