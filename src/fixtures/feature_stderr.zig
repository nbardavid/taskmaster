const std = @import("std");
const posix = std.posix;

fn sleepSeconds(secs: u64) void {
    posix.nanosleep(secs, 0);
}

pub fn main() !void {
    const stderr = std.fs.File.stderr();
    try stderr.writeAll("feature_stderr: ok\n");
    sleepSeconds(5);
}
