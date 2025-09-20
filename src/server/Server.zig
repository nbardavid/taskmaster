const Server = @This();

gpa: mem.Allocator,
address: net.Address,
config: ?Config,
sock_path: []const u8,

pub fn init(gpa: mem.Allocator, sock_path: []const u8) Server {
    return .{
        .gpa = gpa,
        .address = undefined,
        .config = null,
        .sock_path = sock_path,
    };
}


const State = enum {
    server_client_disconnected,
    server_client_connected,
    server_encountered_fatal_error,
    server_can_exit_cleanly,
    server_wait_for_command,
};

pub fn start(self: *Server) !void {
    var server = try self.listenUnixSocket(self.sock_path, 1);
    defer server.close();

    var client_connection: net.Server.Connection = undefined;
    var fatal_error: anyerror = undefined;

    state: switch (State.server_client_disconnected) {
        .server_client_disconnected => {
            if (server.accept()) |connection| {
                client_connection = connection;
                continue :state .server_wait_for_command;
            } else |err| {
                fatal_error = err;
                continue :state .server_encountered_fatal_error;
            }
        },
        .server_encountered_fatal_error => {
            log.err("Encountered fatal error {}.", .{fatal_error});
            return;
        },
    }
}

pub fn deinit(self: *Server) void {
    if (self.config) |*config| {
        config.deinit();
    }
}

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const proc = std.process;
const fs = std.fs;
const Io = std.Io;
const net = std.net;
const log = std.log;
const posix = std.posix;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;
const Command = common.Command;
