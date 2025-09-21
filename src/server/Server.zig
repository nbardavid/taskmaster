const Server = @This();

gpa: mem.Allocator,
bell: std.atomic.Value(bool),

pub fn init(gpa: mem.Allocator) Server {
    return .{
        .gpa = gpa,
        .bell = .{ .raw = false },
    };
}

fn checkMailbox(self: *Server, mailbox: *Mailbox, out_command: *common.Command, out_payload: *[256]u8) bool {
    if (self.bell.load(.acquire)) {
        out_command.* = mailbox.command;
        const payload_len = mailbox.command.payload_len;
        @memcpy(out_payload[0..payload_len], mailbox.payload[0..payload_len]);
        self.bell.store(false, .monotonic);
        return true;
    }
    return false;
}

fn sendCommand(process_manager: *ProcessManager, cmd: Command, cmd_payload: *[256]u8) void {
    process_manager.cmd = cmd;
    @memcpy(&process_manager.cmd_payload, cmd_payload);
    process_manager.new_cmd.store(true, .release);
    log.info("server: queued command {any} for process manager", .{cmd.cmd});
}

pub fn start(self: *Server, log_file_path: []const u8, unix_sock_path: []const u8, config_file_path: []const u8) !void {
    var fatal_error: anyerror = undefined;

    var server_logger: Logger = .init(self.gpa, log_file_path, 32);
    defer server_logger.deinit();

    var server_process_manager: ProcessManager = .init(self.gpa, config_file_path);
    defer server_process_manager.deinit();

    var server_mailbox: Mailbox = .init(unix_sock_path, &self.bell);
    defer server_mailbox.deinit();

    var cmd: Command = undefined;
    var cmd_payload: [256]u8 = undefined;

    state: switch (State.server_needs_to_init_logger) {
        .server_needs_to_init_logger => {
            log.info("state=SERVER_INIT_LOGGER", .{});
            if (server_logger.start()) {
                log.info("logger initialized successfully", .{});
                continue :state .server_needs_to_init_process_manager;
            } else |err| {
                log.err("failed to init logger: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_log_error;
            }
        },

        .server_needs_to_init_process_manager => {
            log.info("state=SERVER_INIT_PROCESS_MANAGER", .{});
            if (server_process_manager.start()) {
                log.info("process manager started successfully", .{});
                continue :state .server_needs_to_init_mailbox;
            } else |err| {
                log.err("failed to start process manager: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_process_error;
            }
        },

        .server_needs_to_init_mailbox => {
            log.info("state=SERVER_INIT_MAILBOX", .{});
            if (server_mailbox.start()) {
                log.info("mailbox started successfully", .{});
                continue :state .server_needs_to_wait_for_command;
            } else |err| {
                log.err("failed to start mailbox: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_mailbox_error;
            }
        },

        .server_needs_to_wait_for_command => {
            if (self.checkMailbox(&server_mailbox, &cmd, &cmd_payload)) {
                log.info("received command: {any}", .{cmd.cmd});
                continue :state .server_needs_to_post_new_command;
            } else {
                Thread.sleep(std.time.ns_per_ms);
                continue :state .server_needs_to_wait_for_command;
            }
        },

        .server_needs_to_post_new_command => {
            log.info("state=SERVER_EXEC_NEW_COMMAND", .{});
            switch (cmd.cmd) {
                .quit => {
                    log.info("received quit command, shutting down", .{});
                    continue :state .server_needs_to_stop;
                },
                else => {
                    log.info("executed command {any}, resuming wait", .{cmd.cmd});
                    continue :state .server_needs_to_send_command;
                },
            }
        },

        .server_needs_to_send_command => {
            sendCommand(&server_process_manager, cmd, &cmd_payload);
            continue :state .server_needs_to_wait_for_command;
        },

        .server_needs_to_stop => {
            log.info("state=SERVER_STOP", .{});
            Thread.sleep(std.time.ns_per_s * 10);
            log.info("server stopped cleanly", .{});
            return;
        },

        .server_encountered_fatal_error => {
            log.err("server encountered fatal error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_log_error => {
            log.err("server stopped due to logger initialization error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_mailbox_error => {
            log.err("server stopped due to mailbox error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_process_error => {
            log.err("server stopped due to process manager error: {}", .{fatal_error});
            return fatal_error;
        },
    }
}

const State = enum {
    server_needs_to_wait_for_command,
    server_needs_to_post_new_command,
    server_needs_to_send_command,

    server_needs_to_stop,
    server_needs_to_init_logger,
    server_needs_to_init_mailbox,
    server_needs_to_init_process_manager,
    server_encountered_log_error,
    server_encountered_mailbox_error,
    server_encountered_process_error,
    server_encountered_fatal_error,
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
const ProcessManager = @import("ProcessManager.zig");
const Mailbox = @import("Mailbox.zig");
