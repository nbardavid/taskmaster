const std = @import("std");

// Test program that continuously writes to stdout and stderr
// Purpose: Test stdout/stderr redirection configuration
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const duration_secs: u64 = if (args.len > 1)
        try std.fmt.parseInt(u64, args[1], 10)
    else
        30;

    std.debug.print("stdout_spammer: Starting (duration={d}s)\n", .{duration_secs});

    var stdout_buff: [128]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buff);
    const stdout = &stdout_writer.interface;

    var stderr_buff: [128]u8 = undefined;
    const stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buff);
    const stderr = &stderr_writer.interface;

    const start = std.time.milliTimestamp();
    var counter: u64 = 0;

    while (true) {
        counter += 1;

        // Write to stdout
        try stdout.print("[STDOUT] Message #{d}\n", .{counter});

        // Write to stderr
        try stderr.print("[STDERR] Error message #{d}\n", .{counter});

        std.Thread.sleep(std.time.ns_per_s);

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start)) / 1000;
        if (elapsed >= duration_secs) {
            break;
        }
    }

    std.debug.print("stdout_spammer: Exiting\n", .{});
}
