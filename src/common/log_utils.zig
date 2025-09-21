const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;

const timezone_shift = 2; // -05:00
pub const TimeParts = packed struct {
    year: u12,
    month: u4, // 16
    day: u5,
    hour: u5,
    minute: u6, // 32
    second: u6,
    millisecond: u10, // 48

    /// Not applicable to time previous to epoch.
    ///
    /// Ported from: https://stackoverflow.com/a/11197532/12185226
    pub fn fromMsTimestamp(timestamp: u64) @This() {
        const ms = timestamp % 1000;

        // Re-bias from 1970 to 1601:
        // 1970 - 1601 = 369 = 3*100 + 17*4 + 1 years (incl. 89 leap days) =
        // (3*100*(365+24/100) + 17*4*(365+1/4) + 1*365)*24*3600 seconds
        var sec: u64 = (timestamp / 1000) + 11644473600;

        // Remove multiples of 400 years (incl. 97 leap days)
        const quadricentennials: u64 = sec / 12622780800; // 400*365.2425*24*3600
        sec %= 12622780800;

        // Remove multiples of 100 years (incl. 24 leap days), can't be more than 3
        // (because multiples of 4*100=400 years (incl. leap days) have been removed)
        const centennials: u64 = @min(3, sec / 3155673600); // 100*(365+24/100)*24*3600
        sec -= centennials * 3155673600;

        // Remove multiples of 4 years (incl. 1 leap day), can't be more than 24
        // (because multiples of 25*4=100 years (incl. leap days) have been removed)
        const quadrennials: u64 = @min(24, sec / 126230400); // 4*(365+1/4)*24*3600
        sec -= quadrennials * 126230400;

        // Remove multiples of years (incl. 0 leap days), can't be more than 3
        // (because multiples of 4 years (incl. leap days) have been removed)
        const annuals: u64 = @min(3, sec / 31536000); // 365*24*3600
        sec -= annuals * 31536000;

        const year = 1601 + quadricentennials * 400 + centennials * 100 + quadrennials * 4 + annuals;
        const leap = (year % 4 == 0) and (year % 100 != 0 or (year % 400 == 0));

        const yday = sec / 86400;
        sec %= 86400;

        const hour = sec / 3600;
        sec %= 3600;

        const minute = sec / 60;
        sec %= 60;

        const mday_list: [12]u9 = if (leap)
            .{ 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 }
        else
            .{ 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 };
        const month = for (mday_list, 0..) |x, i| {
            if (yday < x) break i;
        } else unreachable;
        const mday = if (month == 0) yday else yday - mday_list[month - 1];

        return .{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(mday),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(sec),
            .millisecond = @intCast(ms),
        };
    }

    pub fn format(self: @This(), writer: *Io.Writer) !void {
        var tz_buffer: [7]u8 = undefined;
        var tz: []const u8 = "Z";
        if (timezone_shift != 0) {
            tz = std.fmt.bufPrint(
                &tz_buffer,
                "{c}{:0>2}:00",
                .{ if (timezone_shift > 0) '+' else '-', @abs(timezone_shift) },
            ) catch unreachable;
        }

        var buffer: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(
            &buffer,
            "{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}.{:0>3} {s}",
            .{
                self.year,
                self.month + 1,
                self.day + 1,
                self.hour,
                self.minute,
                self.second,
                self.millisecond,
                tz,
            },
        ) catch unreachable;
        try writer.writeAll(slice);
    }
};
