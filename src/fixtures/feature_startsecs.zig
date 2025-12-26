const std = @import("std");
const posix = std.posix;

fn sleepSeconds(secs: u64) void {
    posix.nanosleep(secs, 0);
}

pub fn main() !void {
    try std.fs.File.stdout().writeAll("feature_startsecs: running\n");
    sleepSeconds(3);
    try std.fs.File.stdout().writeAll("feature_startsecs: done\n");
}
