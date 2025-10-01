const std = @import("std");

// Test program that runs for a specified time (or indefinitely) and responds to signals
// Usage: long_runner [seconds] (0 or no arg = run forever)
// Purpose: Test graceful stop, kill timeout, "always" autorestart
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const duration_secs: u64 = if (args.len > 1)
        try std.fmt.parseInt(u64, args[1], 10)
    else
        0; // 0 means run forever

    std.debug.print("long_runner: Starting (duration={d}s, 0=forever)\n", .{duration_secs});

    const start = std.time.milliTimestamp();
    var counter: u64 = 0;

    while (true) {
        counter += 1;
        std.debug.print("long_runner: tick {d}\n", .{counter});
        std.Thread.sleep(std.time.ns_per_s);

        if (duration_secs > 0) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start)) / 1000;
            if (elapsed >= duration_secs) {
                std.debug.print("long_runner: Completed duration, exiting\n", .{});
                break;
            }
        }
    }
}
