const std = @import("std");

// Test program that exits with a specific exit code from argv
// Usage: code_selector [exit_code]
// Purpose: Test exitcodes configuration option (expected vs unexpected exits)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const exit_code: u8 = if (args.len > 1)
        try std.fmt.parseInt(u8, args[1], 10)
    else
        0;

    std.debug.print("code_selector: Running for 2 seconds, then will exit with code {d}\n", .{exit_code});
    std.Thread.sleep(2 * std.time.ns_per_s); // Sleep 2 seconds to ensure it survives starttime
    std.debug.print("code_selector: Exiting with code {d}\n", .{exit_code});
    std.process.exit(exit_code);
}
