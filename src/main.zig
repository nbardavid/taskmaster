const std = @import("std");
const Io = std.Io;
const fs = std.fs;
const json = std.json;
const http = std.http;
const process = std.process;
const mem = std.mem;
const heap = std.heap;
const posix = std.posix;
const log = std.log;
const atomic = std.atomic;

const zproc = @import("zproc");

var shutdown_requested = atomic.Value(bool).init(false);
var reload_requested = atomic.Value(bool).init(false);

const ConfigReloader = struct {
    gpa: mem.Allocator,
    config_path: []const u8,
    parser: zproc.ConfigParser,

    pub fn init(gpa: mem.Allocator, config_path: []const u8) !ConfigReloader {
        var parser = zproc.ConfigParser.init(gpa);
        errdefer parser.deinit();

        parser.parseFromFile(config_path) catch |err| {
            std.log.err("Failed to parse configuration file '{s}': {s}", .{ config_path, @errorName(err) });
            return err;
        };

        return .{
            .gpa = gpa,
            .config_path = config_path,
            .parser = parser,
        };
    }

    pub fn deinit(self: *ConfigReloader) void {
        self.parser.deinit();
    }

    pub fn reload(self: *ConfigReloader, manager: *zproc.ProcessGroupManager, logger: *zproc.Logger) void {
        var new_parser = zproc.ConfigParser.init(self.gpa);
        errdefer new_parser.deinit();

        new_parser.parseFromFile(self.config_path) catch |err| {
            logger.logConfigError(self.config_path, @errorName(err));
            return;
        };

        const new_config = new_parser.getConfig() catch |err| {
            logger.logConfigError(self.config_path, @errorName(err));
            return;
        };

        const old_config = self.parser.getConfig() catch |err| {
            logger.logConfigError(self.config_path, @errorName(err));
            return;
        };

        manager.reloadConfig(old_config, new_config) catch |err| {
            logger.err("Failed to apply configuration reload: {s}", .{@errorName(err)});
            return;
        };

        self.parser.deinit();
        self.parser = new_parser;
        logger.logConfigReloaded(self.config_path);
    }
};

const Monitor = struct {
    manager: *zproc.ProcessGroupManager,
    io: Io,
    shutdown: *atomic.Value(bool),
    reload: *atomic.Value(bool),
    reloader: *ConfigReloader,
    logger: *zproc.Logger,
};

fn runMonitor(ctx: *Monitor) void {
    while (!ctx.shutdown.load(.acquire)) {
        if (ctx.reload.swap(false, .acq_rel)) {
            ctx.reloader.reload(ctx.manager, ctx.logger);
        }

        ctx.manager.monitor() catch |err| {
            ctx.logger.err("Monitor execution failure: {s}", .{@errorName(err)});
        };

        ctx.io.sleep(Io.Duration.fromMilliseconds(100), Io.Clock.boot) catch {};
    }
}

fn onSignal(sig: posix.SIG) callconv(.c) void {
    switch (sig) {
        .INT, .TERM => shutdown_requested.store(true, .seq_cst),
        .HUP => reload_requested.store(true, .seq_cst),
        else => {},
    }
}

fn setupSignalHandlers() !void {
    const action = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
    posix.sigaction(.HUP, &action, null);
}

comptime {
    std.testing.refAllDecls(zproc);
}

pub fn main() !void {
    const gpa = heap.smp_allocator;

    var threaded: Io.Threaded = .init(gpa);
    defer threaded.deinit();

    const io = threaded.io();

    const argv = process.argsAlloc(gpa) catch |err| {
        std.log.err("Failed to allocate memory for command line arguments: {s}", .{@errorName(err)});
        return err;
    };
    defer process.argsFree(gpa, argv);

    const config_path = if (argv.len > 1) argv[1] else "config.json";

    const log_path = "/tmp/taskmaster.log";
    var logger = zproc.Logger.init(log_path, io, gpa) catch |err| {
        std.log.err("Failed to initialize logger at '{s}': {s}", .{ log_path, @errorName(err) });
        return err;
    };
    defer logger.deinit();

    logger.info("Starting Taskmaster supervisor...", .{});
    logger.logConfigLoaded(config_path);

    var reloader = ConfigReloader.init(gpa, config_path) catch |err| {
        logger.logConfigError(config_path, @errorName(err));
        return err;
    };
    defer reloader.deinit();

    var manager = zproc.ProcessGroupManager.init(gpa, io, &logger);
    defer manager.deinit();

    const config = reloader.parser.getConfig() catch |err| {
        logger.logConfigError(config_path, @errorName(err));
        return err;
    };

    logger.info("Loaded {d} program configuration(s)", .{config.programs.map.count()});

    var config_iter = config.programs.map.iterator();
    while (config_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const prog = entry.value_ptr;
        try manager.createGroup(name, prog);
    }

    try manager.startAll();

    try setupSignalHandlers();

    var monitor_ctx = Monitor{
        .manager = &manager,
        .io = io,
        .shutdown = &shutdown_requested,
        .reload = &reload_requested,
        .reloader = &reloader,
        .logger = &logger,
    };
    var monitor_thread = try std.Thread.spawn(.{}, runMonitor, .{&monitor_ctx});

    const port: u16 = 8080;
    var server = zproc.Server.Server{
        .gpa = gpa,
        .io = io,
        .config = config.*,
        .manager = &manager,
        .logger = &logger,
        .port = port,
        .reload = &reload_requested,
        .shutdown = &shutdown_requested,
    };

    logger.info("Starting HTTP API server on port {d}", .{port});

    var listen_err: ?anyerror = null;
    server.listen() catch |err| {
        listen_err = err;
        logger.err("HTTP server execution error: {s}", .{@errorName(err)});
    };

    if (shutdown_requested.load(.acquire)) {
        logger.info("Termination signal received, initiating shutdown", .{});
    }

    shutdown_requested.store(true, .seq_cst);
    monitor_thread.join();

    manager.stopAll() catch |err| {
        logger.err("Failed to stop process groups during shutdown: {s}", .{@errorName(err)});
    };

    logger.logServerStopped();

    if (listen_err) |err| return err;
}
