const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const value = std.process.getEnvVarOwned(allocator, "FEATURE_ENV") catch {
        try std.fs.File.stderr().writeAll("feature_env: missing FEATURE_ENV\n");
        std.posix.exit(1);
    };
    defer allocator.free(value);

    if (!std.mem.eql(u8, value, "ok")) {
        try std.fs.File.stderr().writeAll("feature_env: FEATURE_ENV != ok\n");
        std.posix.exit(1);
    }

    try std.fs.File.stdout().writeAll("feature_env: ok\n");
}
