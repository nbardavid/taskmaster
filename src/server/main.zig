pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var argv = proc.argsAlloc(gpa) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer proc.argsFree(gpa, argv);

    const config_file_path = if (argv.len == 2) argv[2][0..] else "config.json";
    const socket_file_path = if (argv.len == 3) argv[2][0..] else "/tmp/taskmaster.server.sock";

    var config_file = fs.cwd().openFile(config_file_path, .{}) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer config_file.close();

    var server = Server.init(gpa, socket_file_path);
    server.start(config_file) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
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
const Server = @import("Server.zig");
