const std = @import("std");
const posix = std.posix;

fn sleepSeconds(secs: u64) void {
    posix.nanosleep(secs, 0);
}

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("feature_stdout: ok\n");
    sleepSeconds(5);
}
