const std = @import("std");

pub const config = @import("config.zig");
pub const ConfigParser = config.ConfigParser;
pub const ProgramConfig = config.ProgramConfig;
pub const Config = config.Config;
pub const config_observer = @import("config_observer.zig");
pub const ConfigDiff = config_observer.ConfigDiff;
pub const ProgramChange = config_observer.ProgramChange;
pub const ProgramFieldChanges = config_observer.ProgramFieldChanges;
pub const Process = @import("process/Process.zig").Process;
pub const ProcessGroup = @import("process/ProcessGroup.zig").ProcessGroup;
pub const utils = @import("process/utils.zig");
pub const Server = @import("Server.zig");
pub const Logger = @import("supervisor/Logger.zig");
pub const ProcessGroupManager = @import("supervisor/ProcessGroupManager.zig");

comptime {
    std.testing.refAllDecls(Process);
    std.testing.refAllDecls(ProcessGroup);
    std.testing.refAllDecls(utils);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(config_observer);
    std.testing.refAllDecls(Logger);
    std.testing.refAllDecls(ProcessGroupManager);
    std.testing.refAllDecls(Server);
}
