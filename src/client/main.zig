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
    \\./taskmaster_client ;
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
    client_resend_pending,
    client_wait_for_response,
    client_read_response_header,
    client_read_response_payload,
    client_display_response,
};

pub fn main() !void {
    var gpa_instance: heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var stdout_buffer: [heap.pageSize()]u8 = undefined;
    var stdout_writer: fs.File.Writer = fs.File.stdout().writer(&stdout_buffer);

    const argv = proc.argsAlloc(gpa) catch |err| {
        log.err("Fatal error encountered {}", .{err});
        return;
    };
    defer proc.argsFree(gpa, argv);

    const server_path = "/tmp/taskmaster.server.sock";

    if (argv.len > 1) {
        return runOneShot(gpa, server_path, argv[1..]);
    }

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
    var pending_command: ?Command = null;
    var pending_payload: []const u8 = "";
    var server_read_buffer: [4096]u8 = undefined;
    var server_reader: net.Stream.Reader = undefined;
    var server_response: common.Response = undefined;
    var server_response_payload: []u8 = undefined;

    log.info("client started (server path={s})", .{server_path});

    {
        state: switch (State.client_disconnected_from_server) {
            .client_disconnected_from_server => {
                log.info("state=CLIENT_DISCONNECTED", .{});
                if (connectToServer(server_path, max_try_conn)) |stream| {
                    log.info("connected to server socket", .{});
                    server_stream = stream;
                    continue :state .client_connected_to_server;
                } else |err| {
                    log.err("failed to connect to server: {}", .{err});
                    client_fatal_error = err;
                    continue :state .client_encountered_fatal_error;
                }
            },

            .client_connected_to_server => {
                log.info("state=CLIENT_CONNECTED", .{});
                server_writer = server_stream.writer(&server_buffer);
                server_reader = server_stream.reader(&server_read_buffer);

                if (pending_command) |pcmd| {
                    log.info("have pending command {any}, resending", .{pcmd.cmd});
                    client_command = pcmd;
                    client_command_payload = pending_payload;
                    pending_command = null;
                    continue :state .client_route_command;
                } else {
                    continue :state .client_fetch_inputs;
                }
            },

            .client_fetch_inputs => {
                log.debug("state=CLIENT_FETCH_INPUTS", .{});
                if (shell.readline("taskmaster |>")) |line| {
                    log.debug("user input received: \"{s}\"", .{line});
                    client_input = line;
                    continue :state .client_parse_inputs;
                } else |err| {
                    log.err("readline failed: {}", .{err});
                    client_fatal_error = err;
                    continue :state .client_encountered_fatal_error;
                }
            },

            .client_parse_inputs => {
                log.debug("state=CLIENT_PARSE_INPUTS input=\"{s}\"", .{client_input});
                var it = mem.tokenizeScalar(u8, client_input, ' ');
                const first_token = it.next() orelse "";
                client_command_payload = it.next() orelse "";

                if (parseCommand(first_token, client_command_payload)) |valid| {
                    client_command = valid;
                    log.info("parsed command={any} payload_len={d}", .{
                        client_command.cmd, client_command.payload_len,
                    });
                    continue :state .client_route_command;
                } else |err| {
                    log.warn("invalid command: \"{s}\" ({})", .{ first_token, err });
                    client_fatal_error = err;
                    continue :state .client_received_invalid_command;
                }
            },

            .client_route_command => {
                log.debug("state=CLIENT_ROUTE_COMMAND", .{});
                if (client_command.payload_len != 0) {
                    log.info("routing to SEND_COMMAND_AND_PAYLOAD", .{});
                    continue :state .client_send_command_and_payload;
                } else {
                    log.info("routing to SEND_SIMPLE_COMMAND", .{});
                    continue :state .client_send_simple_command;
                }
            },

            .client_send_simple_command => {
                log.debug("state=CLIENT_SEND_SIMPLE_COMMAND", .{});
                const writer = &server_writer.interface;
                if (writer.writeStruct(client_command, builtin.cpu.arch.endian())) {
                    log.info("sent simple command {any}", .{client_command.cmd});
                    continue :state .client_flush_command;
                } else |err| {
                    pending_command = client_command;
                    pending_payload = client_command_payload;
                    log.warn("failed to send simple command: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_send_command_and_payload => {
                log.debug("state=CLIENT_SEND_COMMAND_AND_PAYLOAD", .{});
                const writer = &server_writer.interface;
                if (writer.writeStruct(client_command, builtin.cpu.arch.endian())) {
                    log.info("sent command struct {any}, now sending payload", .{client_command.cmd});
                    continue :state .client_send_payload;
                } else |err| {
                    pending_command = client_command;
                    pending_payload = client_command_payload;
                    log.warn("failed to send command struct: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_send_payload => {
                log.debug("state=CLIENT_SEND_PAYLOAD", .{});
                const writer = &server_writer.interface;
                if (writer.writeAll(client_command_payload)) {
                    log.info("sent payload of {d} bytes", .{client_command_payload.len});
                    continue :state .client_flush_command;
                } else |err| {
                    pending_command = client_command;
                    pending_payload = client_command_payload;
                    log.warn("failed to send payload: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_flush_command => {
                log.debug("state=CLIENT_FLUSH_COMMAND", .{});
                const writer = &server_writer.interface;
                if (writer.flush()) {
                    log.info("command flush succeeded", .{});
                    continue :state .client_wait_for_response;
                } else |err| {
                    pending_command = client_command;
                    pending_payload = client_command_payload;
                    log.warn("failed to flush command: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_wait_for_response => {
                log.debug("state=CLIENT_WAIT_FOR_RESPONSE", .{});
                continue :state .client_read_response_header;
            },

            .client_read_response_header => {
                log.debug("state=CLIENT_READ_RESPONSE_HEADER", .{});
                const reader = server_reader.interface();
                if (reader.peekStruct(common.Response, builtin.cpu.arch.endian())) |response| {
                    log.info("received response: status={s} payload_len={d}", .{ @tagName(response.status), response.payload_len });
                    server_response = response;
                    _ = reader.discard(.limited(@sizeOf(common.Response))) catch |err| {
                        log.err("failed to discard response header: {}", .{err});
                        continue :state .client_needs_to_disconnect;
                    };
                    if (response.payload_len > 0) {
                        continue :state .client_read_response_payload;
                    } else {
                        server_response_payload = &[_]u8{};
                        continue :state .client_display_response;
                    }
                } else |err| {
                    log.err("failed to read response header: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_read_response_payload => {
                log.debug("state=CLIENT_READ_RESPONSE_PAYLOAD", .{});
                const reader = server_reader.interface();
                const payload_len = server_response.payload_len;

                const payload_buffer = gpa.alloc(u8, payload_len) catch |err| {
                    log.err("failed to allocate payload buffer: {}", .{err});
                    continue :state .client_needs_to_disconnect;
                };

                if (reader.readSliceAll(payload_buffer)) |_| {
                    log.debug("received response payload: {d} bytes", .{payload_len});
                    server_response_payload = payload_buffer;
                    continue :state .client_display_response;
                } else |err| {
                    log.err("failed to read response payload: {}", .{err});
                    gpa.free(payload_buffer);
                    continue :state .client_needs_to_disconnect;
                }
            },

            .client_display_response => {
                log.debug("state=CLIENT_DISPLAY_RESPONSE", .{});
                const out = fs.File.stdout();
                out.writeAll(server_response_payload) catch |err| {
                    log.warn("failed to write response to stdout: {}", .{err});
                };

                if (server_response_payload.len > 0) {
                    gpa.free(server_response_payload);
                }

                continue :state .client_fetch_inputs;
            },

            .client_needs_to_disconnect => {
                log.warn("state=CLIENT_DISCONNECT: closing stream", .{});
                server_stream.close();
                server_writer = undefined;
                continue :state .client_disconnected_from_server;
            },

            .client_received_invalid_command => {
                log.info("state=CLIENT_INVALID_COMMAND input=\"{s}\"", .{client_input});
                continue :state .client_fetch_inputs;
            },

            .client_encountered_fatal_error => {
                log.err("state=CLIENT_FATAL_ERROR: {}", .{client_fatal_error});
                return;
            },

            .client_encountered_write_error => {
                log.warn("state=CLIENT_WRITE_ERROR: {}", .{client_fatal_error});
                continue :state .client_needs_to_disconnect;
            },

            else => {
                log.info("state=CLIENT_CAN_EXIT", .{});
                continue :state .client_can_exit;
            },
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

    if (mem.eql(u8, "reload", first_token)) {
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

    if (mem.eql(u8, "status", first_token)) {
        return .{ .cmd = .status, .payload_len = argument_len };
    } else if (mem.eql(u8, "start", first_token)) {
        return .{ .cmd = .start, .payload_len = argument_len };
    } else if (mem.eql(u8, "stop", first_token)) {
        return .{ .cmd = .stop, .payload_len = argument_len };
    } else if (mem.eql(u8, "restart", first_token)) {
        return .{ .cmd = .restart, .payload_len = argument_len };
    }

    return error.InvalidCommand;
}

fn runOneShot(gpa: mem.Allocator, server_path: []const u8, args: []const []const u8) !void {
    var server_buffer: [1024]u8 = undefined;

    log.info("one-shot mode: connecting to server", .{});
    const server_stream = connectToServer(server_path, max_try_conn) catch |err| {
        log.err("failed to connect to server: {}", .{err});
        return err;
    };
    defer server_stream.close();

    const command_str = try mem.join(gpa, " ", args);
    defer gpa.free(command_str);

    log.info("one-shot mode: executing command: \"{s}\"", .{command_str});

    var it = mem.tokenizeScalar(u8, command_str, ' ');
    const first_token = it.next() orelse return error.NoCommand;
    const payload = it.next() orelse "";

    const client_command = parseCommand(first_token, payload) catch |err| {
        log.err("invalid command: \"{s}\" ({})", .{ first_token, err });
        return err;
    };

    log.info("parsed command={any} payload_len={d}", .{
        client_command.cmd,
        client_command.payload_len,
    });

    var server_writer = server_stream.writer(&server_buffer);
    const writer = &server_writer.interface;

    writer.writeStruct(client_command, builtin.cpu.arch.endian()) catch |err| {
        log.err("failed to send command: {}", .{err});
        return err;
    };

    if (client_command.payload_len != 0) {
        writer.writeAll(payload) catch |err| {
            log.err("failed to send payload: {}", .{err});
            return err;
        };
    }

    writer.flush() catch |err| {
        log.err("failed to flush command: {}", .{err});
        return err;
    };

    log.info("one-shot mode: command sent successfully", .{});

    var read_buffer: [4096]u8 = undefined;
    var server_reader = server_stream.reader(&read_buffer);
    const reader = server_reader.interface();

    const response = reader.peekStruct(common.Response, builtin.cpu.arch.endian()) catch |err| {
        log.err("failed to read response: {}", .{err});
        return err;
    };

    _ = reader.discard(.limited(@sizeOf(common.Response))) catch |err| {
        log.err("failed to discard response header: {}", .{err});
        return err;
    };

    log.info("received response: status={s} payload_len={d}", .{ @tagName(response.status), response.payload_len });

    if (response.payload_len > 0) {
        const payload_buffer = try gpa.alloc(u8, response.payload_len);
        defer gpa.free(payload_buffer);

        reader.readSliceAll(payload_buffer) catch |err| {
            log.err("failed to read response payload: {}", .{err});
            return err;
        };

        const stdout = fs.File.stdout();
        stdout.writeAll(payload_buffer) catch |err| {
            log.err("failed to write response to stdout: {}", .{err});
            return err;
        };
    }
}
