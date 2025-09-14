pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
    _ = gpa;

    const address = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 8383);
    var server = try net.Address.listen(address, .{
        .reuse_address = true,
    });
    defer server.deinit();

    var stdout_buffer: [0]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var client: ?net.Server.Connection = null;
    var read_buffer: [1]u8 = undefined;
    while (true) {
        if (client) |connected| {
            var stream_reader: net.Stream.Reader = connected.stream.reader(&read_buffer);
            const stream: *Io.Reader = stream_reader.interface();
            _ = try stream.streamDelimiterEnding(stdout, 0x00);
            try stdout.flush();
        } else {
            client = try server.accept();
            std.debug.print("new client\n", .{});
        }
    }
}

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
const net = std.net;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;
