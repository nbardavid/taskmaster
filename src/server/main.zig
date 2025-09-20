pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var argv = proc.argsAlloc(gpa) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer proc.argsFree(gpa, argv);

    const socket_file_path = if (argv.len == 2) argv[1][0..] else "/tmp/taskmaster.server.sock";
    fs.cwd().deleteFile(socket_file_path) catch |err| {
        log.err("failed to delete {s} : {}", .{ socket_file_path, err });
    };

    // Create socket
    const sockfd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    defer posix.close(sockfd);

    var addr = try std.net.Address.initUnix(socket_file_path);
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 1);

    const stream = net.connectUnixSocket(socket_file_path) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer stream.close();
}

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
const net = std.net;
const log = std.log;
const posix = std.posix;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;
