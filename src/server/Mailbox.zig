const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const Io = std.Io;
const posix = std.posix;
const fs = std.fs;
const log = std.log;
const net = std.net;
const Thread = std.Thread;
const builtin = @import("builtin");

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;

const Mailbox = @This();

unix_socket_path: []const u8,
server: ?net.Server = null,
client: ?net.Server.Connection = null,

bell: *std.atomic.Value(bool),
stopping: std.atomic.Value(bool) = .{ .raw = false },
command: common.Command = undefined,
payload: [256]u8 = undefined,
thread: ?Thread = null,

pub fn init(unix_socket_path: []const u8, bell: *std.atomic.Value(bool)) Mailbox {
    return .{
        .unix_socket_path = unix_socket_path,
        .bell = bell,
    };
}

pub fn deinit(self: *Mailbox) void {
    self.stopping.store(true, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

pub fn start(self: *Mailbox) !void {
    self.thread = try Thread.spawn(.{}, Mailbox.mainLoop, .{self});
}

fn mainLoop(self: *Mailbox) !void {
    var fatal_error: anyerror = undefined;
    var client_error: anyerror = undefined;
    var client_buffer: [512]u8 = undefined;
    var client_reader: net.Stream.Reader = undefined;
    var reader: *std.Io.Reader = undefined;

    state: switch (State.mailbox_not_open) {
        .mailbox_not_open => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;

            // remove stale socket file
            fs.cwd().deleteFile(self.unix_socket_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                },
            };

            const sockfd = posix.socket(
                posix.AF.UNIX,
                posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
                0,
            ) catch |err| {
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            var address = net.Address.initUnix(self.unix_socket_path) catch |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            if (posix.bind(sockfd, &address.any, address.getOsSockLen())) |_| {} else |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            if (posix.listen(sockfd, 1)) |_| {} else |err| {
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            self.server = net.Server{
                .listen_address = address,
                .stream = .{ .handle = sockfd },
            };

            continue :state .mailbox_wait_for_client;
        },

        .mailbox_wait_for_client => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;
            if (self.server == null) continue :state .mailbox_shutdown;

            var fds = [_]posix.pollfd{
                .{ .fd = self.server.?.stream.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const rc = posix.poll(&fds, 50) catch |err| {
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            if (rc > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                if (self.server.?.accept()) |connection| {
                    _ = posix.fcntl(connection.stream.handle, posix.F.SETFL, posix.SOCK.NONBLOCK) catch |err| {
                        fatal_error = err;
                        continue :state .mailbox_encountered_fatal_error;
                    };
                    self.client = connection;
                    continue :state .mailbox_accepted_new_client;
                } else |err| {
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                }
            } else {
                continue :state .mailbox_wait_for_client;
            }
        },

        .mailbox_accepted_new_client => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;
            client_reader = self.client.?.stream.reader(&client_buffer);
            reader = client_reader.interface();
            continue :state .mailbox_peek_client_command;
        },

        .mailbox_peek_client_command => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;

            var fds = [_]posix.pollfd{
                .{ .fd = self.client.?.stream.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const rc = posix.poll(&fds, 50) catch |err| {
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };

            if (rc > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                if (reader.peekStruct(common.Command, builtin.cpu.arch.endian())) |command| {
                    self.command = command;
                    continue :state .mailbox_decode_client_command;
                } else |err| switch (err) {
                    error.EndOfStream => continue :state .mailbox_peek_client_command,
                    else => {
                        client_error = err;
                        continue :state .mailbox_encountered_read_error;
                    },
                }
            } else {
                continue :state .mailbox_peek_client_command;
            }
        },

        .mailbox_decode_client_command => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;

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
            continue :state .mailbox_wait_for_client;
        },

        .mailbox_encountered_read_error => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;
            log.warn("failed to read from client: {}", .{client_error});
            continue :state .mailbox_disconnect_client;
        },

        .mailbox_disconnect_client => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;
            if (self.client) |*c| {
                c.stream.close();
            }
            self.client = null;
            continue :state .mailbox_wait_for_client;
        },

        .mailbox_encountered_fatal_error => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_shutdown;
            log.err("fatal error in mailbox: {}", .{fatal_error});
            continue :state .mailbox_shutdown;
        },

        .mailbox_shutdown => {
            if (self.client) |*c| {
                c.stream.close();
                self.client = null;
            }
            if (self.server) |*s| {
                s.stream.close();
                self.server = null;
            }
            return;
        },
    }
}

const State = enum {
    mailbox_not_open,
    mailbox_shutdown,
    mailbox_wait_for_client,
    mailbox_peek_client_command,
    mailbox_decode_client_command,
    mailbox_disconnect_client,
    mailbox_accepted_new_client,
    mailbox_encountered_fatal_error,
    mailbox_encountered_read_error,
    mailbox_send_notification,
};
