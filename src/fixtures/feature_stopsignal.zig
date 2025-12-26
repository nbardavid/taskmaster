const std = @import("std");
const posix = std.posix;

var received = false;

fn handle(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    received = true;
}

fn install() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = handle },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &action, null);
}

pub fn main() !void {
    install();
    while (!received) {
        posix.nanosleep(1, 0);
    }
    const file = try std.fs.cwd().createFile("feature_stopsignal.ok", .{});
    file.close();
}
