const std = @import("std");
const ConfigParser = @This();

pub const ProgramStatus = struct {
    pid: c_int = 0,
    running: bool = false,
    nstart: u32 = 0,
    exitno: c_int = 0,
};

pub const Program = struct {
    name: []u8,
    cmd: []u8,
    status: ProgramStatus = ProgramStatus{},
};

pub const Config = struct {
    programs: []Program,

    pub fn format(self: *const Config, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        return std.json.stringify(self, .{ .whitespace = .indent_2 }, writer);
    }
};

alloc: std.mem.Allocator,
parsedConfig: std.json.Parsed(Config),
config: Config,

pub fn init(alloc: std.mem.Allocator) !ConfigParser {
    const parsed = try parse(alloc);
    return .{
        .alloc = alloc,
        .parsedConfig = parsed,
        .config = parsed.value,
    };
}

pub fn deinit(self: *ConfigParser) void {
    self.parsedConfig.deinit();
}

pub fn update(self: *ConfigParser) !void {
    self.parsedConfig.deinit();
    self.parsedConfig = try parse(self.alloc);
    self.config = self.parsedConfig.value;
}

pub fn parse(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    const file = try std.fs.cwd().openFile("./test.json", .{});
    defer file.close();

    const content: []u8 = file.readToEndAlloc(allocator, 1e9) catch |e| {
        std.log.debug("Canno't read file: {s}: cause: {!}", .{ "path", e });
        return error.FileTooBig;
    };
    defer allocator.free(content);
    // allocator.free(self);
    return try std.json.parseFromSlice(Config, allocator, content, .{});
}
