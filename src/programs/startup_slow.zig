const std = @import("std");

// Test program that takes time to start, then runs successfully
// Usage: startup_slow [startup_seconds] [run_seconds]
// Purpose: Test starttime threshold - program must run for starttime before considered "started"
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const startup_secs: u64 = if (args.len > 1)
        try std.fmt.parseInt(u64, args[1], 10)
    else
        5;

    const run_secs: u64 = if (args.len > 2)
        try std.fmt.parseInt(u64, args[2], 10)
    else
        10;

    std.debug.print("startup_slow: Simulating slow startup ({d}s), then running for {d}s\n", .{ startup_secs, run_secs });

    // Simulate slow startup
    for (0..startup_secs) |i| {
        std.debug.print("startup_slow: initializing... {d}/{d}\n", .{ i + 1, startup_secs });
        std.Thread.sleep(std.time.ns_per_s);
    }

    std.debug.print("startup_slow: Startup complete, now running\n", .{});

    // Run normally
    for (0..run_secs) |i| {
        std.debug.print("startup_slow: running... {d}/{d}\n", .{ i + 1, run_secs });
        std.Thread.sleep(std.time.ns_per_s);
    }

    std.debug.print("startup_slow: Exiting successfully\n", .{});
}
