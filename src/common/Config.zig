pub const Config = @This();

arena: heap.ArenaAllocator,
jobs: ArrayList(Job),

pub const ParsingError = error{
    ParseError,
} || Io.Reader.LimitedAllocError || mem.Allocator.Error || json.ParseError(Job);

pub fn init(gpa: mem.Allocator) Config {
    return .{
        .arena = heap.ArenaAllocator.init(gpa),
        .jobs = ArrayList(Job).empty,
    };
}

fn allocator(self: *Config) mem.Allocator {
    return self.arena.allocator();
}

const Programs = struct { programs: json.ArrayHashMap(Job) };

pub fn parse(config: *Config, file_reader: *Io.Reader) !Programs {
    const content = try file_reader.allocRemaining(config.allocator(), .unlimited);
    const parsed = try json.parseFromSliceLeaky(
        Programs,
        config.allocator(),
        content,
        .{},
    );
    return parsed;
}

pub fn deinit(self: *Config) void {
    defer self.* = undefined;
    self.arena.deinit();
}

pub const Job = struct {
    cmd: []const u8 = "",
    numprocs: usize = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    autostart: bool = false,
    autorestart: []const u8 = "",
    exitcodes: []const usize = &.{},
    starttime: usize = 0,
    startretries: usize = 0,
    stoptime: usize = 0,
    stopsignal: []const u8 = "",
    workingdir: []const u8 = "",
    umask: []const u8 = "",

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            "Job{{\n cmd={s}\n numprocs={d}\n autostart={}\n autorestart={s}\n stdout={s}\n stderr={s}\n workingdir={s}\n umask={s}\n exitcodes={any}\n starttime={d}\n startretries={d}\n stoptime={d}\n stopsignal={s}\n}}",
            .{
                self.cmd,
                self.numprocs,
                self.autostart,
                self.autorestart,
                self.stdout,
                self.stderr,
                self.workingdir,
                self.umask,
                self.exitcodes,
                self.starttime,
                self.startretries,
                self.stoptime,
                self.stopsignal,
            },
        );
    }
};

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const StringMap = std.StringArrayHashMapUnmanaged;
const EnumSet = std.EnumSet;
const ArrayList = std.ArrayListUnmanaged;
const json = std.json;
const Io = std.Io;
const Signal = @import("process.zig").Signal;
