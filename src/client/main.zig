const std = @import("std");
const heap = std.heap;
const Io = std.Io;
const mem = std.mem;
const proc = std.process;
const fs = std.fs;

const common = @import("common");
const Config = common.Config;

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

    var config: Config = .init(gpa);
    defer config.deinit();

    const jobs = try config.parse(&file_reader.interface);
    var it = jobs.programs.map.iterator();

    while (it.next()) |entry| {
        std.debug.print("{s}:{f}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}
