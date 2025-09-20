const Server = @This();

gpa: mem.Allocator,
address: net.Address,
sock_path: []const u8,
bell: std.atomic.Value(bool),

pub fn init(gpa: mem.Allocator, sock_path: []const u8) Server {
    return .{
        .gpa = gpa,
        .address = undefined,
        .sock_path = sock_path,
        .bell = .{ .raw = false },
    };
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

pub fn start(self: *Server, config_file: std.fs.File) !void {
    var arena_instance: heap.ArenaAllocator = .init(self.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var config_file_buffer: [4096]u8 = undefined;
    var config_file_reader = config_file.reader(&config_file_buffer);
    const config_reader: *Io.Reader = &config_file_reader.interface;
    var config: Config = .init(arena);

    var server_mailbox: AsyncMailbox = .init(self.sock_path, &self.bell);
    var server_mailbox_thread: Thread = undefined;
    var client_command: common.Command = undefined;
    var client_command_payload: [256]u8 = undefined;
    var fatal_error: anyerror = undefined;

    var process_from_name: StringArrayHashMapUnmanaged(Process) = .empty;
    defer process_from_name.deinit(self.gpa);

    var new_process_from_name: StringArrayHashMapUnmanaged(Process) = .empty;
    defer new_process_from_name.deinit(arena);

    state: switch (State.server_needs_to_start_mailbox) {
        .server_needs_to_start_mailbox => {
            if (Thread.spawn(.{}, AsyncMailbox.start, .{&server_mailbox})) |thread| {
                server_mailbox_thread = thread;
                continue :state .server_needs_to_load_config;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_fatal_error;
            }
        },
        .server_needs_to_load_config => {
            config_file.seekTo(0) catch |err| {
                fatal_error = err;
                continue :state .server_encountered_fatal_error;
            };
            continue :state .server_needs_to_parse_config;
        },
        .server_needs_to_parse_config => {
            config.parse(config_reader) catch |err| {
                fatal_error = err;
                continue :state .server_encountered_syntax_error;
            };
            continue :state .server_needs_to_prepare_config_update;
        },
        .server_needs_to_prepare_config_update => {
            const parsed = config.getParsed();
            new_process_from_name.ensureUnusedCapacity(self.gpa, parsed.len) catch |err| {
                fatal_error = err;
                continue :state .server_encountered_fatal_error;
            };

            for (parsed) |*program| {
                const process = Process.init(program, self.gpa, program.hash()) catch |err| {
                    fatal_error = err;
                    continue :state .server_encountered_fatal_error;
                };
                new_process_from_name.putAssumeCapacity(program.name, process);
            }
        },
        .server_wait_for_command => {},
        .server_encountered_syntax_error => {},
        .server_can_exit_cleanly => {},
        .server_run_client_command => {},
        .server_check_mailbox => {
            if (self.checkMailbox(&server_mailbox, &client_command, &client_command_payload)) {
                continue :state .server_run_client_command;
            } else {
                //TODO
            }
        },
        .server_encountered_fatal_error => {
            log.err("Encountered fatal error {}.", .{fatal_error});
            return;
        },
    }
}

const State = enum {
    server_needs_to_start_mailbox,
    server_needs_to_load_config,
    server_needs_to_parse_config,
    server_needs_to_prepare_config_update,
    server_run_client_command,
    server_encountered_fatal_error,
    server_encountered_syntax_error,
    server_can_exit_cleanly,
    server_wait_for_command,
    server_check_mailbox,
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
