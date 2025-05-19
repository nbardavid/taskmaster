const std = @import("std");
const ConfigParser = @This();
const Program = @import("program.zig");
const ProcessStatus = @import("process.zig");
const Signal = @import("signal.zig");

// var buffer: [512]u8 = .{0} ** 512;
// const stream = std.io.fixedBufferStream(&buffer);
// var writer = stream.writer();

pub const ProgramJson = struct {
    cmd: []u8,
    stdout: []u8,
    stderr: []u8,
    numprocs: u32,
    autorestart: []u8,
    autostart: bool = false,
    starttime: u32 = 0,
    stoptime: u32 = 0,
    exitcodes: []const i32 = &[_]i32{0},
    startretries: u32 = 0,
    stopsignal: []const u8 = "TERM",
    umask: u32 = 22,
};

pub const Config = struct {
    programs: std.ArrayList(Program),

    pub fn format(self: *const Config, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        for (self.programs.items, 0..) |program, i| {
            try writer.print("\nProgram: {d}\n", .{i});
            try writer.print("{}", .{program});
        }
    }

    //function (allocator, program);
    pub fn ForEachProgram(self: Config, allocator: std.mem.Allocator, comptime function: fn (*Program, std.mem.Allocator) anyerror!void) !void {
        for (self.programs.items) |*program| {
            try function(program, allocator);
        }
    }
    //function (allocator, program, process, nproc);
    pub fn ForEachProgramProcess(self: Config, allocator: std.mem.Allocator, comptime function: fn (*ProcessStatus, std.mem.Allocator, *Program, usize) anyerror!void) !void {
        for (self.programs.items) |*program| {
            try program.ForEachProcess(allocator, function);
        }
    }
};

alloc: std.mem.Allocator,
config: Config,
nprocess_running: u32 = 0,
mutex: std.Thread.Mutex = std.Thread.Mutex{},
supervisor: std.Thread = undefined,
stopSupervisor: bool = false,

pub fn startSupervisor(self: *ConfigParser, allocator: std.mem.Allocator) !void {
    while (true) {
        self.mutex.lock();

        try self.config.ForEachProgramProcess(allocator, ProcessStatus.watchMySelf);
        if (self.stopSupervisor == true) {
            self.mutex.unlock();
            break;
        }
        self.mutex.unlock();
        std.time.sleep(1e6);
    }
}

pub fn init(alloc: std.mem.Allocator) !ConfigParser {
    const parsed_programs = try parse(alloc);
    const config: Config = Config{ .programs = parsed_programs };

    return .{
        .alloc = alloc,
        .config = config,
    };
}

pub fn deinit(self: *ConfigParser) void {
    for (self.config.programs.items) |*program| {
        program.deinit(self.alloc);
    }
    self.config.programs.deinit();
}

pub fn getProgramByName(self: ConfigParser, name: []const u8) !*ConfigParser.Program {
    for (self.config.programs.items) |*program| {
        if (std.mem.eql(u8, program.config.name, name)) {
            return program;
        }
    }
    return error.programNotFound;
}

pub fn update(self: *ConfigParser) !void {
    const new_config = parse(self.alloc) catch {
        return;
    };
    var programs = std.ArrayList(Program).init(self.alloc);
    for (new_config.items) |*program| {
        const old_program = self.getProgramByName(program.config.name) catch {
            try programs.append(try program.clone(self.alloc)); //DOIT CLONE POUR FREE LE RESTE FACILEMENT
            continue;
        };

        if (program.hash != old_program.hash) {
            // program.status.need_restart = true;
            try programs.append(try program.clone(self.alloc)); //DOIT CLONE POUR FREE LE RESTE FACILEMENT
        } else {
            try programs.append(try old_program.clone(self.alloc)); //DOIT CLONE POUR FREE LE RESTE FACILEMENT
        }
    }
    for (self.config.programs.items) |*program|
        program.deinit(self.alloc);
    self.config.programs.deinit();

    for (new_config.items) |*program|
        program.deinit(self.alloc);
    new_config.deinit();

    self.config.programs = programs;
    std.debug.print("Config reloaded\n", .{});
}

pub fn parse(allocator: std.mem.Allocator) !std.ArrayList(Program) {
    const file = try std.fs.cwd().openFile("./test.json", .{});
    defer file.close();

    const content: []u8 = file.readToEndAlloc(allocator, 1e9) catch |e| {
        std.log.debug("Canno't read file: {s}: cause: {!}", .{ "path", e });
        return error.FileTooBig;
    };
    defer allocator.free(content);

    const root = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer root.deinit();

    const json_value_programs = root.value.object.get("programs").?.object;
    var it = json_value_programs.iterator();

    var new_programs = std.ArrayList(Program).init(allocator);

    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const json_program = entry.value_ptr.*;

        const parsed_program = std.json.parseFromValue(ProgramJson, allocator, json_program, .{}) catch |e| {
            std.log.err("Invalid json config: {}", .{e});
            for (new_programs.items) |*program| {
                program.deinit(new_programs.allocator);
            }
            new_programs.deinit();
            return e;
        };
        defer parsed_program.deinit();

        var new_program = Program{
            .config = Program.ProgramConfig{
                .name = try allocator.dupe(u8, name),
                .cmd = try allocator.dupe(u8, parsed_program.value.cmd),
                .stderr = try allocator.dupe(u8, parsed_program.value.stderr),
                .stdout = try allocator.dupe(u8, parsed_program.value.stdout),
                .numprocs = parsed_program.value.numprocs,
                .autostart = parsed_program.value.autostart,
                .exitcodes = try allocator.dupe(i32, parsed_program.value.exitcodes),
                .autorestart = std.meta.stringToEnum(Program.restartEnum, parsed_program.value.autorestart) orelse return error.InvalidValueAutoRestart,
                .starttime = parsed_program.value.starttime,
                .startretries = parsed_program.value.startretries,
                .stoptime = parsed_program.value.stoptime,
                .stopsignal = Signal.stringToSignal(parsed_program.value.stopsignal) orelse return error.InvalidValueStopSignal,
                .umask = parsed_program.value.umask,
            },
            .process = std.ArrayList(ProcessStatus).init(allocator),
        };

        for (0..new_program.config.numprocs) |_| {
            try new_program.process.append(ProcessStatus{});
        }

        // try new_program.process.append(ProcessStatus{});

        new_program.hash = new_program.computeHash();

        try new_programs.append(new_program);
    }
    return new_programs;
}
