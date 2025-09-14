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
shell: ?Shell,
config_file: fs.File,
config: Config,
stdout: fs.File,
stdout_writer: fs.File.Writer,
server: ?net.Stream,

pub fn init(gpa: mem.Allocator, config_file: fs.File) Client {
    const stdout = fs.File.stdout();
    return .{
        .gpa = gpa,
        .config_file = config_file,
        .config = Config.init(gpa),
        .stdout = stdout,
        .stdout_writer = stdout.writer(&stdout_buffer),
        .server = null,
        .shell = null,
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

pub fn initShell(self: *Client) !void {
    self.shell = Shell.init(self.gpa, &self.stdout_writer.interface);
    try self.shell.?.enablePersistentHistory("./taskmaster.history");
}

pub fn initServer(self: *Client, address: []const u8, port: u16) !void {
    self.server = try net.tcpConnectToHost(self.gpa, address, port);
}

pub fn start(self: *Client) !void {
    var shell = self.shell orelse return error.NoShellDumbass;
    var server_buffer: [256]u8 = undefined;
    while (true) {
        const line = try shell.readline("taskmaster |> ");

        if (self.server) |*connected| {
            std.debug.print("writing to server\n", .{});
            var server_writer: net.Stream.Writer = connected.writer(&server_buffer);
            var sw: *Io.Writer = &server_writer.interface;
            try sw.writeAll(line);
            try sw.flush();
        }

        if (std.mem.containsAtLeast(u8, line, 1, "quit")) {
            break;
        } else {
            std.debug.print("debug : '{s}'\n", .{line});
        }
    }
}

pub fn deinit(self: *Client) void {
    self.config.deinit();

    if (self.shell) |*shell| {
        shell.deinit();
    }

    if (self.server) |*server| {
        server.close();
    }
}
