const std = @import("std");

// Test program that prints environment variables to stdout
// Purpose: Test environment variable configuration
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("env_printer: Environment variables:\n", .{});

    // Get environment map
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Print all environment variables
    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        std.debug.print("  {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    std.debug.print("env_printer: Done\n", .{});

    // Keep running for a bit
    std.Thread.sleep(5 * std.time.ns_per_s);
}
