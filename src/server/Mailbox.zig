const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const Io = std.Io;
const posix = std.posix;
const fs = std.fs;
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
logger: *Logger,

client_mutex: Thread.Mutex = .{},
response_pending: std.atomic.Value(bool) = .{ .raw = false },
response: common.Response = undefined,
response_payload: []u8 = undefined,
response_payload_owned: bool = false,
gpa: mem.Allocator,

pub fn init(unix_socket_path: []const u8, bell: *std.atomic.Value(bool), logger: *Logger, gpa: mem.Allocator) Mailbox {
    return .{
        .unix_socket_path = unix_socket_path,
        .bell = bell,
        .logger = logger,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Mailbox) void {
    self.stopping.store(true, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    if (self.response_payload_owned and self.response_payload.len > 0) {
        self.gpa.free(self.response_payload);
    }

    // Clean up socket file on shutdown
    fs.cwd().deleteFile(self.unix_socket_path) catch |err| {
        self.logger.warn("failed to delete socket file during cleanup: {}", .{err});
    };
}

pub fn start(self: *Mailbox) !void {
    self.thread = try Thread.spawn(.{}, Mailbox.mainLoop, .{self});
}

pub fn sendResponse(self: *Mailbox, response: common.Response, payload: []const u8) void {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();

    if (self.response_payload_owned and self.response_payload.len > 0) {
        self.gpa.free(self.response_payload);
        self.response_payload_owned = false;
    }

    if (payload.len > 0) {
        const payload_copy = self.gpa.alloc(u8, payload.len) catch {
            self.logger.err("failed to allocate response payload buffer", .{});
            return;
        };
        @memcpy(payload_copy, payload);
        self.response_payload = payload_copy;
        self.response_payload_owned = true;
    } else {
        self.response_payload = &[_]u8{};
        self.response_payload_owned = false;
    }

    self.response = response;
    self.response_pending.store(true, .release);
    self.logger.debug("response queued: status={s} len={d}", .{ @tagName(response.status), response.payload_len });
}

fn mainLoop(self: *Mailbox) !void {
    const logger = self.logger;
    var fatal_error: anyerror = undefined;
    var client_error: anyerror = undefined;
    var client_buffer: [512]u8 = undefined;
    var client_reader: net.Stream.Reader = undefined;
    var reader: *std.Io.Reader = undefined;

    logger.info("MAILBOX thread start: self_ptr=0x{x}", .{@intFromPtr(self)});

    state: switch (State.mailbox_is_not_ready) {
        .mailbox_is_not_ready => {
            logger.info("state=MAILBOX_NOT_OPEN stop={} srv_null={}", .{
                self.stopping.load(.acquire), self.server == null,
            });
            if (self.stopping.load(.acquire)) {
                logger.warn("transition to SHUTDOWN (stopping=true) from NOT_OPEN", .{});
                continue :state .mailbox_needs_to_shutdown;
            }

            fs.cwd().deleteFile(self.unix_socket_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    logger.err("failed to delete stale socket file: {}", .{err});
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                },
            };

            const sockfd = posix.socket(
                posix.AF.UNIX,
                posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
                0,
            ) catch |err| {
                logger.err("socket creation failed: {}", .{err});
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };
            logger.info("socket created fd={d}", .{sockfd});

            var address = net.Address.initUnix(self.unix_socket_path) catch |err| {
                logger.err("failed to init unix socket address: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            if (posix.bind(sockfd, &address.any, address.getOsSockLen())) |_| {
                logger.info("bound unix socket at {s}", .{self.unix_socket_path});
            } else |err| {
                logger.err("bind failed: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            if (posix.listen(sockfd, 1)) |_| {
                logger.info("listening on mailbox socket (fd={d})", .{sockfd});
            } else |err| {
                logger.err("listen failed: {}", .{err});
                posix.close(sockfd);
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            }

            self.server = net.Server{
                .listen_address = address,
                .stream = .{ .handle = sockfd },
            };
            logger.info("server set: srv_null={} fd={d}", .{ self.server == null, self.server.?.stream.handle });

            continue :state .mailbox_wait_for_client_to_connect;
        },

        .mailbox_wait_for_client_to_connect => {
            const stop = self.stopping.load(.acquire);
            const srv_null = self.server == null;

            if (stop or srv_null) {
                if (stop) logger.warn("WAIT -> SHUTDOWN (stopping=true)", .{});
                if (srv_null) logger.warn("WAIT -> SHUTDOWN (server=null)", .{});
                continue :state .mailbox_needs_to_shutdown;
            }

            const fd = self.server.?.stream.handle;
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};

            const rc = posix.poll(&fds, 200) catch |err| {
                logger.err("poll on server socket failed: {}", .{err});
                fatal_error = err;
                continue :state .mailbox_encountered_fatal_error;
            };

            if (rc == 0) {
                continue :state .mailbox_wait_for_client_to_connect;
            }

            if ((fds[0].revents & posix.POLL.IN) != 0) {
                if (self.server.?.accept()) |connection| {
                    logger.info("accepted new client: fd={d}", .{connection.stream.handle});

                    _ = posix.fcntl(connection.stream.handle, posix.F.SETFL, posix.SOCK.NONBLOCK) catch |err| {
                        logger.err("failed to set client socket nonblocking: {}", .{err});
                        fatal_error = err;
                        continue :state .mailbox_encountered_fatal_error;
                    };
                    self.client = connection;
                    continue :state .mailbox_has_accepted_a_client;
                } else |err| {
                    logger.err("accept failed: {}", .{err});
                    fatal_error = err;
                    continue :state .mailbox_encountered_fatal_error;
                }
            }

            logger.warn("server revents=0x{x} -> restart listener", .{fds[0].revents});
            continue :state .mailbox_needs_to_shutdown;
        },

        .mailbox_has_accepted_a_client => {
            logger.info("state=MAILBOX_ACCEPTED_NEW_CLIENT stop={} cli_null={}", .{
                self.stopping.load(.acquire), self.client == null,
            });
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;
            client_reader = self.client.?.stream.reader(&client_buffer);
            reader = client_reader.interface();
            continue :state .mailbox_needs_to_peek_client_command;
        },

        .mailbox_needs_to_peek_client_command => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            var fds = [_]posix.pollfd{
                .{ .fd = self.client.?.stream.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const rc = posix.poll(&fds, 200) catch |err| {
                logger.err("poll on client socket failed: {}", .{err});
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };

            if (rc == 0) continue :state .mailbox_needs_to_peek_client_command;

            const revents = fds[0].revents;
            if ((revents & posix.POLL.IN) != 0) {
                if (reader.peekStruct(common.Command, builtin.cpu.arch.endian())) |command| {
                    logger.info("peeked client command: {any}", .{command.cmd});
                    self.command = command;
                    continue :state .mailbox_needs_to_decode_client_command;
                } else |err| switch (err) {
                    error.EndOfStream => {
                        logger.info("client EOF; disconnecting", .{});
                        continue :state .mailbox_needs_to_disconnect_client;
                    },
                    else => {
                        logger.warn("error peeking client command: {}", .{err});
                        client_error = err;
                        continue :state .mailbox_encountered_read_error;
                    },
                }
            }

            if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                logger.info("client hangup/error (revents=0x{x}); disconnecting", .{revents});
                continue :state .mailbox_needs_to_disconnect_client;
            }

            logger.warn("unexpected client revents=0x{x}; disconnecting", .{revents});
            continue :state .mailbox_needs_to_disconnect_client;
        },

        .mailbox_needs_to_decode_client_command => {
            logger.info("state=MAILBOX_DECODE_CLIENT_COMMAND", .{});
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            _ = reader.discard(.limited(@sizeOf(common.Command))) catch |err| {
                logger.warn("failed to discard command header: {}", .{err});
                client_error = err;
                continue :state .mailbox_encountered_read_error;
            };

            switch (self.command.cmd) {
                .dump, .quit, .reload => {
                    logger.info("client command: {any}", .{self.command.cmd});
                    continue :state .mailbox_needs_to_send_a_notification;
                },
                .status, .start, .restart, .stop => {
                    logger.info("client command: {any} (payload {d} bytes)", .{ self.command.cmd, self.command.payload_len });
                    if (self.command.payload_len > 0) {
                        reader.readSliceAll(self.payload[0..self.command.payload_len]) catch |err| {
                            logger.warn("failed to read client payload: {}", .{err});
                            client_error = err;
                            continue :state .mailbox_encountered_read_error;
                        };
                    }
                    continue :state .mailbox_needs_to_send_a_notification;
                },
            }
        },

        .mailbox_needs_to_send_a_notification => {
            self.bell.store(true, .release);
            logger.info("bell triggered due to client command", .{});
            continue :state .mailbox_check_for_response;
        },

        .mailbox_check_for_response => {
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            if (self.response_pending.load(.acquire)) {
                continue :state .mailbox_send_response;
            } else {
                Thread.sleep(std.time.ns_per_us * 100);
                continue :state .mailbox_check_for_response;
            }
        },

        .mailbox_send_response => {
            logger.info("state=MAILBOX_SEND_RESPONSE", .{});
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;

            self.client_mutex.lock();
            const response = self.response;
            const payload = self.response_payload;
            const owned = self.response_payload_owned;
            self.response_pending.store(false, .monotonic);
            self.client_mutex.unlock();

            defer {
                if (owned and payload.len > 0) {
                    self.client_mutex.lock();
                    if (self.response_payload_owned and self.response_payload.ptr == payload.ptr) {
                        self.gpa.free(self.response_payload);
                        self.response_payload_owned = false;
                        self.response_payload = &[_]u8{};
                    }
                    self.client_mutex.unlock();
                }
            }

            if (self.client) |*c| {
                var write_buffer: [4096]u8 = undefined;
                var writer = c.stream.writer(&write_buffer);
                const w = &writer.interface;

                if (w.writeStruct(response, builtin.cpu.arch.endian())) {
                    logger.debug("sent response header: status={s} len={d}", .{ @tagName(response.status), response.payload_len });

                    if (response.payload_len > 0 and payload.len > 0) {
                        const to_write = @min(payload.len, response.payload_len);
                        if (w.writeAll(payload[0..to_write])) {
                            logger.debug("sent response payload: {d} bytes", .{to_write});
                        } else |err| {
                            logger.err("failed to write response payload: {}", .{err});
                            continue :state .mailbox_needs_to_disconnect_client;
                        }
                    }

                    if (w.flush()) {
                        logger.info("response sent successfully", .{});
                        continue :state .mailbox_needs_to_peek_client_command;
                    } else |err| {
                        logger.err("failed to flush response: {}", .{err});
                        continue :state .mailbox_needs_to_disconnect_client;
                    }
                } else |err| {
                    logger.err("failed to write response header: {}", .{err});
                    continue :state .mailbox_needs_to_disconnect_client;
                }
            } else {
                logger.warn("no client connection to send response to", .{});
                continue :state .mailbox_wait_for_client_to_connect;
            }
        },

        .mailbox_encountered_read_error => {
            logger.warn("failed to read from client: {}", .{client_error});
            continue :state .mailbox_needs_to_disconnect_client;
        },

        .mailbox_needs_to_disconnect_client => {
            const had_client = self.client != null;
            logger.info("disconnecting client (had_client={})", .{had_client});
            if (self.stopping.load(.acquire)) continue :state .mailbox_needs_to_shutdown;
            if (self.client) |*c| c.stream.close();
            self.client = null;
            continue :state .mailbox_wait_for_client_to_connect;
        },

        .mailbox_encountered_fatal_error => {
            logger.err("fatal error in mailbox: {}", .{fatal_error});
            continue :state .mailbox_needs_to_shutdown;
        },

        .mailbox_needs_to_shutdown => {
            logger.info("state=MAILBOX_SHUTDOWN stop={} srv_null={} cli_null={}", .{
                self.stopping.load(.acquire), self.server == null, self.client == null,
            });
            if (self.client) |*c| {
                logger.info("closing client fd={d}", .{c.stream.handle});
                c.stream.close();
                self.client = null;
            }
            if (self.server) |*s| {
                logger.info("closing server fd={d}", .{s.stream.handle});
                s.stream.close();
                self.server = null;
            }

            if (self.stopping.load(.acquire)) {
                logger.info("mailbox stopping permanently", .{});
                return;
            } else {
                logger.info("mailbox restarting loop", .{});
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
    mailbox_check_for_response,
    mailbox_send_response,
};
