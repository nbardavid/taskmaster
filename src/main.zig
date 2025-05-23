const std = @import("std");
const stdout = std.io.getStdOut();

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/time.h");
    @cInclude("time.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("readline/history.h");
});

const ProcessStatus = @import("process.zig");
const ConfigParser = @import("config.zig");
const Program = @import("program.zig");
const Color = @import("color.zig");
const log = @import("log.zig");
const history = @import("history.zig");

var supervisor_pid: c_int = undefined;
var g_configParser_ptr: *ConfigParser = undefined;

const commandEnum = enum {
    config,
    start,
    stop,
    help,
    reload,
    ls,
    logs,
};

fn openLogFile(allocator: std.mem.Allocator) !void {
    _ = allocator;
    return;
}

fn reloadOnSighup(signal: c_int) callconv(.C) void {
    _ = signal;
    g_configParser_ptr.update() catch {};
}

fn cstrFromzstr(allocator: std.mem.Allocator, slice: []const u8) ![]u8 {
    const cstring = try allocator.alloc(u8, slice.len + 1);
    @memcpy(cstring[0..slice.len], slice);
    cstring[slice.len] = 0;
    return cstring;
}

fn sliceFromCstr(str: [*c]u8) []u8 {
    return std.mem.span(str);
}

fn getProgramByName(config: ConfigParser.Config, name: []const u8) !*Program {
    for (config.programs.items) |*program| {
        if (std.mem.eql(u8, program.config.name, name)) {
            return program;
        }
    }
    return error.programNotFound;
}

fn printUsage(cmd: commandEnum) void {
    switch (cmd) {
        .start => {},
        else => {},
    }
}

fn execute(allocator: std.mem.Allocator, configParser: *ConfigParser, string_cmd: []u8) !void {
    var it_cmd = std.mem.tokenizeScalar(u8, string_cmd, ' ');
    const cmd = it_cmd.next() orelse return {};
    const cmd_enum = std.meta.stringToEnum(commandEnum, cmd) orelse return error.CommandNonExisting;

    configParser.mutex.lock();
    defer configParser.mutex.unlock();

    switch (cmd_enum) {
        .start => {
            if (it_cmd.next()) |arg| {
                const program_ptr = try getProgramByName(configParser.config, arg);
                try program_ptr.startAllProcess(allocator);
            } else {
                // printUsage(cmd_enum.start);
            }
        },
        .help => {},
        .config => {
            std.debug.print("{}\n", .{configParser.config});
        },
        .reload => {
            try configParser.update();
        },
        .ls => {
            try configParser.config.ForEachProgram(allocator, Program.logIsRunning);
            // try forEachMapProgram(allocator, configParser.config.programs, logIsProgramRunning);
        },
        .stop => {
            if (it_cmd.next()) |arg| {
                const program_ptr = try getProgramByName(configParser.config, arg);
                std.debug.print("program: {s}\n", .{program_ptr.config.name});
                try program_ptr.ForEachProcess(allocator, ProcessStatus.stopProcess);
            }
            // try configParser.config.ForEachProgramProcess(allocator, ProcessStatus.startProcess);
        },
        .logs => {
            try tailFollowLogs();
        },
    }
}

fn launchAutoStart(allocator: std.mem.Allocator, config: ConfigParser.Config) !void {
    try log.time();
    try log.file.print("Starting autostart-enabled programs...\n", .{});

    for (config.programs.items) |*program| {
        if (program.config.autostart == true) {
            try program.startAllProcess(allocator);
        }
    }

    try log.time();
    try log.file.print("All autostart-enabled programs have been started.\n", .{});
}

fn shell(allocator: std.mem.Allocator, configParser: *ConfigParser, prompt: []u8) !void {
    var input: [*c]u8 = null;
    try launchAutoStart(allocator, configParser.config);

    configParser.supervisor = try std.Thread.spawn(.{}, ConfigParser.startSupervisor, .{ @as(*ConfigParser, configParser), @as(std.mem.Allocator, allocator) });

    while (true) {
        // try configParser.config.ForEachProgramProcess(allocator, ProcessStatus.watchMySelf);

        configParser.mutex.lock();
        std.debug.print("{s}", .{log.buffer.items});
        log.buffer.clearRetainingCapacity();
        configParser.mutex.unlock();

        input = c.readline(prompt.ptr);
        if (input == null)
            break;

        const input_slice = sliceFromCstr(input);

        if (input_slice.len > 0) {
            c.add_history(input);
            try history.file.print("{s}\n", .{input_slice});
        }

        execute(allocator, configParser, input_slice) catch |e| {
            std.log.err("{!}", .{e});
            continue;
        };
    }

    configParser.mutex.lock();
    configParser.stopSupervisor = true;
    configParser.mutex.unlock();
    configParser.supervisor.join();
    // _ = c.waitpid(supervisor_pid, null, 0);
}

var readLogs = true;

pub fn tailFollowLogs() !void {
    const file = try std.fs.cwd().openFile("taskmaster.logs", .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    const fd = file.handle;

    var pfd = c.pollfd{
        .fd = fd,
        .events = c.POLLIN,
        .revents = 0,
    };

    while (readLogs) {
        const res = c.poll(&pfd, 1, 1000);
        if (res < 0) return error.PollFailed;
        if (res == 0) continue;

        if ((pfd.revents & c.POLLIN) != 0) {
            const read_bytes = try file.read(&buf);
            if (read_bytes == 0) {
                std.time.sleep(1e6);
                continue;
            }
            try std.io.getStdOut().writeAll(buf[0..read_bytes]);
        }
    }
}

pub fn main() !void {
    var debugAlloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debugAlloc.deinit();
    const allocator = debugAlloc.allocator();

    const file = try std.fs.cwd().createFile("taskmaster.logs", .{ .read = false });
    defer file.close();
    log.file = file.writer();

    try history.init(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
        sa.__sigaction_handler.sa_handler = reloadOnSighup;
        sa.sa_flags = 0;
        _ = c.sigemptyset(&sa.sa_mask);

        if (c.sigaction(c.SIGHUP, &sa, null) != 0) {
            return error.SignalSetupFailed;
        }
        const prompt = try cstrFromzstr(allocator, args[1]);
        defer allocator.free(prompt);
        var configParser = try ConfigParser.init(allocator);
        g_configParser_ptr = &configParser;
        defer configParser.deinit();

        try log.init(allocator);
        defer log.deinit();

        try shell(allocator, &configParser, prompt);
    }

    // std.debug.print("test\n", .{});
}
