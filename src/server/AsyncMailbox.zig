const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
const net = std.net;
const log = std.log;
const posix = std.posix;
const builtin = @import("builtin");
const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;
const AsyncMailbox = @This();

unix_socket_path: []const u8,
server: net.Server,
client: net.Server.Connection,
bell: *std.atomic.Value(bool),
command: common.Command,
payload: [256]u8,

pub fn init(unix_socket_path: []const u8, bell: *std.atomic.Value(bool)) AsyncMailbox {
    return .{
        .unix_socket_path = unix_socket_path,
        .server = undefined,
        .client = undefined,
        .bell = bell,
        .command = undefined,
        .payload = undefined,
    };
}

pub fn start(self: *AsyncMailbox) !void {
    var fatal_error: anyerror = undefined;
    var client_error: anyerror = undefined;
    var client_buffer: [512]u8 = undefined;
    var client_reader: net.Stream.Reader = undefined;
    var reader: *Io.Reader = undefined;

    state: switch (State.mailbox_not_open) {
        .mailbox_not_open => {
            if (fs.cwd().deleteFile(self.unix_socket_path)) {
                log.info("previous {s} deleted.", .{self.unix_socket_path});
            } else |err| {
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            const sockfd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };
            errdefer posix.close(sockfd);

            var address = net.Address.initUnix(self.unix_socket_path) catch |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            posix.bind(sockfd, &address.any, address.getOsSockLen()) catch |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            posix.listen(sockfd, 1) catch |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            self.server = .{
                .listen_address = address,
                .stream = .{
                    .handle = sockfd,
                },
            };

            continue :state .mailbox_wait_for_client;
        },
        .mailbox_wait_for_client => {
            if (self.server.accept()) |connection| {
                self.client = connection;
                continue :state .mailbox_accepted_new_client;
            } else |err| {
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }
        },
        .mailbox_accepted_new_client => {
            client_reader = self.client.stream.reader(&client_buffer);
            reader = client_reader.interface();
            continue :state .mailbox_peek_client_command;
        },
        .mailbox_peek_client_command => {
            if (reader.peekStruct(common.Command, builtin.cpu.arch.endian())) |command| {
                self.command = command;
                continue :state .mailbox_decode_client_command;
            } else |err| {
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            }
        },
        .mailbox_decode_client_command => {
            _ = reader.discard(.limited(@sizeOf(common.Command))) catch |err| {
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };
            switch (self.command.cmd) {
                .dump, .quit, .status, .reload => {
                    continue :state .mailbox_send_notification;
                },
                .start, .restart, .stop => {
                    reader.readSliceAll(self.payload[0..self.command.payload_len]) catch |err| {
                        client_error = err;
                        continue :state .mailbox_encountered_read_error;
                    };
                    continue :state .mailbox_send_notification;
                },
            }
        },
        .mailbox_send_notification => {
            self.bell.store(true, .release);
        },
        .mailbox_encountered_read_error => {
            log.warn("failed to read with client : {}", .{client_error});
            continue :state .mailbox_disconnect_client;
        },
        .mailbox_disconnect_client => {
            self.client.stream.close();
            self.client = undefined;
            continue :state .mailbox_wait_for_client;
        },
        .mailbox_encountered_fatal_error => {},
    }
}

const State = enum {
    mailbox_not_open,
    mailbox_wait_for_client,
    mailbox_peek_client_command,
    mailbox_decode_client_command,
    mailbox_disconnect_client,
    mailbox_accepted_new_client,
    mailbox_encountered_fatal_error,
    mailbox_encountered_read_error,
    mailbox_send_notification,
};
