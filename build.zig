const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const deancord_dependency = b.dependency("deancord", .{});
    const deancord_module = deancord_dependency.module("deancord");

    const exe = b.addExecutable(.{
        .name = "embed-fixer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("deancord", deancord_module);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("deancord", deancord_module);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // zig build
    b.installArtifact(exe);

    // zig build run
    const run_step = b.step("run", "Run embed-fixer. Remember to supply TOKEN environment variable!");
    run_step.dependOn(&run_cmd.step);

    // zig build test
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // zig build check (for LSP)
    const check_step = b.step("check", "Typechecking for LSP");
    check_step.dependOn(&exe.step);
}
