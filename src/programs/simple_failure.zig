const std = @import("std");

// Test program that runs briefly then exits with code 1
// Purpose: Test unexpected exit codes, "unexpected" autorestart policy
pub fn main() !void {
    std.debug.print("simple_failure: Starting, will run briefly then exit with failure\n", .{});
    // Sleep long enough to pass starttime threshold (2 seconds to be safe)
    std.Thread.sleep(2 * std.time.ns_per_s);
    std.debug.print("simple_failure: Exiting with code 1\n", .{});
    std.process.exit(1);
}