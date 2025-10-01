const std = @import("std");

pub const Command = packed struct(u16) {
    cmd: enum(u8) {
        status,
        start,
        restart,
        stop,
        reload,
        quit,
        dump,
    },
    payload_len: u8,
};

pub const ResponseStatus = enum(u8) {
    success = 0,
    err = 1,
    not_found = 2,
};

pub const Response = packed struct(u32) {
    status: ResponseStatus,
    reserved: u8 = 0,
    payload_len: u16,
};

pub const ResponseBuilder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResponseBuilder {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResponseBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn append(self: *ResponseBuilder, text: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, text);
    }

    pub fn appendFmt(self: *ResponseBuilder, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.buffer.appendSlice(self.allocator, formatted);
    }

    pub fn getPayload(self: *const ResponseBuilder) []const u8 {
        return self.buffer.items;
    }

    pub fn getLen(self: *const ResponseBuilder) u16 {
        const len = self.buffer.items.len;
        return if (len > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(len);
    }

    pub fn clear(self: *ResponseBuilder) void {
        self.buffer.clearRetainingCapacity();
    }
};
