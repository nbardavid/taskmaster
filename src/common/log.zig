const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const Io = std.Io;
const fs = std.fs;
const TimeParts = @import("log_utils.zig").TimeParts;

pub const Logger = struct {
    const Self = @This();

    const Message = struct {
        seq: u64,
        bytes: []u8,
    };

    gpa: mem.Allocator,
    owned_file_path: []const u8,
    owned_file: ?fs.File,
    owned_writer: fs.File.Writer,
    owned_buffer: [heap.pageSize()]u8,
    sinks: std.ArrayList(*Io.Writer),
    thread: ?std.Thread = null,
    lock: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    stopping: bool = false,

    queue: []?*Message,
    q_cap: usize,
    q_head: usize = 0,
    q_tail: usize = 0,
    q_len: usize = 0,
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(gpa: mem.Allocator, log_file_path: []const u8, queue_capacity: usize) Self {
        return .{
            .owned_file_path = log_file_path,
            .owned_file = null,
            .owned_buffer = undefined,
            .owned_writer = undefined,
            .gpa = gpa,
            .q_cap = @max(queue_capacity, 1),
            .sinks = std.ArrayList(*Io.Writer).empty,
            .queue = &[_]?*Message{},
        };
    }

    pub fn start(self: *Self) !void {
        self.lock.lock();
        self.stopping = false;
        self.lock.unlock();
        self.queue = try self.gpa.alloc(?*Message, self.q_cap);
        @memset(self.queue, null);
        @memset(self.owned_buffer[0..], 0xaa);
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn stopAndJoin(self: *Self) void {
        self.lock.lock();
        self.stopping = true;
        self.not_empty.broadcast();
        self.lock.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn addOwnedFileSink(self: *Self, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        self.owned_file = file;
        self.owned_writer = file.writer(&self.owned_buffer);
        try self.sinks.append(self.gpa, &self.owned_writer.interface);
    }

    pub fn deinit(self: *Self) void {
        self.lock.lock();
        while (self.q_len > 0) {
            const msg = self.queue[self.q_head].?;
            self.queue[self.q_head] = null;
            self.q_head = (self.q_head + 1) % self.q_cap;
            self.q_len -= 1;
            self.lock.unlock();

            for (self.sinks.items) |sink| {
                sink.writeAll(msg.bytes) catch {};
                sink.flush() catch {};
            }
            self.freeMessage(msg);

            self.lock.lock();
        }
        self.lock.unlock();

        self.sinks.deinit(self.gpa);
        if (self.owned_file) |*f| f.close();
        self.gpa.free(self.queue);
        self.gpa.destroy(self);
    }

    pub fn addSink(self: *Self, sink: *Io.Writer) !void {
        try self.sinks.append(self.gpa, sink);
    }

    fn logInternal(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const msg = try self.makeMessage(fmt, args);
        errdefer self.freeMessage(msg);

        self.lock.lock();
        defer self.lock.unlock();

        while (self.q_len == self.q_cap and !self.stopping) {
            self.not_full.wait(&self.lock);
        }
        if (self.stopping) return error.ShuttingDown;

        self.queue[self.q_tail] = msg;
        self.q_tail = (self.q_tail + 1) % self.q_cap;
        self.q_len += 1;
        self.not_empty.signal();
    }

    pub fn log(self: *Self, comptime level: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const timestamp: u64 = @intCast(@abs(std.time.milliTimestamp()));
        const tm = TimeParts.fromMsTimestamp(timestamp);
        try self.logInternal("[{f}] [{s}] " ++ fmt ++ "\n", .{ tm, level } ++ args);
    }

    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const timestamp: u64 = @intCast(@abs(std.time.milliTimestamp()));
        const tm = TimeParts.fromMsTimestamp(timestamp);
        try self.logInternal("[{f}] [INFO] " ++ fmt ++ "\n", .{tm} ++ args);
    }

    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const timestamp: u64 = @intCast(@abs(std.time.milliTimestamp()));
        const tm = TimeParts.fromMsTimestamp(timestamp);
        try self.logInternal("[{f}] [DEBUG] " ++ fmt ++ "\n", .{tm} ++ args);
    }

    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const timestamp: u64 = @intCast(@abs(std.time.milliTimestamp()));
        const tm = TimeParts.fromMsTimestamp(timestamp);
        try self.logInternal("[{f}] [WARN] " ++ fmt ++ "\n", .{tm} ++ args);
    }

    pub fn fatal(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const timestamp: u64 = @intCast(@abs(std.time.milliTimestamp()));
        const tm = TimeParts.fromMsTimestamp(timestamp);
        try self.logInternal("[{f}] [ERROR] " ++ fmt ++ "\n", .{tm} ++ args);
    }

    fn makeMessage(self: *Self, comptime fmt: []const u8, args: anytype) !*Message {
        const seq = self.seq.fetchAdd(1, .monotonic);
        const bytes = try std.fmt.allocPrint(self.gpa, fmt, args);
        const msg = try self.gpa.create(Message);
        msg.* = .{ .seq = seq, .bytes = bytes };
        return msg;
    }

    fn freeMessage(self: *Self, msg: *Message) void {
        self.gpa.free(msg.bytes);
        self.gpa.destroy(msg);
    }

    fn worker(self: *Self) void {
        while (true) {
            self.lock.lock();
            while (self.q_len == 0 and !self.stopping) {
                self.not_empty.wait(&self.lock);
            }
            if (self.q_len == 0 and self.stopping) {
                self.lock.unlock();
                break;
            }

            const msg = self.queue[self.q_head].?;
            self.queue[self.q_head] = null;
            self.q_head = (self.q_head + 1) % self.q_cap;
            self.q_len -= 1;
            self.not_full.signal();
            self.lock.unlock();

            for (self.sinks.items) |sink| {
                sink.writeAll(msg.bytes) catch {};
            }

            self.freeMessage(msg);
        }
    }
};
