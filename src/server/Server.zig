const Server = @This();

gpa: mem.Allocator,
bell: std.atomic.Value(bool),
logger: *Logger = undefined,
signal_handler: SignalHandler,

pub fn init(gpa: mem.Allocator, logger: *Logger) Server {
    return .{
        .gpa = gpa,
        .bell = .{ .raw = false },
        .logger = logger,
        .signal_handler = SignalHandler.init(logger),
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

pub fn start(self: *Server, unix_sock_path: []const u8, config_file_path: []const u8) !void {
    var fatal_error: anyerror = undefined;

    const logger = self.logger;
    var process_manager: ProcessManager = .init(self.gpa, config_file_path, logger);
    defer process_manager.deinit();

    var mailbox: Mailbox = .init(unix_sock_path, &self.bell, logger);
    defer mailbox.deinit();

    // Setup signal handling
    SignalHandler.setGlobalHandler(&self.signal_handler);
    defer SignalHandler.clearGlobalHandler();
    defer self.signal_handler.deinit();

    var cmd: Command = undefined;
    var cmd_payload: [256]u8 = undefined;

    state: switch (State.server_needs_to_setup_signals) {
        .server_needs_to_setup_signals => {
            logger.info("state=SERVER_SETUP_SIGNALS", .{});
            if (self.signal_handler.setup()) {
                logger.info("signal handlers setup successfully", .{});
                continue :state .server_needs_to_check_signals;
            } else |err| {
                logger.err("failed to setup signal handlers: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_fatal_error;
            }
        },

        .server_needs_to_check_signals => {
            // Always check for signals first, before any other operations
            const signals = self.signal_handler.checkSignals();
            if (signals.hasAnySignal()) {
                // Debug: log what signals were detected
                logger.debug("signals detected - sighup={} sigterm={} sigint={} sigchld={}", .{signals.sighup, signals.sigterm, signals.sigint, signals.sigchld});

                // Handle signals immediately here instead of in a separate state
                if (signals.sighup) {
                    logger.info("received SIGHUP - reloading configuration", .{});
                    cmd = Command{ .cmd = .reload, .payload_len = 0 };
                    sendCommand(&process_manager, cmd, &cmd_payload);
                }

                if (signals.sigterm or signals.sigint or signals.sigquit) {
                    const sig_name = if (signals.sigterm) "SIGTERM" else if (signals.sigint) "SIGINT" else "SIGQUIT";
                    logger.info("received {s} - initiating graceful shutdown", .{sig_name});
                    continue :state .server_needs_to_stop;
                }

                if (signals.sigchld) {
                    logger.debug("received SIGCHLD - child process state changed", .{});
                    // ProcessManager will handle child process reaping in its monitor loop
                }

                if (signals.sigusr1) {
                    logger.info("received SIGUSR1 - dumping process status", .{});
                    cmd = Command{ .cmd = .dump, .payload_len = 0 };
                    sendCommand(&process_manager, cmd, &cmd_payload);
                }

                if (signals.sigusr2) {
                    logger.info("received SIGUSR2 - logging status information", .{});
                    cmd = Command{ .cmd = .status, .payload_len = 0 };
                    sendCommand(&process_manager, cmd, &cmd_payload);
                }
            }

            // If no signals, continue with normal operation - determine next state based on initialization
            if (process_manager.thread == null) {
                continue :state .server_needs_to_init_process_manager;
            } else {
                continue :state .server_needs_to_wait_for_command;
            }
        },

        .server_needs_to_init_process_manager => {
            logger.info("state=SERVER_INIT_PROCESS_MANAGER", .{});
            if (process_manager.start()) {
                logger.info("process manager started successfully", .{});
                continue :state .server_needs_to_init_mailbox;
            } else |err| {
                logger.err("failed to start process manager: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_process_error;
            }
        },

        .server_needs_to_init_mailbox => {
            logger.info("state=SERVER_INIT_MAILBOX", .{});
            if (mailbox.start()) {
                logger.info("mailbox started successfully", .{});
                continue :state .server_needs_to_check_signals;
            } else |err| {
                logger.err("failed to start mailbox: {}", .{err});
                fatal_error = err;
                continue :state .server_encountered_mailbox_error;
            }
        },

        .server_needs_to_wait_for_command => {
            if (self.checkMailbox(&mailbox, &cmd, &cmd_payload)) {
                logger.info("received command: {any}", .{cmd.cmd});
                continue :state .server_needs_to_post_new_command;
            } else {
                Thread.sleep(std.time.ns_per_ms);
                continue :state .server_needs_to_check_signals;
            }
        },

        .server_needs_to_post_new_command => {
            logger.info("state=SERVER_EXEC_NEW_COMMAND", .{});
            switch (cmd.cmd) {
                .quit => {
                    logger.info("received quit command, shutting down", .{});
                    continue :state .server_needs_to_stop;
                },
                else => {
                    logger.info("executed command {any}, resuming wait", .{cmd.cmd});
                    continue :state .server_needs_to_send_command;
                },
            }
        },

        .server_needs_to_send_command => {
            sendCommand(&process_manager, cmd, &cmd_payload);
            continue :state .server_needs_to_check_signals;
        },


        .server_needs_to_stop => {
            logger.info("state=SERVER_STOP", .{});
            logger.info("server stopped cleanly", .{});
            return;
        },

        .server_encountered_fatal_error => {
            logger.err("server encountered fatal error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_log_error => {
            logger.err("server stopped due to logger initialization error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_mailbox_error => {
            logger.err("server stopped due to mailbox error: {}", .{fatal_error});
            return fatal_error;
        },

        .server_encountered_process_error => {
            logger.err("server stopped due to process manager error: {}", .{fatal_error});
            return fatal_error;
        },
    }
}

const State = enum {
    server_needs_to_setup_signals,
    server_needs_to_check_signals,
    server_needs_to_wait_for_command,
    server_needs_to_post_new_command,
    server_needs_to_send_command,

    server_needs_to_stop,
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
const SignalHandler = @import("SignalHandler.zig");
