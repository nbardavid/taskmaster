pub const packages = struct {
    pub const @"linenoize-0.1.0-J7HK8IfXAABxH-V4Bp2Q0G7P-nrOmq9g8LuQAoX3SjDy" = struct {
        pub const build_root = "/home/nbardavi/.cache/zig/p/linenoize-0.1.0-J7HK8IfXAABxH-V4Bp2Q0G7P-nrOmq9g8LuQAoX3SjDy";
        pub const build_zig = @import("linenoize-0.1.0-J7HK8IfXAABxH-V4Bp2Q0G7P-nrOmq9g8LuQAoX3SjDy");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "wcwidth", "wcwidth-0.1.0-A4Aa6obmAAC40epfTYwhsdITDO3M6dHEWf6C0jeGMWrV" },
        };
    };
    pub const @"wcwidth-0.1.0-A4Aa6obmAAC40epfTYwhsdITDO3M6dHEWf6C0jeGMWrV" = struct {
        pub const build_root = "/home/nbardavi/.cache/zig/p/wcwidth-0.1.0-A4Aa6obmAAC40epfTYwhsdITDO3M6dHEWf6C0jeGMWrV";
        pub const build_zig = @import("wcwidth-0.1.0-A4Aa6obmAAC40epfTYwhsdITDO3M6dHEWf6C0jeGMWrV");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zig_yaml-0.1.0-C1161miEAgBCwL3YAEQZwV_4GyaaT2Xqj9nKB6hNe_TL" = struct {
        pub const build_root = "/home/nbardavi/.cache/zig/p/zig_yaml-0.1.0-C1161miEAgBCwL3YAEQZwV_4GyaaT2Xqj9nKB6hNe_TL";
        pub const build_zig = @import("zig_yaml-0.1.0-C1161miEAgBCwL3YAEQZwV_4GyaaT2Xqj9nKB6hNe_TL");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "linenoize", "linenoize-0.1.0-J7HK8IfXAABxH-V4Bp2Q0G7P-nrOmq9g8LuQAoX3SjDy" },
    .{ "yaml", "zig_yaml-0.1.0-C1161miEAgBCwL3YAEQZwV_4GyaaT2Xqj9nKB6hNe_TL" },
};
