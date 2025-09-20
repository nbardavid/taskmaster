const std = @import("std");
const common = @import("common");
const anyline = @import("anyline");
const Logger = common.Logger;
const Config = common.Config;
const Job = common.Job;
const Io = std.Io;
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;

const Shell = @This();

arena: heap.ArenaAllocator,
writer: *Io.Writer,
last_line: ?[]u8 = null,

pub fn init(gpa: mem.Allocator, writer: *Io.Writer) Shell {
    return .{
        .arena = heap.ArenaAllocator.init(gpa),
        .writer = writer,
        .last_line = null,
    };
}

pub fn deinit(self: *Shell) void {
    self.arena.deinit();
}

pub fn enableHistory(_: *const Shell) void {
    anyline.using_history();
}

fn allocator(self: *Shell) mem.Allocator {
    return self.arena.allocator();
}

pub fn readline(self: *Shell, prompt: []const u8) ![]u8 {
    if (self.last_line) |_| {
        self.last_line = null;
    }
    self.last_line = try anyline.readline(self.allocator(), prompt);
    try anyline.add_history(self.allocator(), self.last_line.?);
    return self.last_line.?;
}
