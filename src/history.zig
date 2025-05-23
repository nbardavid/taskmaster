const history = @This();
const std = @import("std");
const Program = @import("program.zig");

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
    @cInclude("fcntl.h");
});

pub var file: std.fs.File.Writer = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    var hist_file = try std.fs.cwd().createFile("history.logs", .{ .mode = c.O_RDWR, .truncate = false });
    file = hist_file.writer();

    const content: []u8 = hist_file.readToEndAlloc(allocator, 1e9) catch |e| {
        std.log.debug("Canno't read file: {s}: cause: {!}", .{ "path", e });
        return error.FileTooBig;
    };
    defer allocator.free(content);

    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    var it = std.mem.tokenizeAny(u8, content, "\n");
    while (it.next()) |part| {
        try list.append(part);
    }

    for (list.items) |item| {
        c.add_history(@ptrCast(try Program.cstrFromzstr(allocator, item)));
    }
}
