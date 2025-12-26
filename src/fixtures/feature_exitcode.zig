const std = @import("std");

pub fn main() !void {
    try std.fs.File.stdout().writeAll("feature_exitcode: exiting 42\n");
    std.posix.exit(42);
}
