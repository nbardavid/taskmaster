const std = @import("std");

// Test program that runs briefly then exits with code 0
// Purpose: Test autostart, expected exit codes, "never" autorestart
pub fn main() !void {
    std.debug.print("simple_success: Starting, will run briefly then exit successfully\n", .{});
    // Sleep long enough to pass starttime threshold (2 seconds to be safe)
    std.Thread.sleep(2 * std.time.ns_per_s);
    std.debug.print("simple_success: Exiting with code 0\n", .{});
    std.process.exit(0);
}