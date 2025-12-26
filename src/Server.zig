const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const http = std.http;
const atomic = std.atomic;

const root = @import("root.zig");
const ProcessGroupManager = root.ProcessGroupManager;
const ProcessGroup = root.ProcessGroup;
const Logger = root.Logger;
const Config = root.Config;

pub const Server = @This();

const VERSION = "1.0.0";

fn getCurrentTimeNs(io: Io) !u64 {
    const timestamp = try Io.Clock.boot.now(io);
    return @as(u64, @truncate(@abs(timestamp.toNanoseconds())));
}

fn signalToString(sig: u8) []const u8 {
    return switch (@as(std.posix.SIG, @enumFromInt(sig))) {
        .TERM => "SIGTERM",
        .KILL => "SIGKILL",
        .INT => "SIGINT",
        .HUP => "SIGHUP",
        .QUIT => "SIGQUIT",
        .USR1 => "SIGUSR1",
        .USR2 => "SIGUSR2",
        else => "UNKNOWN",
    };
}

gpa: mem.Allocator,
io: Io,
config: Config,
manager: *ProcessGroupManager,
logger: *Logger,
port: u16,
reload: *atomic.Value(bool),
shutdown: *atomic.Value(bool),
start_time_ns: u64 = 0,

pub fn init(
    gpa: mem.Allocator,
    io: Io,
    config: Config,
    manager: *ProcessGroupManager,
    logger: *Logger,
    port: u16,
    reload: *atomic.Value(bool),
    shutdown: *atomic.Value(bool),
) Server {
    return .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .manager = manager,
        .logger = logger,
        .port = port,
        .reload = reload,
        .shutdown = shutdown,
    };
}

pub fn listen(self: *Server) !void {
    self.start_time_ns = try getCurrentTimeNs(self.io);

    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
    var server = try address.listen(self.io, .{});
    defer server.deinit(self.io);

    self.logger.logServerStarted(self.port);

    while (!self.shutdown.load(.acquire)) {
        const stream = server.accept(self.io) catch |err| {
            if (err == error.Interrupted and self.shutdown.load(.acquire)) {
                break;
            }
            self.logger.err("Failed to accept connection: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(self.io);

        if (self.shutdown.load(.acquire)) break;

        self.handleConnection(stream) catch |err| {
            self.logger.err("Failed to handle connection: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(self: *Server, stream: Io.net.Stream) !void {
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = stream.reader(self.io, &read_buffer);
    var writer = stream.writer(self.io, &write_buffer);

    var http_server = http.Server.init(&reader.interface, &writer.interface);

    while (!self.shutdown.load(.acquire)) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => return err,
        };

        self.handleRequest(&request) catch |err| {
            self.logger.err("HTTP request handler error: {s}", .{@errorName(err)});
            self.sendError(&request, .internal_server_error, "Internal server error", @errorName(err)) catch {};
        };
    }
}

fn handleRequest(self: *Server, request: *http.Server.Request) !void {
    const method = @tagName(request.head.method);
    const target = request.head.target;

    self.logger.debug("HTTP {s} {s}", .{ method, target });

    if (mem.eql(u8, target, "/") and request.head.method == .GET) {
        try self.handleHealth(request);
    } else if (mem.eql(u8, target, "/api") and request.head.method == .GET) {
        try self.handleApiInfo(request);
    } else if (mem.eql(u8, target, "/status") and request.head.method == .GET) {
        try self.handleGetStatus(request);
    } else if (mem.startsWith(u8, target, "/programs/")) {
        try self.handleProgramRoute(request, target);
    } else if (mem.eql(u8, target, "/reload") and request.head.method == .POST) {
        try self.handleReload(request);
    } else if ((mem.eql(u8, target, "/shutdown") or mem.eql(u8, target, "/quit")) and request.head.method == .POST) {
        try self.handleShutdown(request);
    } else {
        try self.sendError(request, .not_found, "Route not found", "The requested endpoint does not exist. Try GET /api for available endpoints.");
    }
}

fn handleHealth(self: *Server, request: *http.Server.Request) !void {
    const now_ns = try getCurrentTimeNs(self.io);
    const uptime_s = if (self.start_time_ns > 0) (now_ns - self.start_time_ns) / std.time.ns_per_s else 0;

    try self.sendJson(request, .ok, .{
        .success = true,
        .status = "healthy",
        .version = VERSION,
        .uptime_seconds = uptime_s,
        .port = self.port,
    });
}

fn handleApiInfo(self: *Server, request: *http.Server.Request) !void {
    try self.sendJson(request, .ok, .{
        .success = true,
        .version = VERSION,
        .endpoints = .{
            .health = .{
                .method = "GET",
                .path = "/",
                .description = "Health check endpoint",
            },
            .api_info = .{
                .method = "GET",
                .path = "/api",
                .description = "API information and available endpoints",
            },
            .status = .{
                .method = "GET",
                .path = "/status",
                .description = "Get status of all programs with full configuration",
            },
            .program_status = .{
                .method = "GET",
                .path = "/programs/:name",
                .description = "Get detailed status of a specific program including all processes",
            },
            .program_start = .{
                .method = "POST",
                .path = "/programs/:name/start",
                .description = "Start a program",
            },
            .program_stop = .{
                .method = "POST",
                .path = "/programs/:name/stop",
                .description = "Stop a program",
            },
            .program_restart = .{
                .method = "POST",
                .path = "/programs/:name/restart",
                .description = "Restart a program",
            },
            .reload = .{
                .method = "POST",
                .path = "/reload",
                .description = "Reload configuration from file",
            },
            .shutdown = .{
                .method = "POST",
                .path = "/shutdown",
                .description = "Gracefully shutdown the supervisor",
            },
        },
    });
}

fn handleGetStatus(self: *Server, request: *http.Server.Request) !void {
    var programs_list: std.ArrayList(std.json.Value) = .empty;
    defer programs_list.deinit(self.gpa);

    var iter = self.manager.groups.iterator();
    while (iter.next()) |entry| {
        const group = entry.value_ptr.*;
        const program_status = try self.buildProgramStatus(group, false);
        try programs_list.append(self.gpa, program_status);
    }

    const now_ns = try getCurrentTimeNs(self.io);
    const uptime_s = if (self.start_time_ns > 0) (now_ns - self.start_time_ns) / std.time.ns_per_s else 0;

    try self.sendJson(request, .ok, .{
        .success = true,
        .timestamp = now_ns,
        .server_uptime_seconds = uptime_s,
        .total_programs = programs_list.items.len,
        .programs = programs_list.items,
    });
}

fn handleProgramRoute(self: *Server, request: *http.Server.Request, target: []const u8) !void {
    const prefix = "/programs/";
    const rest = target[prefix.len..];

    var it = mem.splitScalar(u8, rest, '/');
    const name = it.next() orelse return self.sendError(request, .bad_request, "Missing program name", "Program name must be provided in the URL path");

    const action = it.next();

    if (action == null) {
        if (request.head.method == .GET) {
            try self.handleGetProgram(request, name);
        } else {
            try self.sendError(request, .method_not_allowed, "Method not allowed", "Only GET is supported for program status");
        }
    } else {
        if (request.head.method != .POST) {
            return self.sendError(request, .method_not_allowed, "Method not allowed", "Only POST is supported for program actions");
        }

        if (mem.eql(u8, action.?, "start")) {
            try self.handleStartProgram(request, name);
        } else if (mem.eql(u8, action.?, "stop")) {
            try self.handleStopProgram(request, name);
        } else if (mem.eql(u8, action.?, "restart")) {
            try self.handleRestartProgram(request, name);
        } else {
            try self.sendError(request, .not_found, "Unknown action", "Valid actions are: start, stop, restart");
        }
    }
}

fn buildProgramStatus(self: *Server, group: *const ProcessGroup, include_processes: bool) !std.json.Value {
    const uptime_ns = try group.getTotalUptime(self.io);
    const uptime_s: u64 = uptime_ns / std.time.ns_per_s;

    var fatal_count: u32 = 0;
    var processes_list: std.ArrayList(std.json.Value) = .empty;
    defer processes_list.deinit(self.gpa);

    if (include_processes) {
        for (group.children, 0..) |*child, i| {
            if (child.state == .exited and child.retries_count >= group.start_retries) {
                fatal_count += 1;
            }

            const proc_uptime_ns = try child.getUptime(self.io);
            const proc_uptime_s = proc_uptime_ns / std.time.ns_per_s;

            try processes_list.append(self.gpa, .{
                .object = std.json.ObjectMap.init(self.gpa),
            });
            var proc_obj = &processes_list.items[processes_list.items.len - 1].object;

            try proc_obj.put("id", .{ .integer = @intCast(i) });
            try proc_obj.put("pid", if (child.pid) |p| .{ .integer = p } else .null);
            try proc_obj.put("state", .{ .string = @tagName(child.state) });
            try proc_obj.put("uptime_seconds", .{ .integer = @intCast(proc_uptime_s) });
            try proc_obj.put("retries_count", .{ .integer = @intCast(child.retries_count) });
            try proc_obj.put("is_stable", .{ .bool = child.is_stable });
            if (child.exit_code) |code| {
                try proc_obj.put("exit_code", .{ .integer = @intCast(code) });
            }
            if (child.exit_signal) |sig| {
                try proc_obj.put("exit_signal", .{ .integer = @intCast(sig) });
            }
        }
    } else {
        for (group.children) |*child| {
            if (child.state == .exited and child.retries_count >= group.start_retries) {
                fatal_count += 1;
            }
        }
    }

    var result = std.json.Value{ .object = std.json.ObjectMap.init(self.gpa) };
    var obj = &result.object;

    try obj.put("name", .{ .string = group.name });
    try obj.put("state", .{ .string = @tagName(group.state) });
    try obj.put("running", .{ .integer = @intCast(group.getRunningCount()) });
    try obj.put("alive", .{ .integer = @intCast(group.getAliveCount()) });
    try obj.put("total", .{ .integer = @intCast(group.numprocs) });
    try obj.put("uptime_seconds", .{ .integer = @intCast(uptime_s) });
    try obj.put("fatal_count", .{ .integer = @intCast(fatal_count) });

    var config_obj = std.json.Value{ .object = std.json.ObjectMap.init(self.gpa) };
    var cfg = &config_obj.object;
    try cfg.put("cmd", .{ .string = group.cmd });
    try cfg.put("numprocs", .{ .integer = @intCast(group.numprocs) });
    try cfg.put("autostart", .{ .bool = group.autostart });
    try cfg.put("autorestart", .{ .string = @tagName(group.autorestart) });
    try cfg.put("start_delay_seconds", .{ .integer = @intCast(group.start_delay) });
    try cfg.put("startsecs", .{ .integer = @intCast(group.startsecs) });
    try cfg.put("start_retries", .{ .integer = @intCast(group.start_retries) });
    try cfg.put("stop_signal", .{ .string = signalToString(group.stop_signal) });
    try cfg.put("stop_timeout_seconds", .{ .integer = @intCast(group.stop_timeout) });
    try cfg.put("redirect_stdout", .{ .bool = group.redirect_stdout });
    try cfg.put("redirect_stderr", .{ .bool = group.redirect_stderr });

    if (group.stdout_path.len > 0) {
        try cfg.put("stdout_path", .{ .string = group.stdout_path });
    }
    if (group.stderr_path.len > 0) {
        try cfg.put("stderr_path", .{ .string = group.stderr_path });
    }
    if (group.working_directory.len > 0) {
        try cfg.put("working_directory", .{ .string = group.working_directory });
    }
    if (group.umask != 0) {
        try cfg.put("umask", .{ .integer = @intCast(group.umask) });
    }

    var exitcodes = std.json.Value{ .array = std.json.Array.init(self.gpa) };
    for (group.exitcodes) |code| {
        try exitcodes.array.append(.{ .integer = @intCast(code) });
    }
    try cfg.put("exitcodes", exitcodes);

    try obj.put("config", config_obj);

    if (include_processes) {
        try obj.put("processes", .{ .array = std.json.Array.fromOwnedSlice(self.gpa, try processes_list.toOwnedSlice(self.gpa)) });
    }

    return result;
}

fn handleGetProgram(self: *Server, request: *http.Server.Request, name: []const u8) !void {
    const group = self.manager.getGroup(name) orelse {
        return self.sendError(request, .not_found, "Program not found", "No program with that name is configured");
    };

    const program_status = try self.buildProgramStatus(group, true);

    try self.sendJson(request, .ok, .{
        .success = true,
        .program = program_status,
    });
}

fn handleStartProgram(self: *Server, request: *http.Server.Request, name: []const u8) !void {
    const group = self.manager.getGroup(name) orelse {
        return self.sendError(request, .not_found, "Program not found", "No program with that name is configured");
    };

    if (group.getAliveCount() > 0) {
        return self.sendError(request, .conflict, "Program already running", "Stop the program first or use restart");
    }

    group.spawnChildren(self.io) catch |err| {
        self.logger.err("Failed to start program '{s}': {s}", .{ name, @errorName(err) });
        return self.sendError(request, .internal_server_error, "Failed to start program", @errorName(err));
    };

    self.logger.info("Started program '{s}' via API", .{name});

    try self.sendSuccess(request, "Program started");
}

fn handleStopProgram(self: *Server, request: *http.Server.Request, name: []const u8) !void {
    const group = self.manager.getGroup(name) orelse {
        return self.sendError(request, .not_found, "Program not found", "No program with that name is configured");
    };

    try group.stop(self.io);

    self.logger.info("Stopped program '{s}' via API", .{name});

    try self.sendSuccess(request, "Program stopped");
}

fn handleRestartProgram(self: *Server, request: *http.Server.Request, name: []const u8) !void {
    const group = self.manager.getGroup(name) orelse {
        return self.sendError(request, .not_found, "Program not found", "No program with that name is configured");
    };

    try group.stop(self.io);

    group.spawnChildren(self.io) catch |err| {
        self.logger.err("Failed to restart program '{s}': {s}", .{ name, @errorName(err) });
        return self.sendError(request, .internal_server_error, "Failed to restart program", @errorName(err));
    };

    self.logger.info("Restarted program '{s}' via API", .{name});

    try self.sendSuccess(request, "Program restarted");
}

fn handleReload(self: *Server, request: *http.Server.Request) !void {
    self.reload.store(true, .seq_cst);
    self.logger.info("Config reload requested via API", .{});
    try self.sendSuccess(request, "Reload scheduled");
}

fn handleShutdown(self: *Server, request: *http.Server.Request) !void {
    self.shutdown.store(true, .seq_cst);
    self.logger.info("Shutdown requested via API", .{});
    try self.sendSuccess(request, "Shutdown scheduled");
}

fn sendSuccess(self: *Server, request: *http.Server.Request, message: []const u8) !void {
    try self.sendJson(request, .ok, .{
        .success = true,
        .message = message,
    });
}

fn sendError(self: *Server, request: *http.Server.Request, status: http.Status, message: []const u8, detail: []const u8) !void {
    try self.sendJson(request, status, .{
        .success = false,
        .err = .{
            .code = @intFromEnum(status),
            .message = message,
            .detail = detail,
        },
    });
}

fn sendJson(self: *Server, request: *http.Server.Request, status: http.Status, payload: anytype) !void {
    var response = std.Io.Writer.Allocating.init(self.gpa);
    defer response.deinit();

    const writer = &response.writer;
    try std.json.Stringify.value(payload, .{}, writer);

    try request.respond(response.written(), .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });

    self.logger.logApiRequest(@tagName(request.head.method), request.head.target, @intFromEnum(status));
}
