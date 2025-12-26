const std = @import("std");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);
    try std.fs.File.stdout().writeAll("feature_workdir: ");
    try std.fs.File.stdout().writeAll(cwd);
    try std.fs.File.stdout().writeAll("\n");
}
