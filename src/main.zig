pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var argv = try proc.argsWithAllocator(gpa);
    defer argv.deinit();

    _ = argv.skip();
    const config_file_path = argv.next().?;

    const cwd = fs.cwd();
    var file = try cwd.openFile(config_file_path, .{ .mode = .read_only });
    defer file.close();

    var file_buffer: [std.heap.pageSize()]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const reader = &file_reader.interface;

    var config: Config = .init(gpa);
    defer config.deinit();

    const jobs = try config.parse(reader);

    for (jobs) |job| {
        std.debug.print("{f},\n", .{job});
    }
}

const std = @import("std");
const Config = @import("Config.zig");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
