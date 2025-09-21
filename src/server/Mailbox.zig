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

    log.info("MAILBOX thread start: self_ptr=0x{x}", .{@intFromPtr(self)});

    state: switch (State.mailbox_is_not_ready) {
        .mailbox_is_not_ready => {
            log.info("state=MAILBOX_NOT_OPEN stop={} srv_null={}", .{
                self.stopping.load(.acquire), self.server == null,
            });
            if (self.stopping.load(.acquire)) {
                log.warn("transition to SHUTDOWN (stopping=true) from NOT_OPEN", .{});
                continue :state .mailbox_needs_to_shutdown;
            }

            fs.cwd().deleteFile(self.unix_socket_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    log.err("failed to delete stale socket file: {}", .{err});
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                },
            };

            const sockfd = posix.socket(
                posix.AF.UNIX,
                posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
                0,
            ) catch |err| {
                log.err("socket creation failed: {}", .{err});
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };
            log.info("socket created fd={d}", .{sockfd});

            var address = net.Address.initUnix(self.unix_socket_path) catch |err| {
                log.err("failed to init unix socket address: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            if (posix.bind(sockfd, &address.any, address.getOsSockLen())) |_| {
                log.info("bound unix socket at {s}", .{self.unix_socket_path});
            } else |err| {
                log.err("bind failed: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            if (posix.listen(sockfd, 1)) |_| {
                log.info("listening on mailbox socket (fd={d})", .{sockfd});
            } else |err| {
                log.err("listen failed: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            self.server = net.Server{
                .listen_address = address,
                .stream = .{ .handle = sockfd },
            };
            log.info("server set: srv_null={} fd={d}", .{ self.server == null, self.server.?.stream.handle });

            continue :state .mailbox_wait_for_client_to_connect;
        },

        .mailbox_wait_for_client_to_connect => {
            const stop = self.stopping.load(.acquire);
            const srv_null = self.server == null;
            log.debug("state=MAILBOX_WAIT_FOR_CLIENT stop={} srv_null={}", .{ stop, srv_null });

            if (stop or srv_null) {
                if (stop) log.warn("WAIT -> SHUTDOWN (stopping=true)", .{});
                if (srv_null) log.warn("WAIT -> SHUTDOWN (server=null)", .{});
                continue :state .mailbox_needs_to_shutdown;
            }

            const fd = self.server.?.stream.handle;
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};

            const rc = posix.poll(&fds, 200) catch |err| {
                log.err("poll on server socket failed: {}", .{err});
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };
            log.debug("poll(server_fd={d}) -> rc={} revents=0x{x}", .{ fd, rc, fds[0].revents });

            if (rc == 0) {
                continue :state .mailbox_wait_for_client_to_connect;
            }

            if ((fds[0].revents & posix.POLL.IN) != 0) {
                if (self.server.?.accept()) |connection| {
                    log.info("accepted new client: fd={d}", .{connection.stream.handle});

                    _ = posix.fcntl(connection.stream.handle, posix.F.SETFL, posix.SOCK.NONBLOCK) catch |err| {
                        log.err("failed to set client socket nonblocking: {}", .{err});
                        fatal_error = err;
                        continue :state .mailbox_encountered_fatal_error;
                    };
                    self.client = connection;
                    continue :state .mailbox_has_accepted_a_client;
                } else |err| {
                    log.err("accept failed: {}", .{err});
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                }
            }

            log.warn("server revents=0x{x} -> restart listener", .{fds[0].revents});
            continue :state .mailbox_needs_to_shutdown;
        },

        .mailbox_has_accepted_a_client => {
            log.info("state=MAILBOX_ACCEPTED_NEW_CLIENT stop={} cli_null={}", .{
                self.stopping.load(.acquire), self.client == null,
            });
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;
            client_reader = self.client.?.stream.reader(&client_buffer);
            reader = client_reader.interface();
            continue :state .mailbox_needs_to_peek_client_command;
        },

        .mailbox_needs_to_peek_client_command => {
            log.debug("state=MAILBOX_PEEK_CLIENT_COMMAND stop={} cli_fd={}", .{
                self.stopping.load(.acquire), self.client.?.stream.handle,
            });
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            var fds = [_]posix.pollfd{
                .{ .fd = self.client.?.stream.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const rc = posix.poll(&fds, 200) catch |err| {
                log.err("poll on client socket failed: {}", .{err});
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };

            if (rc == 0) continue :state .mailbox_needs_to_peek_client_command;

            const revents = fds[0].revents;
            if ((revents & posix.POLL.IN) != 0) {
                if (reader.peekStruct(common.Command, builtin.cpu.arch.endian())) |command| {
                    log.info("peeked client command: {any}", .{command.cmd});
                    self.command = command;
                    continue :state .mailbox_needs_to_decode_client_command;
                } else |err| switch (err) {
                    error.EndOfStream => {
                        log.info("client EOF; disconnecting", .{});
                        continue :state .mailbox_needs_to_disconnect_client;
                    },
                    else => {
                        log.warn("error peeking client command: {}", .{err});
                        client_error = err;
                        continue :state .mailbox_encountered_read_error;
                    },
                }
            }

            if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                log.info("client hangup/error (revents=0x{x}); disconnecting", .{revents});
                continue :state .mailbox_needs_to_disconnect_client;
            }

            log.warn("unexpected client revents=0x{x}; disconnecting", .{revents});
            continue :state .mailbox_needs_to_disconnect_client;
        },

        .mailbox_needs_to_decode_client_command => {
            log.info("state=MAILBOX_DECODE_CLIENT_COMMAND", .{});
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            _ = reader.discard(.limited(@sizeOf(common.Command))) catch |err| {
                log.warn("failed to discard command header: {}", .{err});
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };

            switch (self.command.cmd) {
                .dump, .quit, .status, .reload => {
                    log.info("client command: {any}", .{self.command.cmd});
                    continue :state .mailbox_needs_to_send_a_notification;
                },
                .start, .restart, .stop => {
                    log.info("client command: {any} (payload {d} bytes)", .{ self.command.cmd, self.command.payload_len });
                    reader.readSliceAll(self.payload[0..self.command.payload_len]) catch |err| {
                        log.warn("failed to read client payload: {}", .{err});
                        client_error = err;
                        continue :state .mailbox_encountered_read_error;
                    };
                    continue :state .mailbox_needs_to_send_a_notification;
                },
            }
        },

        .mailbox_needs_to_send_a_notification => {
            log.debug("state=MAILBOX_SEND_NOTIFICATION", .{});
            self.bell.store(true, .release);
            log.info("bell triggered due to client command", .{});
            continue :state .mailbox_needs_to_peek_client_command;
        },

        .mailbox_encountered_read_error => {
            log.warn("failed to read from client: {}", .{client_error});
            continue :state .mailbox_needs_to_disconnect_client;
        },

        .mailbox_needs_to_disconnect_client => {
            const had_client = self.client != null;
            log.info("disconnecting client (had_client={})", .{had_client});
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;
            if (self.client) |*c| c.stream.close();
            self.client = null;
            continue :state .mailbox_wait_for_client_to_connect;
        },

        .mailbox_encountered_fatal_error => {
            log.err("fatal error in mailbox: {}", .{fatal_error});
            continue :state .mailbox_needs_to_shutdown;
        },

        .mailbox_needs_to_shutdown => {
            log.info("state=MAILBOX_SHUTDOWN stop={} srv_null={} cli_null={}", .{
                self.stopping.load(.acquire), self.server == null, self.client == null,
            });
            if (self.client) |*c| {
                log.info("closing client fd={d}", .{c.stream.handle});
                c.stream.close();
                self.client = null;
            }
            if (self.server) |*s| {
                log.info("closing server fd={d}", .{s.stream.handle});
                s.stream.close();
                self.server = null;
            }

            if (self.stopping.load(.acquire)) {
                log.info("mailbox stopping permanently", .{});
                return;
            } else {
                log.info("mailbox restarting loop", .{});
                continue :state .mailbox_is_not_ready;
            }
        },
    }
}

const State = enum {
    mailbox_encountered_fatal_error,
    mailbox_encountered_read_error,
    mailbox_has_accepted_a_client,
    mailbox_is_not_ready,
    mailbox_needs_to_decode_client_command,
    mailbox_needs_to_disconnect_client,
    mailbox_needs_to_peek_client_command,
    mailbox_needs_to_send_a_notification,
    mailbox_needs_to_shutdown,
    mailbox_wait_for_client_to_connect,
};
