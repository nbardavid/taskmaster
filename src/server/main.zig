pub const warn =
    \\=============================================================
    \\ Taskmaster config sanity check:
    \\
    \\ 1. Make sure the program binary exists and is executable:
    \\    e.g. /usr/bin/taskmaster_foo
    \\    → check with: ls -l /usr/bin/taskmaster_foo
    \\
    \\ 2. Make sure the working directory exists before launch:
    \\    e.g. /tmp/testtest
    \\    → create it with: mkdir -p /tmp/testtest
    \\
    \\ 3. Make sure stdout/stderr log paths are writable:
    \\    e.g. /tmp/foo.stdout, /tmp/foo.stderr
    \\    → parent directories must exist and be writable
    \\
    \\ 4. Double-check your env values (KEY=VALUE) are correct.
    \\
    \\ If any of these are missing, you will get error.FileNotFound
    \\ during startup.
    \\=============================================================
;

pub fn main() !void {
    var gpa_instance = heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 32,
        .safety = true,
        .thread_safe = true,
        .never_unmap = true,
        .retain_metadata = true,
        .verbose_log = true,
        .resize_stack_traces = true,
    }){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    std.debug.print("{s}\n", .{warn});

    var argv = proc.argsAlloc(gpa) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer proc.argsFree(gpa, argv);

    const config_file_path = if (argv.len == 2) argv[1][0..] else "config.json";
    const socket_file_path = if (argv.len == 3) argv[2][0..] else "/tmp/taskmaster.server.sock";
    const log_file_path = "taskmaster.log";

    var logger = Logger.init(gpa, log_file_path);
    defer logger.deinit();

    var server = Server.init(gpa, &logger);
    server.start(socket_file_path, config_file_path) catch |err| {
        logger.err("Fatal error encountered {}", .{err});
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
