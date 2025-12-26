const std = @import("std");

pub fn main() !void {
    try std.fs.File.stdout().writeAll("feature_autorestart: exiting 2\n");
    std.posix.exit(2);
}
