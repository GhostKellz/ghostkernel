const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Ghost Kernel build options
    const enable_debug = b.option(bool, "debug", "Enable debug features") orelse false;
    const enable_tests = b.option(bool, "tests", "Enable kernel tests") orelse false;
    const cpu_arch = b.option([]const u8, "cpu", "Target CPU architecture") orelse "znver4";

    // Kernel target configuration (freestanding x86_64)
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Ghost Kernel (Pure Zig Linux 6.15.5 port)
    const kernel = b.addExecutable(.{
        .name = "linux-ghost",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Kernel-specific build configuration
    kernel.setLinkerScript(b.path("src/arch/x86_64/kernel.ld"));
    kernel.pie = false;
    kernel.force_pic = false;
    kernel.red_zone = false;
    kernel.omit_frame_pointer = false;
    kernel.stack_protector = false;

    // Kernel defines
    kernel.defineCMacro("__KERNEL__", "1");
    kernel.defineCMacro("LINUX_VERSION_CODE", "0x060f05"); // 6.15.5
    kernel.defineCMacro("KBUILD_MODNAME", "\"ghost\"");
    
    if (enable_debug) {
        kernel.defineCMacro("DEBUG", "1");
        kernel.defineCMacro("CONFIG_DEBUG_KERNEL", "1");
    }

    // CPU-specific optimizations
    const cpu_flags = getCpuFlags(cpu_arch);
    for (cpu_flags) |flag| {
        kernel.addCSourceFile(.{
            .file = b.path("dummy.c"), // Placeholder for C flags
            .flags = &[_][]const u8{flag},
        });
    }

    b.installArtifact(kernel);

    // QEMU testing
    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-kernel", "zig-out/bin/linux-ghost",
        "-m", "1G",
        "-smp", "4",
        "-serial", "stdio",
        "-display", "none",
        "-no-reboot",
        "-d", "int",
    };

    const run_qemu = b.addSystemCommand(&qemu_args);
    run_qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run Ghost Kernel in QEMU");
    run_step.dependOn(&run_qemu.step);

    // Kernel tests
    if (enable_tests) {
        const kernel_tests = b.addTest(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const test_step = b.step("test", "Run kernel tests");
        test_step.dependOn(&kernel_tests.step);
    }

    // Generate kernel headers (for future driver development)
    const gen_headers = b.addExecutable(.{
        .name = "gen-headers",
        .root_source_file = b.path("tools/gen_headers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_gen_headers = b.addRunArtifact(gen_headers);
    const headers_step = b.step("headers", "Generate kernel headers");
    headers_step.dependOn(&run_gen_headers.step);

    // Documentation generation
    const docs = b.addInstallDirectory(.{
        .source_dir = b.path("src"),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);
}

fn getCpuFlags(cpu_arch: []const u8) []const []const u8 {
    if (std.mem.eql(u8, cpu_arch, "znver4")) {
        return &[_][]const u8{
            "-march=znver4",
            "-mtune=znver4", 
            "-msse4.2",
            "-mavx",
            "-mavx2",
            "-mavx512f",
            "-mavx512dq",
            "-mavx512cd",
            "-mavx512bw",
            "-mavx512vl",
            "-mavx512vnni",
            "-mavx512bf16",
            "-mfma",
            "-mbmi2",
            "-madx",
            "-mrdrnd",
            "-mrdseed",
        };
    } else if (std.mem.eql(u8, cpu_arch, "alderlake")) {
        return &[_][]const u8{
            "-march=alderlake",
            "-mtune=alderlake",
            "-mavx2",
            "-mavx512f",
            "-mavx512dq",
            "-mavx512cd",
            "-mavx512bw",
            "-mavx512vl",
            "-mfma",
            "-mbmi2",
            "-mclflushopt",
            "-mfsgsbase",
            "-mrdrnd",
            "-mrdseed",
            "-mprfchw",
            "-madx",
        };
    } else if (std.mem.eql(u8, cpu_arch, "raptorlake")) {
        return &[_][]const u8{
            "-march=raptorlake",
            "-mtune=raptorlake",
            "-mavx2",
            "-mavx512f",
            "-mavx512dq",
            "-mavx512cd",
            "-mavx512bw",
            "-mavx512vl",
            "-mavx512vnni",
            "-mavx512bf16",
            "-mfma",
            "-mbmi2",
            "-mclflushopt",
            "-mfsgsbase",
            "-mrdrnd",
            "-mrdseed",
            "-mprfchw",
            "-madx",
            "-mgfni",
            "-mvaes",
            "-mvpclmulqdq",
        };
    } else {
        return &[_][]const u8{"-march=x86-64"};
    }
}