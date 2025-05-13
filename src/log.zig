const log = @This();
const std = @import("std");

const c = @cImport({
    @cInclude("sys/time.h");
    @cInclude("time.h");
});

const Color = @import("color.zig");
const Program = @import("program.zig");

pub var file: std.fs.File.Writer = undefined;

pub fn programExit(name: []const u8, exit_code: i32) void {
    log.time();
    file.print("{s}[{s}-{s}]{s} {s}{s}{s} has exited with status code {s}{d}{s}", .{
        Color.gray,  Color.red,   Color.gray, Color.reset,
        Color.reset, name,        Color.gray, Color.green,
        exit_code,   Color.reset,
    });
}

pub fn programStart(name: []const u8) void {
    log.time();
    file.print("{s}[{s}+{s}]{s} {s}", .{
        Color.gray,  Color.green, Color.gray,
        Color.reset, name,
    });
}

pub fn isProgramRunning(alloc: std.mem.Allocator, program: *Program) !void {
    _ = alloc;
    if (program.status.running) {
        std.log.info("{s}: {s}running{s}", .{ program.config.name, Color.green, Color.reset });
    } else {
        std.log.info("{s}: {s}stopped{s}", .{ program.config.name, Color.red, Color.reset });
    }
}

pub fn time() !void {
    var tv: c.timeval = undefined;
    const err = c.gettimeofday(&tv, null);
    if (err != 0) return error.GetTimeFailed;

    const now: c.time_t = tv.tv_sec;
    const tm = c.localtime(&now);
    const ctime = tm.*;

    try file.print("{s}[{d}:{:0>2}:{:0>2}]{s} ", .{ Color.gray, ctime.tm_hour, @as(u8, @intCast(ctime.tm_min)), @as(u8, @intCast(ctime.tm_sec)), Color.reset });
}
