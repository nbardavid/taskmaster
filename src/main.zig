const std = @import("std");
const stdout = std.io.getStdOut();

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
});

const ConfigParser = @import("config.zig");
const Program = @import("program.zig");
const Color = @import("color.zig");

var g_configParser_ptr: *ConfigParser = undefined;

const commandEnum = enum {
    config,
    start,
    help,
    reload,
    ls,
};

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
    }
}

fn logProgramExit(name: []const u8, exit_code: i32) void {
    std.log.info("{s}[{s}-{s}]{s} {s}{s}{s} has exited with status code {s}{d}{s}", .{
        Color.gray,  Color.red,   Color.gray, Color.reset,
        Color.reset, name,        Color.gray, Color.green,
        exit_code,   Color.reset,
    });
}

fn logProgramStart(name: []const u8) void {
    std.log.info("{s}[{s}+{s}]{s} {s}", .{
        Color.gray,  Color.green, Color.gray,
        Color.reset, name,
    });
}

fn logIsProgramRunning(alloc: std.mem.Allocator, program: *Program) !void {
    _ = alloc;
    if (program.status.running) {
        std.log.info("{s}: {s}running{s}", .{ program.config.name, Color.green, Color.reset });
    } else {
        std.log.info("{s}: {s}stopped{s}", .{ program.config.name, Color.red, Color.reset });
    }
}

fn launchAutoStart(allocator: std.mem.Allocator, config: ConfigParser.Config) !void {
    std.debug.print("Starting autostart-enabled programs...\n", .{});
    for (config.programs.items) |*program| {
        if (program.config.autostart == true) {
            try program.startAllProcess(allocator);
        }
    }
    std.debug.print("All autostart-enabled programs have been started.\n", .{});
}

fn shell(allocator: std.mem.Allocator, configParser: *ConfigParser, prompt: []u8) !void {
    var input: [*c]u8 = null;
    try launchAutoStart(allocator, configParser.config);

    while (true) {
        try configParser.config.ForEachProgramProcess(allocator, Program.ProcessStatus.watchMySelf);

        input = c.readline(prompt.ptr);
        if (input == null)
            break;

        execute(allocator, configParser, sliceFromCstr(input)) catch |e| {
            std.log.err("{!}", .{e});
            continue;
        };
    }
}

pub fn main() !void {
    var debugAlloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debugAlloc.deinit();
    const allocator = debugAlloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = reloadOnSighup;
    sa.sa_flags = 0;
    _ = c.sigemptyset(&sa.sa_mask);

    if (c.sigaction(c.SIGHUP, &sa, null) != 0) {
        return error.SignalSetupFailed;
    }

    if (args.len > 1) {
        const prompt = try cstrFromzstr(allocator, args[1]);
        defer allocator.free(prompt);
        var configParser = try ConfigParser.init(allocator);
        g_configParser_ptr = &configParser;
        defer configParser.deinit();

        // parse_config_file(allocator, config);

        // _ = process;
        // var Configs: []Config = parse_Config_file();

        try shell(allocator, &configParser, prompt);
    }

    // std.debug.print("test\n", .{});
}
