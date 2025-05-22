const history = @This();
const std = @import("std");

pub var file: std.fs.File.Writer = undefined;

pub fn init() !void {
    const hist_file = try std.fs.cwd().createFile("history.logs", .{});
    defer hist_file.close();
    file = hist_file.writer();
}
