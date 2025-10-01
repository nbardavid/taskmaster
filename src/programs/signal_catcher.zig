const std = @import("std");
const posix = std.posix;

// Test program that catches and logs signals before exiting
// Purpose: Test stopsignal configuration (TERM, INT, etc.) and stoptime timeout
pub fn main() !void {
    std.debug.print("signal_catcher: Starting, will catch SIGTERM and SIGINT\n", .{});

    // Set up signal handlers
    var sa = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = @splat(0),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);

    std.debug.print("signal_catcher: Signal handlers installed, running...\n", .{});

    // Run indefinitely until signal received
    var counter: u64 = 0;
    while (!should_exit) {
        counter += 1;
        std.debug.print("signal_catcher: tick {d}\n", .{counter});
        std.Thread.sleep(std.time.ns_per_s);
    }

    std.debug.print("signal_catcher: Received signal {d}, gracefully shutting down...\n", .{last_signal});

    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("signal_catcher: Graceful shutdown complete, exiting\n", .{});
}

var should_exit: bool = false;
var last_signal: i32 = 0;

fn handleSignal(sig: i32) callconv(.c) void {
    last_signal = sig;
    should_exit = true;
}
