const std = @import("std");
const posix = std.posix;

fn installIgnore() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &action, null);
}

pub fn main() !void {
    installIgnore();
    try std.fs.File.stdout().writeAll("feature_stoptime: ignoring TERM\n");
    while (true) {
        posix.nanosleep(1, 0);
    }
}
