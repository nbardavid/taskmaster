const std = @import("std");

// Test program that prints its current working directory
// Purpose: Test workingdir configuration option
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    std.debug.print("workdir_printer: Current working directory: {s}\n", .{cwd});

    // Keep running for a bit
    std.Thread.sleep(5 * std.time.ns_per_s);
}
