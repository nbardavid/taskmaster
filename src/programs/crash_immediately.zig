const std = @import("std");

// Test program that crashes immediately before starttime can elapse
// Purpose: Test startretries and abort behavior after too many failed starts
// NOTE: This intentionally exits quickly to trigger the "failed to start" logic
pub fn main() !void {
    std.debug.print("crash_immediately: Starting and crashing immediately (before starttime)\n", .{});
    // Exit immediately with unexpected code to trigger startretries logic
    std.process.exit(42);
}