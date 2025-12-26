const std = @import("std");
const posix = std.posix;

fn sleepSeconds(secs: u64) void {
    posix.nanosleep(secs, 0);
}

pub fn main() !void {
    try std.fs.File.stdout().writeAll("feature_numprocs: ok\n");
    sleepSeconds(5);
}
