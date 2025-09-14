const std = @import("std");
const common = @import("common");
const anyline = @import("anyline");
const Logger = common.Logger;
const Config = common.Config;
const Job = common.Job;
const Io = std.Io;
const fs = std.fs;
const mem = std.mem;

const Shell = @This();

gpa: mem.Allocator,
writer: *Io.Writer,
last_line: ?[]u8 = null,

pub fn init(gpa: mem.Allocator, writer: *Io.Writer) Shell {
    return .{
        .gpa = gpa,
        .writer = writer,
        .last_line = null,
    };
}

pub fn deinit(self: *Shell) void {
    std.debug.assert(self.last_line == null);
    if (self.last_line) |line| {
        self.gpa.free(line);
    }
}

pub fn enableHistory(_: *const Shell) !void {
    anyline.using_history();
}

pub fn enablePersistentHistory(self: *const Shell, path: []const u8) !void {
    const path_buffer: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd();
    const absolute_path = try cwd.realpath(path, path_buffer);
    self.enableHistory();
    anyline.write_history(self.gpa, absolute_path);
}

pub fn readline(self: *Shell, prompt: []const u8) ![]u8 {
    if (self.last_line) {
        self.gpa.free(self.last_line);
        self.last_line = null;
    }
    self.last_line = try anyline.readline(self.gpa, prompt);
    return self.last_line;
}
