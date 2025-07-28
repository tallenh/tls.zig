const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tls_module = b.addModule("tls", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const examples = [_][]const u8{
        "http_get",
        "http_get_std",
        "client",
        "server",
        "top_sites",
        "badssl",
        "std_top_sites",
        "all_ciphers",
        "client_auth",
        "client_std",
        "fuzz_server",
        "http_get_nonblock",
        "arena_usage",
        "buffer_pool_demo",
        "buffer_pool_tls_demo",
        "signal_pipe_demo",
        "kqueue_signal_demo",
        "zero_copy_demo",
        "hot_path_benchmark",
    };
    inline for (examples) |path| {
        const source_file = "example/" ++ path ++ ".zig";
        const name = comptime if (std.mem.indexOfScalar(u8, path, '/')) |pos| path[0..pos] else path;
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(source_file),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("tls", tls_module);
        setupExample(b, exe, name);
    }

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("example/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("tls", tls_module);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}

// Copied from: https://github.com/karlseguin/mqttz/blob/master/build.zig
fn setupExample(b: *std.Build, exe: *std.Build.Step.Compile, comptime name: []const u8) void {
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("example_" ++ name, "Run the " ++ name ++ " example");
    run_step.dependOn(&run_cmd.step);
}
