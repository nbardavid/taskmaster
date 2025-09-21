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
    }
    return true;
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
            if (server_logger.start()) {
                continue :state .server_needs_to_init_process_manager;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_log_error;
            }
        },
        .server_needs_to_init_process_manager => {
            if (server_process_manager.start()) {
                continue :state .server_needs_to_init_mailbox;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_process_error;
            }
        },
        .server_needs_to_init_mailbox => {
            if (server_mailbox.start()) {
                continue :state .server_needs_to_wait_for_command;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_mailbox_error;
            }
        },
        .server_needs_to_wait_for_command => {
            if (self.checkMailbox(&server_mailbox, &cmd, &cmd_payload)) {
                continue :state .server_needs_to_exec_new_command;
            }
        },
        .server_needs_to_exec_new_command => {
            switch (cmd.cmd) {
                .quit => continue :state .server_needs_to_stop,
                else => continue :state .server_needs_to_wait_for_command,
            }
        },
        .server_needs_to_stop => {
            Thread.sleep(std.time.ns_per_s * 10);
            return;
        },
        .server_encountered_fatal_error => {
            log.err("Encountered fatal error {}.", .{fatal_error});
            return fatal_error;
        },
        .server_encountered_log_error => {},
        .server_encountered_mailbox_error => {},
        .server_encountered_process_error => {},
    }
}

const State = enum {
    server_needs_to_wait_for_command,
    server_needs_to_exec_new_command,
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
