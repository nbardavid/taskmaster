const std = @import("std");

pub const Command = packed struct(u16) {
    cmd: enum(u8) {
        status,
        start,
        restart,
        stop,
        reload,
        quit,
        dump,
    },
    payload_len: u8,
};
