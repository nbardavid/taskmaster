const std = @import("std");
const common = @import("common");
const anyline = @import("anyline");
const Logger = common.Logger;
const Config = common.Config;
const Job = common.Job;
const Io = std.Io;
const mem = std.mem;

const Shell = @This();

gpa: mem.Allocator,
writer: *Io.Writer,
