const std = @import("std");
const ConfigParser = @This();
const Program = @import("program.zig");

// var buffer: [512]u8 = .{0} ** 512;
// const stream = std.io.fixedBufferStream(&buffer);
// var writer = stream.writer();

pub const ProgramJson = struct {
    cmd: []u8,
    stdout: []u8,
    stderr: []u8,
    numprocs: u32,
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
    pub fn ForEachProgramProcess(self: Config, allocator: std.mem.Allocator, comptime function: fn (*Program.ProcessStatus, std.mem.Allocator, *Program, usize) anyerror!void) !void {
        for (self.programs.items) |*program| {
            try program.ForEachProcess(allocator, function);
        }
    }

    // fn watchProgram(alloc: std.mem.Allocator, program: *ConfigParser.Program) !void {
    //     if (program.status.running == false) {
    //         return;
    //     } else if (c.waitpid(program.status.pid, &program.status.exitno, c.WNOHANG) != 0) {
    //         logProgramExit(program.config.name, program.status.exitno);
    //         program.status.running = false;
    //     } else if (program.status.need_restart) {
    //         try start(alloc, program);
    //     }
    // }
    // pub fn updateStatusAndLog(self: *Config){
    //
    // }
};

alloc: std.mem.Allocator,
config: Config,
nprocess_running: u32 = 0,

pub fn init(alloc: std.mem.Allocator) !ConfigParser {
    const parsed_programs = try parse(alloc);
    const config: Config = Config{ .programs = parsed_programs };

    return .{
        .alloc = alloc,
        .config = config,
    };
}

pub fn deinit(self: *ConfigParser) void {
    for (self.config.programs.items) |program| {
        self.alloc.free(program.config.name);
        self.alloc.free(program.config.cmd);
        self.alloc.free(program.config.stdout);
        self.alloc.free(program.config.stderr);
        program.process.deinit();
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
    const new_config = try parse(self.alloc);

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
    for (self.config.programs.items) |program| {
        self.alloc.free(program.config.name);
        self.alloc.free(program.config.cmd);
        self.alloc.free(program.config.stdout);
        self.alloc.free(program.config.stderr);
    }
    self.config.programs.deinit();

    for (new_config.items) |program| {
        self.alloc.free(program.config.name);
        self.alloc.free(program.config.cmd);
        self.alloc.free(program.config.stdout);
        self.alloc.free(program.config.stderr);
    }
    new_config.deinit();

    self.config.programs = programs;
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

        const parsed_program = try std.json.parseFromValue(ProgramJson, allocator, json_program, .{});
        defer parsed_program.deinit();

        var new_program = Program{
            .config = Program.ProgramConfig{
                .name = try allocator.dupe(u8, name),
                .cmd = try allocator.dupe(u8, parsed_program.value.cmd),
                .stderr = try allocator.dupe(u8, parsed_program.value.stderr),
                .stdout = try allocator.dupe(u8, parsed_program.value.stdout),
                .numprocs = parsed_program.value.numprocs,
            },
            .process = std.ArrayList(Program.ProcessStatus).init(allocator),
        };

        for (0..new_program.config.numprocs) |_| {
            try new_program.process.append(Program.ProcessStatus{});
        }

        // try new_program.process.append(Program.ProcessStatus{});

        new_program.hash = new_program.computeHash();

        try new_programs.append(new_program);
    }
    return new_programs;
}
