const std = @import("std");
const Shell = @import("Shell.zig");
const Client = @This();
const common = @import("common");
const Config = common.Config;
const Job = common.Job;
const Io = std.Io;
const fs = std.fs;
const net = std.net;
const heap = std.heap;
const mem = std.mem;
var stdout_buffer: [heap.pageSize()]u8 = undefined;

gpa: mem.Allocator,
shell: Shell,
config_file: fs.File,
config: Config,
stdout: fs.File,
stdout_writer: fs.File.Writer,
server: net.Stream,

pub fn init(gpa: mem.Allocator, config_file: fs.File) Client {
    const stdout = fs.File.stdout();
    return .{
        .gpa = gpa,
        .config_file = config_file,
        .config = Config.init(gpa),
        .stdout = stdout,
        .stdout_writer = stdout.writer(&stdout_buffer),
        .server = undefined,
        .shell = undefined,
    };
}

pub fn parseConfig(self: *Client) !void {
    var file_buffer: [heap.pageSize()]u8 = undefined;
    var file_reader = self.config_file.reader(&file_buffer);
    try self.config.parse(&file_reader.interface);
}

pub fn printConfig(self: *Client) !void {
    const programs = self.config.getParsed();
    const stdout = &self.stdout_writer.interface;
    for (programs) |program| {
        try stdout.print("{f}\n", .{program});
    }
    try stdout.flush();
}

pub fn deinit(self: *Client) void {
    self.config.deinit();
}
