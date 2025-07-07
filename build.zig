//! Use `zig init --strip` next time to generate a project without comments.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build Ghost Kernel (Pure Zig)
    const ghost_build = b.addSystemCommand(&.{ "zig", "build" });
    ghost_build.setCwd(b.path("linux-ghost"));

    const ghost_step = b.step("ghost", "Build Ghost Kernel (Pure Zig)");
    ghost_step.dependOn(&ghost_build.step);

    // Run Ghost Kernel in QEMU
    const ghost_run = b.addSystemCommand(&.{ "zig", "build", "run" });
    ghost_run.setCwd(b.path("linux-ghost"));
    ghost_run.step.dependOn(&ghost_build.step);

    const run_step = b.step("run", "Run Ghost Kernel in QEMU");
    run_step.dependOn(&ghost_run.step);

    // Test Ghost Kernel
    const ghost_test = b.addSystemCommand(&.{ "zig", "build", "test", "--enable-tests" });
    ghost_test.setCwd(b.path("linux-ghost"));

    const test_step = b.step("test", "Run Ghost Kernel tests");
    test_step.dependOn(&ghost_test.step);

    // Ghost kernel management tools
    const mod = b.addModule("linux_ghost", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Ghost kernel info utility
    const ghost_info = b.addExecutable(.{
        .name = "ghost-info",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghost_info.root_module.addImport("linux_ghost", mod);
    b.installArtifact(ghost_info);

    // Ghost kernel builder CLI
    const gbuild = b.addExecutable(.{
        .name = "gbuild",
        .root_source_file = b.path("src/gbuild.zig"),
        .target = target,
        .optimize = optimize,
    });
    gbuild.root_module.addImport("linux_ghost", mod);
    b.installArtifact(gbuild);

    // Run utilities
    const run_info = b.addRunArtifact(ghost_info);
    const run_gbuild = b.addRunArtifact(gbuild);
    
    if (b.args) |args| {
        run_info.addArgs(args);
        run_gbuild.addArgs(args);
    }

    const info_step = b.step("info", "Show Ghost Kernel info");
    info_step.dependOn(&run_info.step);
    
    const gbuild_step = b.step("gbuild", "Run gbuild utility");
    gbuild_step.dependOn(&run_gbuild.step);

    // Default build target
    b.default_step.dependOn(&ghost_build.step);
}
