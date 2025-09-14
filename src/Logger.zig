pub const Logger = @This();

pub const Message = struct {
    timestamp: usize,
    msg: []const u8,

    pub fn lessThan(comptime _: void, m1: *Message, m2: *Message) math.Order {
        if (m1.timestamp < m2.timestamp) {
            return .lt;
        } else if (m1.timestamp == m2.timestamp) {
            return .eq;
        } else {
            return .gt;
        }
    }
};

mpool: heap.MemoryPool(Message),
stop: std.atomic.Value(bool) = .{ .raw = false },
thread: Thread,
gpa: mem.Allocator,
mtx: Thread.Mutex,
mailbox: PriorityQueue(*Message, void, Message.lessThan),
sinks: ArrayList(*Io.Writer),

pub fn init(gpa: mem.Allocator) Logger {
    return .{
        .mpool = heap.MemoryPool(Message).init(gpa),
        .gpa = gpa,
        .mtx = .{},
        .mailbox = PriorityQueue(*Message, void, Message.lessThan),
        .sinks = ArrayList(*Io.Writer).empty,
    };
}

pub fn deinit(logger: *Logger) void {
    logger.mtx.lock();
    defer logger.mtx.unlock();

    logger.mailbox.deinit();
    logger.mpool.deinit();
}

fn createMessage(logger: *Logger) !*Message {
    logger.mtx.lock();
    defer logger.mtx.unlock();
    return try logger.mpool.create();
}

fn lock(logger: *Logger) void {
    logger.mtx.lock();
}

fn unlock(logger: *Logger) void {
    logger.mtx.unlock();
}

fn destroyMessage(logger: *Logger, message: *Message) void {
    logger.mtx.lock();
    defer logger.mtx.unlock();
    logger.gpa.free(message.msg);
    return try logger.mpool.destroy(message);
}

pub fn log(logger: *Logger, comptime fmt: []const u8, args: anytype) !void {
    const timestamp: usize = @truncate(time.timestamp());
    const buffer = try std.fmt.allocPrint(logger.gpa, "[d] : " ++ fmt, .{timestamp} ++ args);
    logger.lock();
    defer logger.unlock();
    const msg = try logger.createMessage();
    msg.* = .{
        .timestamp = timestamp,
        .msg = buffer,
    };
    logger.mailbox.add(msg);
}

fn start(logger: *Logger) !void {
    while (logger.stop.bitSet(false, .monotonic) == 1) {
        logger.lock();
        defer logger.unlock();
        const msg = logger.mailbox.removeMin();
        for (logger.sinks.items) |sink| {
            sink.writeAll(msg.msg);
            sink.flush();
        }
        logger.destroyMessage(msg);
    }
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const time = std.time;
const heap = std.heap;
const fs = std.fs;
const math = std.math;
const PriorityQueue = std.PriorityDequeue;
const Thread = std.Thread;
const ArrayList = std.ArrayListUnmanaged;
