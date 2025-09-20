const Server = @This();

gpa: mem.Allocator,
bell: std.atomic.Value(bool),
mailbox: AsyncMailbox,
config: Config,
logger: *Logger,

pub fn init(gpa: mem.Allocator) Server {
    return .{
        .gpa = gpa,
        .address = undefined,
        .bell = .{ .raw = false },
        .mailbox = undefined,
        .config = undefined,
        .logger = undefined,
    };
}

fn initLogger(self: *Server, log_file_path: []const u8) !*Logger {
    const logger: *Logger = try .init(self.gpa, 32);
    errdefer logger.deinit();

    try logger.start();
    try logger.addOwnedFileSink(log_file_path);
    return logger;
}

fn initConfig(_: *Server, config_file_path: []const u8) !Config {
    const config: Config = .init();
    errdefer config.deinit();
    try config.open(config_file_path);
}

fn initMailbox(self: *Server, unix_sock_path: []const u8) !AsyncMailbox {
    const mailbox: AsyncMailbox = .init(unix_sock_path, &self.bell, self.logger);
    mailbox.thread = Thread.spawn(.{}, AsyncMailbox.start, .{&self.mailbox});
    return mailbox;
}

fn checkMailbox(self: *Server, mailbox: *AsyncMailbox, out_command: *common.Command, out_payload: *[256]u8) bool {
    if (self.bell.load(.acquire)) {
        out_command.* = mailbox.command;
        const payload_len = mailbox.command.payload_len;
        @memcpy(out_payload[0..payload_len], mailbox.payload[0..payload_len]);
        self.bell.store(false, .monotonic);
    }
    return true;
}

pub fn start(self: *Server, log_file_path: []const u8, unix_sock_path: []const u8, config_file_path: []const u8) !void {
    var fatal_error: anyerror = undefined;

    state: switch (State.server_needs_to_init_logger) {
        .server_needs_to_init_logger => {
            if (self.initLogger(log_file_path)) |logger| {
                self.logger = logger;
                continue :state .server_needs_to_init_config;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_log_error;
            }
        },
        .server_needs_to_init_config => {
            if (self.initConfig(config_file_path)) |config| {
                self.config = config;
                continue :state .server_needs_to_init_mailbox;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_config_error;
            }
        },
        .server_needs_to_init_mailbox => {
            if (self.initMailbox(unix_sock_path)) |mailbox| {
                self.mailbox = mailbox;
                continue :state .server_needs_to_init_process_manager;
            }
        },
        .server_needs_to_init_process_manager => {},
        .server_encountered_fatal_error => {
            log.err("Encountered fatal error {}.", .{fatal_error});
            return;
        },
        .server_encountered_log_error => {},
        .server_encountered_config_error => {},
        .server_encountered_mailbox_error => {},
        .server_encountered_process_error => {},
    }
}

const State = enum {
    server_needs_to_init_logger,
    server_needs_to_init_config,
    server_needs_to_init_mailbox,
    server_needs_to_init_process_manager,
    server_encountered_fatal_error,
    server_encountered_log_error,
    server_encountered_config_error,
    server_encountered_mailbox_error,
    server_encountered_process_error,
};

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
const net = std.net;
const log = std.log;
const posix = std.posix;
const Thread = std.Thread;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;
const Command = common.Command;
const Program = common.Program;
const Process = common.Process;
const AsyncMailbox = @import("AsyncMailbox.zig");
