pub const Signal = enum(i32) {
    block,
    unblock,
    setmask,
    hup,
    int,
    quit,
    ill,
    trap,
    abrt,
    poll,
    iot,
    emt,
    fpe,
    kill,
    bus,
    segv,
    sys,
    pipe,
    alrm,
    term,
    urg,
    stop,
    tstp,
    cont,
    chld,
    ttin,
    ttou,
    io,
    xcpu,
    xfsz,
    vtalrm,
    prof,
    winch,
    info,
    usr1,
    usr2,

    pub fn signalFromString(string: []const u8) ?Signal {
        return signal_from_string.get(string);
    }

    pub fn stringFromSignal(signal: Signal) []const u8 {
        return switch (signal) {
            .block => return "BLOCK",
            .unblock => return "UNBLOCK",
            .setmask => return "SETMASK",
            .hup => return "HUP",
            .int => return "INT",
            .quit => return "QUIT",
            .ill => return "ILL",
            .trap => return "TRAP",
            .abrt => return "ABRT",
            .poll => return "POLL",
            .iot => return "IOT",
            .emt => return "EMT",
            .fpe => return "FPE",
            .kill => return "KILL",
            .bus => return "BUS",
            .segv => return "SEGV",
            .sys => return "SYS",
            .pipe => return "PIPE",
            .alrm => return "ALRM",
            .term => return "TERM",
            .urg => return "URG",
            .stop => return "STOP",
            .tstp => return "TSTP",
            .cont => return "CONT",
            .chld => return "CHLD",
            .ttin => return "TTIN",
            .ttou => return "TTOU",
            .io => return "IO",
            .xcpu => return "XCPU",
            .xfsz => return "XFSZ",
            .vtalrm => return "VTALRM",
            .prof => return "PROF",
            .winch => return "WINCH",
            .info => return "INFO",
            .usr1 => return "USR1",
            .usr2 => return "USR2",
        };
    }

    const signal_from_string: std.StaticEnumMap(Signal) = .initComptime(&.{
        .{ "HUP", Signal.hup },
        .{ "INT", Signal.int },
        .{ "TRAP", Signal.trap },
        .{ "ABRT", Signal.abrt },
        .{ "IOT", Signal.abrt },
        .{ "EMT", Signal.poll },
        .{ "POLL", Signal.poll },
        .{ "FPE", Signal.fpe },
        .{ "KILL", Signal.kill },
        .{ "BUS", Signal.bus },
        .{ "SEGV", Signal.segv },
        .{ "SYS", Signal.sys },
        .{ "PIPE", Signal.pipe },
        .{ "ALRM", Signal.alrm },
        .{ "TERM", Signal.term },
        .{ "URG", Signal.urg },
        .{ "STOP", Signal.stop },
        .{ "TSTP", Signal.tstp },
        .{ "CONT", Signal.cont },
        .{ "CHLD", Signal.chld },
        .{ "TTIN", Signal.ttin },
        .{ "TTOU", Signal.ttou },
        .{ "IO", Signal.io },
        .{ "XCPU", Signal.xcpu },
        .{ "XFSZ", Signal.xfsz },
        .{ "VTALRM", Signal.vtalrm },
        .{ "PROF", Signal.prof },
        .{ "WINCH", Signal.winch },
        .{ "INFO", Signal.info },
        .{ "USR1", Signal.usr1 },
        .{ "USR2", Signal.usr2 },
    });

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.stringFromSignal()});
    }
};

pub const ExitCode = enum(i32) {
    _,

    pub fn exitCodeFromInt(number: anytype) ExitCode {
        return @enumFromInt(@as(i32, @intCast(number)));
    }

    pub fn intFromExitCode(code: ExitCode) i32 {
        return @as(i32, @intFromEnum(code));
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("exit code : {d}", .{self.intFromExitCode()});
    }
};

const std = @import("std");
