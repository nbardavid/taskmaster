const std = @import("std");
const builtin = @import("builtin");
const proc = std.process;
const Io = std.Io;
const fs = std.fs;
const net = std.net;
const heap = std.heap;
const mem = std.mem;
const log = std.log;
const common = @import("common");
const Job = common.Job;
const Config = common.Config;
const Shell = @import("Shell.zig");
const Command = common.Command;

const max_try_conn = 10;
const task_master_usage =
    \\./taskmaster_client <config.json>;
;

const State = enum {
    client_connected_to_server,
    client_disconnected_from_server,
    client_can_exit,
    client_fetch_inputs,
    client_parse_inputs,
    client_route_command,
    client_send_simple_command,
    client_send_command_and_payload,
    client_received_invalid_command,
    client_flush_command,
    client_send_payload,
    client_encountered_fatal_error,
    client_encountered_write_error,
    client_needs_to_disconnect,
};

pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var stdout_buffer: [heap.pageSize()]u8 = undefined;
    var stdout_writer: fs.File.Writer = fs.File.stdout().writer(&stdout_buffer);

    var argv = proc.argsAlloc(gpa) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer proc.argsFree(gpa, argv);

    const server_path =
        if (argv.len == 2)
            argv[1][0..]
        else
            "/tmp/taskmaster.server.sock";

    var shell: Shell = .init(gpa, &stdout_writer.interface);
    defer shell.deinit();
    shell.enableHistory();

    var client_command: Command = undefined;
    var client_command_payload: []const u8 = "";
    var client_fatal_error: anyerror = error.None;
    var client_input: []const u8 = "";
    var server_buffer: [1024]u8 = undefined;
    var server_writer: net.Stream.Writer = undefined;
    var server_stream: net.Stream = undefined;

    // state machine.
    {
        state: switch (State.client_disconnected_from_server) {
            .client_disconnected_from_server => {
                if (connectToServer(server_path, max_try_conn)) |stream| {
                    server_stream = stream;
                    continue :state .client_connected_to_server;
                } else |err| {
                    client_fatal_error = err;
                    continue :state .client_encountered_fatal_error;
                }
            },
            .client_connected_to_server => {
                log.info("client is connected to server at {s}", .{server_path});
                server_writer = server_stream.writer(&server_buffer);
                continue :state .client_fetch_inputs;
            },
            .client_fetch_inputs => {
                if (shell.readline("taskmaster |>")) |line| {
                    client_input = line;
                    continue :state .client_parse_inputs;
                } else |err| {
                    client_fatal_error = err;
                    continue :state .client_encountered_fatal_error;
                }
            },
            .client_parse_inputs => {
                var it = mem.tokenizeScalar(u8, client_input, ' ');
                const first_token = it.next() orelse "";
                client_command_payload = it.next() orelse "";

                if (parseCommand(first_token, client_command_payload)) |valid| {
                    client_command = valid;
                    continue :state .client_route_command;
                } else |err| {
                    client_fatal_error = err;
                    continue :state .client_received_invalid_command;
                }
            },
            .client_route_command => {
                if (client_command.payload_len != 0)
                    continue :state .client_send_command_and_payload
                else
                    continue :state .client_send_simple_command;
            },
            .client_send_simple_command => {
                const writer = &server_writer.interface;
                if (writer.writeStruct(client_command, builtin.cpu.arch.endian())) {
                    continue :state .client_flush_command;
                } else |err| {
                    log.warn("failed to send command to server : {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },
            .client_send_command_and_payload => {
                const writer = &server_writer.interface;
                if (writer.writeStruct(client_command, builtin.cpu.arch.endian())) {
                    continue :state .client_send_payload;
                } else |err| {
                    log.warn("failed to send command to server : {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },
            .client_send_payload => {
                const writer = &server_writer.interface;
                if (writer.writeAll(client_command_payload)) {
                    continue :state .client_flush_command;
                } else |err| {
                    log.warn("failed to send command payload to server : {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },
            .client_flush_command => {
                const writer = &server_writer.interface;
                if (writer.flush()) {
                    continue :state .client_fetch_inputs;
                } else |err| {
                    log.warn("failed to flush command to server : {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },
            .client_needs_to_disconnect => {
                server_stream.close();
                server_writer = undefined;
                continue :state .client_disconnected_from_server;
            },
            .client_received_invalid_command => {
                log.info("failed to recognize : {s} not a command.", .{client_input});
                continue :state .client_fetch_inputs;
            },
            .client_encountered_fatal_error => {
                log.err("fatal error encountered : {}", .{client_fatal_error});
                return;
            },
            .client_encountered_write_error => {
                log.warn("failed to write command to server : {}", .{client_fatal_error});
                continue :state .client_needs_to_disconnect;
            },
            else => continue :state .client_can_exit,
        }
    }
}

fn connectToServer(path: []const u8, attempts: usize) !net.Stream {
    return for (0..attempts) |i| {
        log.info("[{d}/{d}] : attempting to connect to server at : '{s}'", .{ i + 1, max_try_conn, path });
        if (net.connectUnixSocket(path)) |stream| {
            return stream;
        } else |err| {
            log.err("failed to connect to server : {}", .{err});
            std.Thread.sleep(std.time.ns_per_s);
        }
    } else {
        log.err("[{d}/{d}] attempts failed. stoping now.", .{ max_try_conn, max_try_conn });
        return error.FailedToReconnect;
    };
}

fn parseCommand(cmd: []const u8, payload: []const u8) !Command {
    const first_token =
        if (cmd.len >= 4)
            cmd
        else
            return error.InvalidCommand;

    if (mem.eql(u8, "status", first_token)) {
        return .{ .cmd = .status, .payload_len = 0 };
    } else if (mem.eql(u8, "reload", first_token)) {
        return .{ .cmd = .reload, .payload_len = 0 };
    } else if (mem.eql(u8, "dump", first_token)) {
        return .{ .cmd = .dump, .payload_len = 0 };
    } else if (mem.eql(u8, "quit", first_token)) {
        return .{ .cmd = .quit, .payload_len = 0 };
    }

    const argument_len: u8 =
        if (payload.len > 0 and payload.len < std.math.maxInt(u8))
            @intCast(payload.len)
        else
            return error.InvalidArgumentLength;

    if (mem.eql(u8, "start", first_token)) {
        return .{ .cmd = .start, .payload_len = argument_len };
    } else if (mem.eql(u8, "stop", first_token)) {
        return .{ .cmd = .stop, .payload_len = argument_len };
    } else if (mem.eql(u8, "restart", first_token)) {
        return .{ .cmd = .restart, .payload_len = argument_len };
    }

    return error.InvalidCommand;
}
