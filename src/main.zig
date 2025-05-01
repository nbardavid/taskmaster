const std = @import("std");
const stdout = std.io.getStdOut();

const c = @cImport({
    @cInclude("readline/readline.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

const ConfigParser = @import("config.zig");

const commandEnum = enum {
    config,
    start,
    help,
    reload,
};

fn cstrFromzstr(allocator: std.mem.Allocator, slice: []u8) ![]u8 {
    const cstring = try allocator.alloc(u8, slice.len + 1);
    @memcpy(cstring[0..slice.len], slice);
    cstring[slice.len] = 0;
    return cstring;
}

fn sliceFromCstr(str: [*c]u8) []u8 {
    return std.mem.span(str);
}

fn start(alloc: std.mem.Allocator, program: *ConfigParser.Program) !void {
    var it_cmd = std.mem.tokenizeScalar(u8, program.cmd, ' ');

    var argv_list = std.ArrayList(?[*:0]const u8).init(alloc);
    var argv_ptr_list = std.ArrayList([]u8).init(alloc);

    while (it_cmd.next()) |slice| {
        const dup = try alloc.alloc(u8, slice.len + 1);
        @memcpy(dup[0..slice.len], slice);
        dup[slice.len] = 0;
        try argv_list.append(@as([*:0]const u8, @ptrCast(dup.ptr)));
        try argv_ptr_list.append(dup);
    }

    defer {
        for (argv_ptr_list.items) |item| {
            alloc.free(item);
        }
        argv_ptr_list.deinit();
        argv_list.deinit();
    }

    // const null_ptr: [*:0]const u8 = null;
    try argv_list.append(null);

    const pid = std.c.fork();

    if (pid == 0) {
        const path = @as([*:0]const u8, @ptrCast(argv_list.items[0]));
        const argv = @as([*:null]const ?[*:0]const u8, @ptrCast(argv_list.items.ptr));

        const stderr_filename: []u8 = try cstrFromzstr(alloc, program.stderr);
        const stdout_filename: []u8 = try cstrFromzstr(alloc, program.stdout);

        const stdout_fd: c_int = c.open(stdout_filename.ptr, c.O_WRONLY | c.O_CREAT, @as(c_int, @intCast(0o664)));
        const stderr_fd: c_int = c.open(stderr_filename.ptr, c.O_WRONLY | c.O_CREAT, @as(c_int, @intCast(0o664)));
        if (stdout_fd == -1 or stderr_fd == -1) {
            return error.cantOpenOutputFiles;
        }

        if (std.c.dup2(stdout_fd, std.c.STDOUT_FILENO) == -1 or std.c.dup2(stderr_fd, std.c.STDERR_FILENO) == -1) {
            return error.Dup2Failed;
        }

        _ = std.c.execve(path, argv, std.c.environ);
        std.log.err("execve failed", .{});
        std.process.exit(1);
    }

    program.status.pid = pid;
    program.status.nstart += 1;
    program.status.running = true;
    std.log.info("program: {s} started", .{program.name});
}

fn getProgramByName(config: ConfigParser.Config, name: []const u8) !*ConfigParser.Program {
    for (config.programs) |*program| {
        if (std.mem.eql(u8, program.name, name)) {
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
                try start(allocator, program_ptr);
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
    }
}

fn watchPrograms(programs: []ConfigParser.Program) void {
    for (programs) |*program| {
        if (program.status.running == false) {
            continue;
        }
        if (c.waitpid(program.status.pid, &program.status.exitno, c.WNOHANG) != 0) {
            std.log.info("program: {s} has exited with status code {d}", .{ program.name, program.status.exitno });
        }
    }
}

fn shell(allocator: std.mem.Allocator, configParser: *ConfigParser, prompt: []u8) !void {
    var input: [*c]u8 = null;
    while (true) {
        input = c.readline(prompt.ptr);
        if (input == null)
            break;

        execute(allocator, configParser, sliceFromCstr(input)) catch |e| {
            std.log.err("{!}", .{e});
            continue;
        };

        watchPrograms(configParser.parsedConfig.value.programs);
    }
}

pub fn main() !void {
    var debugAlloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debugAlloc.deinit();
    const allocator = debugAlloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        const prompt = try cstrFromzstr(allocator, args[1]);
        defer allocator.free(prompt);
        var configParser = try ConfigParser.init(allocator);
        defer configParser.deinit();

        // parse_config_file(allocator, config);

        // _ = process;
        // var Configs: []Config = parse_Config_file();

        try shell(allocator, &configParser, prompt);
    }

    // std.debug.print("test\n", .{});
}
