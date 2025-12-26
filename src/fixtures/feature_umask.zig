const std = @import("std");

pub fn main() !void {
    const filename = "feature_umask.out";
    const file = try std.fs.cwd().createFile(filename, .{ .read = true });
    defer file.close();

    const stat = try file.stat();
    const mode = stat.mode & 0o777;

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "feature_umask: mode={o}\n", .{mode});
    try std.fs.File.stdout().writeAll(text);

    std.fs.cwd().deleteFile(filename) catch {};
}
