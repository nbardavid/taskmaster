const std = @import("std");

pub fn buildNullTerminatedArray(items: []const []const u8, allocator: std.mem.Allocator) ![:null]?[*:0]u8 {
    const result = try allocator.allocSentinel(?[*:0]u8, items.len, null);
    for (items, 0..) |item, i| {
        result[i] = try allocator.dupeZ(u8, item);
    }
    return result;
}

pub fn buildArgv(argv: []const []const u8, allocator: std.mem.Allocator) ![:null]?[*:0]u8 {
    return buildNullTerminatedArray(argv, allocator);
}

pub fn buildEnvp(env: []const []const u8, allocator: std.mem.Allocator) ![:null]?[*:0]u8 {
    return buildNullTerminatedArray(env, allocator);
}

pub fn timestampNs(io: std.Io) !u64 {
    const timestamp = try std.Io.Clock.boot.now(io);
    return @as(u64, @truncate(@abs(timestamp.toNanoseconds())));
}

test "buildArgv with single argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = [_][]const u8{"echo"};
    const result = try buildArgv(&argv, allocator);
    defer {
        for (result) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] != null);
    try std.testing.expectEqualStrings("echo", std.mem.span(result[0].?));
}

test "buildArgv with multiple arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = [_][]const u8{ "ls", "-la", "/tmp" };
    const result = try buildArgv(&argv, allocator);
    defer {
        for (result) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expect(result[0] != null);
    try std.testing.expect(result[1] != null);
    try std.testing.expect(result[2] != null);
    try std.testing.expectEqualStrings("ls", std.mem.span(result[0].?));
    try std.testing.expectEqualStrings("-la", std.mem.span(result[1].?));
    try std.testing.expectEqualStrings("/tmp", std.mem.span(result[2].?));
}

test "buildArgv with empty array" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = [_][]const u8{};
    const result = try buildArgv(&argv, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "buildArgv with special characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = [_][]const u8{ "echo", "hello world", "foo&bar" };
    const result = try buildArgv(&argv, allocator);
    defer {
        for (result) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("echo", std.mem.span(result[0].?));
    try std.testing.expectEqualStrings("hello world", std.mem.span(result[1].?));
    try std.testing.expectEqualStrings("foo&bar", std.mem.span(result[2].?));
}

test "buildEnvp with single environment variable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const env = [_][]const u8{"PATH=/usr/bin"};
    const result = try buildEnvp(&env, allocator);
    defer {
        for (result) |envvar| {
            if (envvar) |e| allocator.free(std.mem.span(e));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] != null);
    try std.testing.expectEqualStrings("PATH=/usr/bin", std.mem.span(result[0].?));
}

test "buildEnvp with multiple environment variables" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const env = [_][]const u8{ "PATH=/usr/bin", "HOME=/home/user", "LANG=en_US.UTF-8" };
    const result = try buildEnvp(&env, allocator);
    defer {
        for (result) |envvar| {
            if (envvar) |e| allocator.free(std.mem.span(e));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expect(result[0] != null);
    try std.testing.expect(result[1] != null);
    try std.testing.expect(result[2] != null);
    try std.testing.expectEqualStrings("PATH=/usr/bin", std.mem.span(result[0].?));
    try std.testing.expectEqualStrings("HOME=/home/user", std.mem.span(result[1].?));
    try std.testing.expectEqualStrings("LANG=en_US.UTF-8", std.mem.span(result[2].?));
}

test "buildEnvp with empty array" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const env = [_][]const u8{};
    const result = try buildEnvp(&env, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "buildEnvp with complex values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const env = [_][]const u8{ "DB_URL=postgresql://localhost:5432/db", "FLAGS=-Wall -Werror" };
    const result = try buildEnvp(&env, allocator);
    defer {
        for (result) |envvar| {
            if (envvar) |e| allocator.free(std.mem.span(e));
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("DB_URL=postgresql://localhost:5432/db", std.mem.span(result[0].?));
    try std.testing.expectEqualStrings("FLAGS=-Wall -Werror", std.mem.span(result[1].?));
}
