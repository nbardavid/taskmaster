const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const anyline_dep = b.dependency("anyline", .{
        .target = target,
        .optimize = optimize,
    });
    const anyline = anyline_dep.module("anyline");

    const common = b.addLibrary(.{
        .name = "taskmaster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "anyline", .module = anyline },
            },
        }),
    });
    b.installArtifact(common);

    const server = b.addExecutable(.{
        .name = "taskmaster-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "anyline", .module = anyline },
                .{ .name = "common", .module = common.root_module },
            },
        }),
    });
    b.installArtifact(server);

    const run_server_cmd = b.addRunArtifact(server);

    run_server_cmd.step.dependOn(b.getInstallStep());

    run_server_cmd.addFileArg(b.path("config.json"));
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const run_server_step = b.step("run_server", "Run the app");
    run_server_step.dependOn(&run_server_cmd.step);

    const server_unit_test = b.addTest(.{
        .root_module = server.root_module,
    });

    const run_server_unit_test = b.addRunArtifact(server_unit_test);

    const test_server_step = b.step("test_server", "Run unit tests");
    test_server_step.dependOn(&run_server_unit_test.step);

    const client = b.addExecutable(.{
        .name = "taskmaster-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "anyline", .module = anyline },
                .{ .name = "common", .module = common.root_module },
            },
        }),
    });
    b.installArtifact(client);

    const run_client_cmd = b.addRunArtifact(client);

    run_client_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const run_client_step = b.step("run_client", "Run the app");
    run_client_step.dependOn(&run_client_cmd.step);

    const client_unit_test = b.addTest(.{
        .root_module = client.root_module,
    });

    const run_client_unit_test = b.addRunArtifact(client_unit_test);

    const test_client_step = b.step("test_client", "Run unit tests");
    test_client_step.dependOn(&run_client_unit_test.step);

    const check_step = b.step("check", "zls helper");
    check_step.dependOn(&server.step);
    check_step.dependOn(&client.step);

    // Test programs for evaluation
    const test_programs = [_][]const u8{
        "simple_success",
        "simple_failure",
        "long_runner",
        "crash_immediately",
        "startup_slow",
        "code_selector",
        "env_printer",
        "workdir_printer",
        "stdout_spammer",
        "signal_catcher",
    };

    const test_programs_step = b.step("test-programs", "Build all test programs");

    inline for (test_programs) |prog_name| {
        const prog = b.addExecutable(.{
            .name = prog_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/programs/" ++ prog_name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(prog);
        test_programs_step.dependOn(&prog.step);
    }
}
