const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const fixture_specs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "feature_stdout", .path = "src/fixtures/feature_stdout.zig" },
        .{ .name = "feature_stderr", .path = "src/fixtures/feature_stderr.zig" },
        .{ .name = "feature_env", .path = "src/fixtures/feature_env.zig" },
        .{ .name = "feature_workdir", .path = "src/fixtures/feature_workdir.zig" },
        .{ .name = "feature_umask", .path = "src/fixtures/feature_umask.zig" },
        .{ .name = "feature_startsecs", .path = "src/fixtures/feature_startsecs.zig" },
        .{ .name = "feature_exitcode", .path = "src/fixtures/feature_exitcode.zig" },
        .{ .name = "feature_autorestart", .path = "src/fixtures/feature_autorestart.zig" },
        .{ .name = "feature_stopsignal", .path = "src/fixtures/feature_stopsignal.zig" },
        .{ .name = "feature_stoptime", .path = "src/fixtures/feature_stoptime.zig" },
        .{ .name = "feature_numprocs", .path = "src/fixtures/feature_numprocs.zig" },
    };

    const mod = b.addModule("zproc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zproc", .module = mod },
            },
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&run_mod_tests.step);
    check_step.dependOn(&exe.step);

    for (fixture_specs) |spec| {
        const fixture_exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec.path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        b.installArtifact(fixture_exe);

        const step = b.step(spec.name, "Build fixture program");
        step.dependOn(&fixture_exe.step);
    }
}
