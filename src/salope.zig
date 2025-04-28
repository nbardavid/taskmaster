const std = @import("std");

const Salope = @This();

content: []const u8,
pub fn init() Salope {
    return .{
        .content = @as([]const u8, &[_]u8{ 's', 'a', 'l', 'u', 't' }),
    };
}
