const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const in_test = builtin.is_test;

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = @This();

file: std.fs.File,
mutex: std.Thread.Mutex,
io: Io,
allocator: std.mem.Allocator,

pub fn init(log_path: []const u8, io: Io, allocator: std.mem.Allocator) !Logger {
    const file = if (std.fs.path.isAbsolute(log_path))
        try std.fs.createFileAbsolute(log_path, .{ .read = true, .truncate = false })
    else
        try std.fs.cwd().createFile(log_path, .{ .read = true, .truncate = false });

    try file.seekFromEnd(0);

    return Logger{
        .file = file,
        .mutex = .{},
        .io = io,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Logger) void {
    self.file.close();
}

pub fn log(
    self: *Logger,
    level: LogLevel,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const timestamp = Io.Clock.real.now(self.io) catch {
        _ = self.file.write("ERROR: Failed to retrieve current timestamp\n") catch {};
        return;
    };
    const timestamp_s = timestamp.toSeconds();
    const datetime = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp_s) };
    const day_seconds = datetime.getDaySeconds();
    const epoch_day = datetime.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const log_line = std.fmt.allocPrint(
        self.allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2} [{s}] " ++ fmt ++ "\n",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            level.toString(),
        } ++ args,
    ) catch {
        _ = self.file.write("ERROR: Log message formatting failure\n") catch {};
        return;
    };
    defer self.allocator.free(log_line);

    _ = self.file.write(log_line) catch {};
    if (!in_test) {
        _ = std.fs.File.stderr().write(log_line) catch {};
    }
}

pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.log(.debug, fmt, args);
}

pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.log(.info, fmt, args);
}

pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.log(.warn, fmt, args);
}

pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
    self.log(.err, fmt, args);
}

pub fn logProgramStarted(self: *Logger, name: []const u8, pid: i32) void {
    self.info("Program '{s}' started (PID: {})", .{ name, pid });
}

pub fn logProgramStopped(self: *Logger, name: []const u8, pid: i32) void {
    self.info("Program '{s}' stopped (PID: {})", .{ name, pid });
}

pub fn logProgramRestarted(self: *Logger, name: []const u8, pid: i32) void {
    self.info("Program '{s}' restarted (PID: {})", .{ name, pid });
}

pub fn logProgramDied(self: *Logger, name: []const u8, pid: i32, code: i32) void {
    self.warn("Program '{s}' exited unexpectedly (PID: {}, code: {})", .{ name, pid, code });
}

pub fn logProgramKilled(self: *Logger, name: []const u8, pid: i32, signal: i32) void {
    self.warn("Program '{s}' killed by signal (PID: {}, signal: {})", .{ name, pid, signal });
}

pub fn logProgramFatal(self: *Logger, name: []const u8) void {
    self.err("Program '{s}' exceeded maximum retries and is now fatal", .{name});
}

pub fn logConfigLoaded(self: *Logger, path: []const u8) void {
    self.info("Configuration loaded from '{s}'", .{path});
}

pub fn logConfigReloaded(self: *Logger, path: []const u8) void {
    self.info("Configuration reloaded from '{s}'", .{path});
}

pub fn logConfigError(self: *Logger, path: []const u8, error_msg: []const u8) void {
    self.err("Failed to load configuration from '{s}': {s}", .{ path, error_msg });
}

pub fn logServerStarted(self: *Logger, port: u16) void {
    self.info("Taskmaster server started on port {}", .{port});
}

pub fn logServerStopped(self: *Logger) void {
    self.info("Taskmaster server stopped", .{});
}

pub fn logApiRequest(self: *Logger, method: []const u8, path: []const u8, status: u16) void {
    self.debug("API request: {s} {s} - {}", .{ method, path, status });
}

// Tests
test "logger creation and basic logging" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/taskmaster_test.log";

    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    logger.info("Test message: {}", .{42});
    logger.debug("Debug test", .{});
    logger.warn("Warning test", .{});
    logger.err("Error test", .{});

    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);

    std.fs.cwd().deleteFile(log_path) catch {};
}

test "logger structured events" {
    var io = std.Io.Threaded.init(std.testing.allocator);
    defer io.deinit();

    const log_path = "/tmp/taskmaster_events_test.log";

    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(log_path, io.io(), std.testing.allocator);
    defer logger.deinit();

    logger.logProgramStarted("nginx", 12345);
    logger.logProgramStopped("nginx", 12345);
    logger.logProgramRestarted("worker", 12346);
    logger.logProgramDied("worker", 12346, 1);
    logger.logServerStarted(8080);
    logger.logServerStopped();

    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);

    std.fs.cwd().deleteFile(log_path) catch {};
}
