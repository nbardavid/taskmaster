const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const Io = std.Io;
const fs = std.fs;
const TimeParts = @import("log_utils.zig").TimeParts;
const Thread = std.Thread;
const atomic = std.atomic;
const ArrayList = std.ArrayListUnmanaged;
const builtin = @import("builtin");

var file_buffer: [std.heap.pageSize()]u8 = undefined;

pub const Logger = struct {
    const Self = @This();

    stop: atomic.Value(bool),
    mtx: Thread.Mutex,
    gpa: mem.Allocator,
    log_file: ?fs.File,
    log_file_path: []const u8,
    log_file_writer: std.fs.File.Writer,

    pub const LogLevel = enum {
        default,
        info,
        debug,
        warn,
        err,
        fatal,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const tag: []const u8 = switch (self) {
                .err => "[error]",
                .info, .default => "[info]",
                .debug => "[debug]",
                .warn => "[warn]",
                .fatal => "[fatal]",
            };
            try writer.print("{s}", .{tag});
        }
    };

    pub fn init(gpa: mem.Allocator, log_file_path: []const u8) Logger {
        return .{
            .stop = .{ .raw = false },
            .gpa = gpa,
            .mtx = Thread.Mutex{},
            .log_file = null,
            .log_file_path = log_file_path,
            .log_file_writer = undefined,
        };
    }

    pub fn deinit(self: *Logger) void {
        defer self.* = undefined;

        if (self.log_file) |log_file| {
            log_file.close();
        }
    }

    pub fn start(self: *Logger) !void {
        if (fs.cwd().access(self.log_file_path, .{ .mode = .read_write })) {
            self.log_file = try fs.cwd().openFile(self.log_file_path, .{ .mode = .read_write });
        } else |e| {
            std.debug.print("{}", .{e});
            const dirname = std.fs.path.dirname(self.log_file_path) orelse return error.InvalidPath;
            try fs.cwd().makePath(dirname);
            self.log_file = try fs.cwd().createFile(self.log_file_path, .{ .truncate = false });
        }
        self.log_file_writer = self.log_file.?.writer(&file_buffer);
    }

    fn timestamp(_: *const Logger) u64 {
        return @as(u64, @intCast(std.time.timestamp()));
    }

    fn logInternal(self: *Logger, comptime lvl: LogLevel, time: u64, comptime str: []const u8, args: anytype) void {
        self.mtx.lock();
        defer self.mtx.unlock();
        std.debug.print("{f} | {f}" ++ str ++ "\n", .{ TimeParts.fromMsTimestamp(time), lvl } ++ args);
        if (self.log_file) |_| {
            const writer = &self.log_file_writer.interface;
            writer.print("{f} | {f}" ++ str ++ "\n", .{ TimeParts.fromMsTimestamp(time), lvl } ++ args) catch {};
        }
    }

    pub fn err(self: *Logger, comptime str: []const u8, args: anytype) void {
        self.logInternal(.err, self.timestamp(), str, args);
    }

    pub fn warn(self: *Logger, comptime str: []const u8, args: anytype) void {
        self.logInternal(.warn, self.timestamp(), str, args);
    }

    pub fn info(self: *Logger, comptime str: []const u8, args: anytype) void {
        self.logInternal(.info, self.timestamp(), str, args);
    }

    pub fn debug(self: *Logger, comptime str: []const u8, args: anytype) void {
        self.logInternal(.debug, self.timestamp(), str, args);
    }
};
