const std = @import("std");
const ConfigParser = @This();

// var buffer: [512]u8 = .{0} ** 512;
// const stream = std.io.fixedBufferStream(&buffer);
// var writer = stream.writer();

pub const ProgramJson = struct {
    cmd: []u8,
    stdout: []u8,
    stderr: []u8,
};

pub const ProgramStatus = struct {
    hash: u64 = 0,
    need_restart: bool = false,
    pid: c_int = 0,
    running: bool = false,
    nstart: u32 = 0,
    exitno: c_int = 0,
    stdout_fd: c_int = -1,
    stdin_fd: c_int = -1,
};

pub const ProgramConfig = struct {
    name: []const u8,
    cmd: []const u8,
    stdout: []const u8,
    stderr: []const u8,
};

// ERROR couleurs prints (config)

pub const Program = struct {
    config: ProgramConfig,
    status: ProgramStatus = ProgramStatus{},

    pub fn computeHash(self: *Program) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.config.name);
        hasher.update(self.config.cmd);
        hasher.update(self.config.stdout);
        hasher.update(self.config.stdout);
        // self.status.hash = hasher.final();
        return hasher.final();
    }

    pub fn format(self: *const Program, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const color = std.io.tty.Color;

        _ = fmt;
        try writer.print("{}===== Config =====\n{}", .{ color.green, color.reset });
        try writer.print("name: {s}\ncmd: {s}\nstdout: {s}\nstderr: {s}\n", .{ self.config.name, self.config.cmd, self.config.stdout, self.config.stderr });
        try writer.print("{}===== Status =====\n", .{color.green});
        try writer.print(
            \\hash: {}\n
            \\need_restart: {}\n
            \\pid: {}\n
            \\running: {}\n
            \\nstart: {}\n
            \\exitno: {}\n
            \\stdout_fd: {}\n
            \\stdin_fd: {}\n
        ,
            .{
                self.status.hash,
                self.status.need_restart,
                self.status.pid,
                self.status.running,
                self.status.nstart,
                self.status.exitno,
                self.status.stdout_fd,
                self.status.stdin_fd,
            },
        );
        try writer.print("{}", .{color.reset});
    }
};

pub const Config = struct {
    programs: std.ArrayList(Program),

    pub fn format(self: *const Config, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        for (self.programs.items, 0..) |program, i| {
            try writer.print("Program: {d}\n", .{i});
            try writer.print("{}", .{program});
        }
    }
};

alloc: std.mem.Allocator,
// parsedConfig: std.json.Parsed(Config),
config: Config,

pub fn init(alloc: std.mem.Allocator) !ConfigParser {
    const parsed_programs = try parse(alloc);
    const config: Config = Config{ .programs = parsed_programs };

    return .{
        .alloc = alloc,
        .config = config,
    };
}

pub fn deinit(self: *ConfigParser) void {
    self.config.programs.deinit();
    // for (self.config.programs) |program| {
    //     // self.alloc.destroy(program);
    // }
    // self.alloc.destroy(self.config);
}

pub fn getProgramByName(self: ConfigParser, name: []const u8) !*ConfigParser.Program {
    for (self.config.programs) |*program| {
        if (std.mem.eql(u8, program.config.name, name)) {
            return program;
        }
    }
    return error.programNotFound;
}
//
// pub fn update(self: *ConfigParser) !void {
//     // self.parsedConfig.deinit();
//     const new_config = try parse(self.alloc);
//
//     var programs = std.ArrayList(Program).init(self.alloc);
//     var programs = std.MultiArrayList()
//     for (new_config.value.programs) |*program| {
//         program.computeHash();
//         const old_program = self.getProgramByName(program.name) catch {
//             programs.append(program); //DOIT CLONE POUR FREE LE RESTE FACILEMENT
//             continue;
//         };
//
//         if (program.status.hash != old_program.status.hash) {
//             program.status.need_restart = true;
//             programs.append(program); //DOIT CLONE POUR FREE LE RESTE FACILEMENT
//         }
//     }
//
//     self.config.programs = programs;
//
//     // self.config = self.parsedConfig.value;
// }
//
pub fn parse(allocator: std.mem.Allocator) !std.ArrayList(Program) {
    const file = try std.fs.cwd().openFile("./test.json", .{});
    defer file.close();

    const content: []u8 = file.readToEndAlloc(allocator, 1e9) catch |e| {
        std.log.debug("Canno't read file: {s}: cause: {!}", .{ "path", e });
        return error.FileTooBig;
    };
    defer allocator.free(content);
    // allocator.free(self);
    //
    const root = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer root.deinit();

    const json_value_programs = root.value.object.get("programs").?.object;
    var it = json_value_programs.iterator();

    var new_programs = std.ArrayList(Program).init(allocator);

    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const json_program = entry.value_ptr.*;

        std.debug.print("SALUTSALUTSLAUT\n\n\n", .{});
        const parsed_program = try std.json.parseFromValue(ProgramJson, allocator, json_program, .{});
        std.debug.print("SALUTSALUTSLAUT\n\n\n", .{});

        const new_program = Program{
            .config = ProgramConfig{
                .name = name,
                .cmd = parsed_program.value.cmd,
                .stderr = parsed_program.value.stderr,
                .stdout = parsed_program.value.stdout,
            },
            .status = ProgramStatus{},
        };

        try new_programs.append(new_program);
    }
    return new_programs;
}
