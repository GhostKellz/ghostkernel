const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Ghost Kernel build options
    const enable_debug = b.option(bool, "debug", "Enable debug features") orelse false;
    const enable_tests = b.option(bool, "tests", "Enable kernel tests") orelse false;
    const cpu_arch = b.option([]const u8, "cpu-arch", "Target CPU architecture") orelse "znver4";
    const gpu_support = b.option(bool, "gpu", "Enable GPU driver support") orelse true;
    const nvidia_support = b.option(bool, "nvidia", "Enable NVIDIA GPU support") orelse true;
    const gaming_mode = b.option(bool, "gaming", "Enable gaming optimizations") orelse true;
    const ai_acceleration = b.option(bool, "ai", "Enable AI acceleration") orelse true;

    // Kernel target configuration (freestanding x86_64)
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Ghost Kernel (Pure Zig Linux 6.15.5 port)
    const kernel = b.addExecutable(.{
        .name = "linux-ghost",
        .root_source_file = b.path("src/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    
    // Gaming components are now imported directly by the kernel, not as separate modules
    
    // Device drivers
    const usb_hid = b.addModule("usb_hid", .{
        .root_source_file = b.path("src/drivers/usb/hid.zig"),
    });
    const usb_mass_storage = b.addModule("usb_mass_storage", .{
        .root_source_file = b.path("src/drivers/usb/mass_storage.zig"),
    });
    const block_device = b.addModule("block_device", .{
        .root_source_file = b.path("src/block/block_device.zig"),
    });
    const scsi = b.addModule("scsi", .{
        .root_source_file = b.path("src/scsi/scsi.zig"),
    });
    const input_subsystem = b.addModule("input_subsystem", .{
        .root_source_file = b.path("src/input/input_subsystem.zig"),
    });
    
    // Gaming components are imported directly by the kernel files, not as separate modules
    
    // Add device driver modules
    kernel.root_module.addImport("usb_hid", usb_hid);
    kernel.root_module.addImport("usb_mass_storage", usb_mass_storage);
    kernel.root_module.addImport("block_device", block_device);
    kernel.root_module.addImport("scsi", scsi);
    kernel.root_module.addImport("input_subsystem", input_subsystem);

    // Kernel-specific build configuration
    kernel.setLinkerScript(b.path("src/arch/x86_64/kernel.ld"));
    kernel.pie = false;

    // Kernel defines - using current Zig build system syntax
    const kernel_options = b.addOptions();
    kernel_options.addOption(bool, "KERNEL", true);
    kernel_options.addOption(u32, "LINUX_VERSION_CODE", 0x060f05); // 6.15.5
    kernel_options.addOption([]const u8, "KBUILD_MODNAME", "ghost");
    
    if (enable_debug) {
        kernel_options.addOption(bool, "DEBUG", true);
        kernel_options.addOption(bool, "CONFIG_DEBUG_KERNEL", true);
    }
    
    // GPU support configuration
    if (gpu_support and nvidia_support) {
        // Get GhostNV dependency
        const ghostnv_dep = b.dependency("ghostnv", .{
            .target = target,
            .optimize = optimize,
            .@"driver-mode" = .auto,
            .legacy = false,
            .@"pure-zig" = false,
        });
        
        kernel_options.addOption(bool, "CONFIG_GPU_NVIDIA", true);
        kernel_options.addOption(bool, "CONFIG_GHOSTNV", true);
        kernel_options.addOption(bool, "CONFIG_GHOSTNV_VIBRANCE", true);
        kernel_options.addOption(bool, "CONFIG_GHOSTNV_CUDA", true);
        kernel_options.addOption(bool, "CONFIG_GHOSTNV_NVENC", true);
        kernel_options.addOption(bool, "CONFIG_GHOSTNV_VRR", true);
        
        if (gaming_mode) {
            kernel_options.addOption(bool, "CONFIG_GPU_GAMING", true);
            kernel_options.addOption(bool, "CONFIG_GHOSTNV_GAMING", true);
            kernel_options.addOption(bool, "CONFIG_GHOSTNV_LOW_LATENCY", true);
            kernel_options.addOption(bool, "CONFIG_GHOSTNV_GSYNC", true);
            kernel_options.addOption(bool, "CONFIG_GAMING_OPTIMIZATIONS", true);
            kernel_options.addOption(bool, "CONFIG_DIRECT_STORAGE", true);
            kernel_options.addOption(bool, "CONFIG_NUMA_CACHE_AWARE", true);
            kernel_options.addOption(bool, "CONFIG_GAMING_SYSCALLS", true);
            kernel_options.addOption(bool, "CONFIG_HW_TIMESTAMP_SCHED", true);
            kernel_options.addOption(bool, "CONFIG_REALTIME_COMPACTION", true);
            kernel_options.addOption(bool, "CONFIG_GAMING_FUTEX", true);
            kernel_options.addOption(bool, "CONFIG_GAMING_PRIORITY", true);
        }
        
        if (ai_acceleration) {
            kernel_options.addOption(bool, "CONFIG_GPU_AI", true);
            kernel_options.addOption(bool, "CONFIG_GHOSTNV_TENSOR", true);
            kernel_options.addOption(bool, "CONFIG_GHOSTNV_RTX_VOICE", true);
        }
        
        // Add GhostNV module to kernel
        kernel.root_module.addImport("ghostnv", ghostnv_dep.module("ghostnv"));
        
        // Add GhostVibrance tool (from your repo)
        const ghostvibrance = b.addExecutable(.{
            .name = "ghostvibrance",
            .root_source_file = ghostnv_dep.path("zig-nvidia/tools/ghostvibrance.zig"),
            .target = target,
            .optimize = optimize,
        });
        ghostvibrance.root_module.addImport("ghostnv", ghostnv_dep.module("ghostnv"));
        
        b.installArtifact(ghostvibrance);
        
        // Add GPU test suite
        const gpu_tests = b.addExecutable(.{
            .name = "gpu-test",
            .root_source_file = b.path("src/test/gpu_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        
        // Add nvidia module to gpu tests
        const nvidia_module = b.addModule("nvidia", .{
            .root_source_file = b.path("src/drivers/gpu/nvidia/main.zig"),
        });
        
        // Add required dependencies to nvidia module
        const pci_module = b.addModule("pci", .{
            .root_source_file = b.path("src/drivers/pci.zig"),
        });
        const mm_module = b.addModule("mm", .{
            .root_source_file = b.path("src/mm/mm_wrapper.zig"),
        });
        const interrupts_module = b.addModule("interrupts", .{
            .root_source_file = b.path("src/arch/x86_64/interrupts.zig"),
        });
        const kernel_module = b.addModule("kernel", .{
            .root_source_file = b.path("src/kernel/kernel.zig"),
        });
        interrupts_module.addImport("kernel", kernel_module);
        
        nvidia_module.addImport("pci", pci_module);
        nvidia_module.addImport("mm", mm_module);
        nvidia_module.addImport("interrupts", interrupts_module);
        gpu_tests.root_module.addImport("nvidia", nvidia_module);
        gpu_tests.root_module.addImport("ghostnv", ghostnv_dep.module("ghostnv"));
        
        b.installArtifact(gpu_tests);
        
        // Add NVENC test tool (from your repo)
        const nvenc_test = b.addExecutable(.{
            .name = "nvenc-test",
            .root_source_file = ghostnv_dep.path("zig-nvidia/tools/test-nvenc.zig"),
            .target = target,
            .optimize = optimize,
        });
        nvenc_test.root_module.addImport("ghostnv", ghostnv_dep.module("ghostnv"));
        
        b.installArtifact(nvenc_test);
    }

    // Add options to kernel
    kernel.root_module.addOptions("config", kernel_options);

    // CPU-specific optimizations
    const cpu_flags = getCpuFlags(cpu_arch);
    for (cpu_flags) |flag| {
        kernel.root_module.addCMacro(flag, "");
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
        
        // Gaming components are imported directly by the kernel files, not as separate modules

        const test_step = b.step("test", "Run kernel tests");
        test_step.dependOn(&kernel_tests.step);
        
        // Gaming-specific tests
        const gaming_tests = b.addTest(.{
            .root_source_file = b.path("src/test/gaming_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        
        const gaming_test_step = b.step("test-gaming", "Run gaming optimization tests");
        gaming_test_step.dependOn(&gaming_tests.step);
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

    // GhostNV tools build steps
    if (gpu_support and nvidia_support) {
        const ghostvibrance_step = b.step("ghostvibrance", "Build GhostVibrance digital vibrance tool");
        ghostvibrance_step.dependOn(b.getInstallStep());
        
        const gpu_test_step = b.step("gpu-test", "Build GPU test suite");
        gpu_test_step.dependOn(b.getInstallStep());
        
        const nvenc_test_step = b.step("nvenc-test", "Build NVENC test tool");
        nvenc_test_step.dependOn(b.getInstallStep());
        
        const ghostnv_all_step = b.step("ghostnv-all", "Build all GhostNV tools");
        ghostnv_all_step.dependOn(ghostvibrance_step);
        ghostnv_all_step.dependOn(gpu_test_step);
        ghostnv_all_step.dependOn(nvenc_test_step);
    }
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