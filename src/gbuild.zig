const std = @import("std");
const linux_ghost = @import("linux_ghost");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.debug.print("Ghost Kernel Builder (gbuild)\n");
    std.debug.print("=============================\n");
    
    if (args.len < 2) {
        try printUsage();
        return;
    }

    const variant = args[1];
    
    if (std.mem.eql(u8, variant, "experimental")) {
        try buildExperimentalKernel();
    } else if (std.mem.eql(u8, variant, "ghost") or std.mem.eql(u8, variant, "ghost-cachy")) {
        try buildCKernel(variant);
    } else {
        std.debug.print("Unknown variant: {s}\n", .{variant});
        try printUsage();
    }
}

fn printUsage() !void {
    std.debug.print(
        \\Usage: gbuild <variant>
        \\
        \\Variants:
        \\  ghost         Build standard linux-ghost kernel
        \\  ghost-cachy   Build linux-ghost with CachyOS patches  
        \\  experimental  Build experimental Zig kernel (linux-zghost)
        \\
    );
}

fn buildExperimentalKernel() !void {
    std.debug.print("Building experimental Zig kernel (linux-zghost)...\n");
    
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "zig", "build" },
        .cwd = "linux-zghost",
    }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
    
    if (result.term.Exited == 0) {
        std.debug.print("✓ Successfully built linux-zghost\n");
        std.debug.print("  Output: linux-zghost/zig-out/bin/linux-zghost\n");
        std.debug.print("  Run with: zig build --kernel --variant experimental\n");
    } else {
        std.debug.print("✗ Failed to build linux-zghost\n");
        std.debug.print("Error output: {s}\n", .{result.stderr});
    }
}

fn buildCKernel(variant: []const u8) !void {
    std.debug.print("Building C kernel variant: {s}...\n", .{variant});
    
    // Check if kernel source exists
    const kernel_source = "kernel-source";
    std.fs.cwd().access(kernel_source, .{}) catch {
        std.debug.print("Error: Kernel source not found at {s}\n", .{kernel_source});
        return;
    };
    
    // Check if config exists
    const config_path = std.fmt.allocPrint(
        std.heap.page_allocator,
        "linux-ghost/configs/{s}.config",
        .{variant}
    ) catch return;
    defer std.heap.page_allocator.free(config_path);
    
    std.fs.cwd().access(config_path, .{}) catch {
        std.debug.print("Warning: Config file not found at {s}\n", .{config_path});
        return;
    };
    
    // Apply patches first
    std.debug.print("Applying patches for {s}...\n", .{variant});
    try applyPatches(variant);
    
    // Build kernel with optimized flags
    const output_dir = std.fmt.allocPrint(
        std.heap.page_allocator,
        "zig-out/linux-ghost-{s}",
        .{variant}
    ) catch return;
    defer std.heap.page_allocator.free(output_dir);
    
    // Make output directory
    std.fs.cwd().makeDir(output_dir) catch {};
    
    const make_args = [_][]const u8{
        "make",
        "-C", kernel_source,
        std.fmt.allocPrint(std.heap.page_allocator, "O=../{s}", .{output_dir}) catch return,
        std.fmt.allocPrint(std.heap.page_allocator, "KCONFIG_CONFIG=../linux-ghost/configs/{s}.config", .{variant}) catch return,
        "CC=clang",
        "HOSTCC=clang", 
        "LLVM=1",
        "LLVM_IAS=1",
        std.fmt.allocPrint(std.heap.page_allocator, "KCFLAGS=-march=znver4 -O3", .{}) catch return,
        std.fmt.allocPrint(std.heap.page_allocator, "-j{d}", .{std.Thread.getCpuCount() catch 4}) catch return,
    };
    
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &make_args,
    }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
    
    if (result.term.Exited == 0) {
        std.debug.print("✓ Successfully built linux-ghost-{s}\n", .{variant});
        std.debug.print("  Kernel: {s}/arch/x86/boot/bzImage\n", .{output_dir});
        std.debug.print("  Modules: {s}/lib/modules/\n", .{output_dir});
    } else {
        std.debug.print("✗ Failed to build linux-ghost-{s}\n", .{variant});
        if (result.stderr.len > 0) {
            std.debug.print("Error output: {s}\n", .{result.stderr});
        }
    }
}

fn applyPatches(variant: []const u8) !void {
    const series_path = std.fmt.allocPrint(
        std.heap.page_allocator,
        "patches/series/{s}.series",
        .{variant}
    ) catch return;
    defer std.heap.page_allocator.free(series_path);
    
    const series_file = std.fs.cwd().openFile(series_path, .{}) catch {
        std.debug.print("Warning: No patch series found at {s}\n", .{series_path});
        return;
    };
    defer series_file.close();
    
    const content = series_file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(content);
    
    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        const patch_path = std.fmt.allocPrint(
            std.heap.page_allocator,
            "patches/{s}",
            .{trimmed}
        ) catch continue;
        defer std.heap.page_allocator.free(patch_path);
        
        std.debug.print("  Applying {s}...\n", .{patch_path});
        
        const patch_result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "patch", "-p1", "-d", "kernel-source", "-i", std.fmt.allocPrint(std.heap.page_allocator, "../{s}", .{patch_path}) catch continue },
        }) catch |err| {
            std.debug.print("    Warning: Failed to apply {s}: {}\n", .{ patch_path, err });
            continue;
        };
        
        if (patch_result.term.Exited != 0) {
            std.debug.print("    Warning: Patch {s} failed\n", .{patch_path});
        }
    }
}

fn createDefaultConfig(variant: []const u8) !void {
    const config_dir = "linux-ghost/configs";
    std.fs.cwd().makeDir(config_dir) catch {};
    
    const config_path = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}/{s}.config",
        .{ config_dir, variant }
    ) catch return;
    defer std.heap.page_allocator.free(config_path);
    
    const config_content = 
        \\# Linux Ghost Kernel Configuration
        \\CONFIG_X86_64=y
        \\CONFIG_SMP=y
        \\CONFIG_MODULES=y
        \\CONFIG_MODULE_UNLOAD=y
        \\CONFIG_IKCONFIG=y
        \\CONFIG_IKCONFIG_PROC=y
        \\CONFIG_LOCALVERSION="-ghost"
        \\CONFIG_LOCALVERSION_AUTO=y
        \\CONFIG_KERNEL_GZIP=y
        \\# NVIDIA Open Kernel Module support
        \\CONFIG_DRM=y
        \\CONFIG_DRM_NOUVEAU=n
        \\# Bore-EEVDF scheduler
        \\CONFIG_SCHED_BORE=y
        \\
    ;
    
    const file = std.fs.cwd().createFile(config_path, .{}) catch {
        std.debug.print("Error: Cannot create config file {s}\n", .{config_path});
        return;
    };
    defer file.close();
    
    file.writeAll(config_content) catch {
        std.debug.print("Error: Cannot write to config file {s}\n", .{config_path});
        return;
    };
    
    std.debug.print("Created default config: {s}\n", .{config_path});
}