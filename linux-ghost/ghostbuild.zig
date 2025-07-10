const std = @import("std");
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: zig run ghostbuild.zig -- <command>\n");
        print("Commands:\n");
        print("  configure   - Configure kernel build options\n");
        print("  build       - Build the kernel\n");
        print("  install     - Install kernel and modules\n");
        print("  package     - Create installable package\n");
        print("  clean       - Clean build artifacts\n");
        print("  menuconfig  - Interactive kernel configuration\n");
        return;
    }

    const cmd = args[1];
    
    if (std.mem.eql(u8, cmd, "configure")) {
        try configure();
    } else if (std.mem.eql(u8, cmd, "build")) {
        try build();
    } else if (std.mem.eql(u8, cmd, "install")) {
        try install();
    } else if (std.mem.eql(u8, cmd, "package")) {
        try package();
    } else if (std.mem.eql(u8, cmd, "clean")) {
        try clean();
    } else if (std.mem.eql(u8, cmd, "menuconfig")) {
        try menuconfig();
    } else {
        print("Unknown command: {s}\n", .{cmd});
    }
}

fn configure() !void {
    print("==> Configuring GhostKernel build...\n");
    
    // Read current configuration
    const config = try readConfig();
    
    print("Current configuration:\n");
    print("  CPU Architecture: {s}\n", .{config.cpu_arch});
    print("  GPU Support: {}\n", .{config.gpu_support});
    print("  NVIDIA Support: {}\n", .{config.nvidia_support});
    print("  Gaming Mode: {}\n", .{config.gaming_mode});
    print("  AI Acceleration: {}\n", .{config.ai_acceleration});
    print("  Debug Mode: {}\n", .{config.debug_mode});
    
    // TODO: Interactive configuration
    print("Configuration complete. Run 'zig run ghostbuild.zig -- build' to build.\n");
}

fn build() !void {
    print("==> Building GhostKernel...\n");
    
    const config = try readConfig();
    
    // Build zig command
    var cmd = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer cmd.deinit();
    
    try cmd.append("zig");
    try cmd.append("build");
    try cmd.append("--release=safe");
    
    // Add configuration options
    if (!config.gpu_support) {
        try cmd.append("-Dgpu=false");
    }
    if (!config.nvidia_support) {
        try cmd.append("-Dnvidia=false");
    }
    if (!config.gaming_mode) {
        try cmd.append("-Dgaming=false");
    }
    if (!config.ai_acceleration) {
        try cmd.append("-Dai=false");
    }
    if (config.debug_mode) {
        try cmd.append("-Ddebug=true");
    }
    
    // Add CPU architecture
    const cpu_arg = try std.fmt.allocPrint(std.heap.page_allocator, "-Dcpu-arch={s}", .{config.cpu_arch});
    try cmd.append(cpu_arg);
    
    // Execute build
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = cmd.items,
    });
    
    if (result.term.Exited != 0) {
        print("Build failed!\n");
        print("stderr: {s}\n", .{result.stderr});
        return;
    }
    
    print("==> Build successful!\n");
    print("Kernel binary: zig-out/bin/linux-ghost\n");
}

fn install() !void {
    print("==> Installing GhostKernel...\n");
    
    // Check if running as root
    if (std.os.linux.getuid() != 0) {
        print("Error: Installation requires root privileges\n");
        print("Run with: sudo zig run ghostbuild.zig -- install\n");
        return;
    }
    
    // Install kernel
    print("Installing kernel to /boot/linux-ghost...\n");
    try std.fs.cwd().copyFile("zig-out/bin/linux-ghost", std.fs.cwd(), "/boot/linux-ghost", .{});
    
    // Install modules (if any)
    print("Installing kernel modules...\n");
    // TODO: Install modules to /lib/modules/
    
    // Create mkinitcpio preset
    print("Creating mkinitcpio preset...\n");
    try createMkinitcpioPreset();
    
    // Update initramfs
    print("Updating initramfs...\n");
    const mkinitcpio_result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "mkinitcpio", "-p", "linux-ghost" },
    });
    
    if (mkinitcpio_result.term.Exited != 0) {
        print("Warning: mkinitcpio failed, you may need to run it manually\n");
    }
    
    // Detect and configure bootloader
    if (std.fs.openDirAbsolute("/boot/loader", .{})) |_| {
        print("Detected systemd-boot, configuring...\n");
        try configureSystemdBoot();
    } else |_| {
        print("Systemd-boot not detected, checking for GRUB...\n");
        if (std.fs.openFileAbsolute("/boot/grub/grub.cfg", .{})) |file| {
            file.close();
            print("Updating GRUB...\n");
            const grub_result = try std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &[_][]const u8{ "grub-mkconfig", "-o", "/boot/grub/grub.cfg" },
            });
            
            if (grub_result.term.Exited != 0) {
                print("Warning: GRUB update failed, you may need to run grub-mkconfig manually\n");
            }
        } else |_| {
            print("No supported bootloader detected. Please configure manually.\n");
        }
    }
    
    print("==> Installation complete!\n");
    print("Reboot to use the new kernel.\n");
}

fn package() !void {
    print("==> Creating GhostKernel package...\n");
    
    // Create package directory
    try std.fs.cwd().makeDir("pkg");
    
    // Copy kernel
    try std.fs.cwd().copyFile("zig-out/bin/linux-ghost", std.fs.cwd(), "pkg/linux-ghost", .{});
    
    // Create package metadata
    const pkg_info = 
        \\name=linux-ghost
        \\version=6.15.5
        \\description=GhostKernel - Pure Zig Linux kernel with gaming optimizations
        \\depends=
        \\
    ;
    
    try std.fs.cwd().writeFile("pkg/GHOSTINFO", pkg_info);
    
    // Create install script
    const install_script = 
        \\#!/bin/bash
        \\cp linux-ghost /boot/
        \\mkinitcpio -p linux-ghost
        \\grub-mkconfig -o /boot/grub/grub.cfg
        \\
    ;
    
    try std.fs.cwd().writeFile("pkg/install.sh", install_script);
    
    // Create tarball
    const tar_result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "tar", "-czf", "ghostkernel-6.15.5.tar.gz", "-C", "pkg", "." },
    });
    
    if (tar_result.term.Exited != 0) {
        print("Failed to create package tarball\n");
        return;
    }
    
    print("==> Package created: ghostkernel-6.15.5.tar.gz\n");
}

fn clean() !void {
    print("==> Cleaning build artifacts...\n");
    
    std.fs.cwd().deleteTree("zig-out") catch {};
    std.fs.cwd().deleteTree("zig-cache") catch {};
    std.fs.cwd().deleteTree(".zig-cache") catch {};
    std.fs.cwd().deleteTree("pkg") catch {};
    
    print("==> Clean complete!\n");
}

fn menuconfig() !void {
    print("==> GhostKernel Configuration Menu\n");
    print("===================================\n");
    
    const config = try readConfig();
    
    print("1. CPU Architecture: {s}\n", .{config.cpu_arch});
    print("2. GPU Support: {}\n", .{config.gpu_support});
    print("3. NVIDIA Support: {}\n", .{config.nvidia_support});
    print("4. Gaming Mode: {}\n", .{config.gaming_mode});
    print("5. AI Acceleration: {}\n", .{config.ai_acceleration});
    print("6. Debug Mode: {}\n", .{config.debug_mode});
    print("7. Save and Exit\n");
    
    // TODO: Interactive menu implementation
    print("Interactive configuration not yet implemented.\n");
    print("Edit ghostkernel.conf manually for now.\n");
}

const KernelConfig = struct {
    cpu_arch: []const u8,
    gpu_support: bool,
    nvidia_support: bool,
    gaming_mode: bool,
    ai_acceleration: bool,
    debug_mode: bool,
};

fn readConfig() !KernelConfig {
    // Default configuration
    var config = KernelConfig{
        .cpu_arch = "znver4",
        .gpu_support = true,
        .nvidia_support = true,
        .gaming_mode = true,
        .ai_acceleration = true,
        .debug_mode = false,
    };
    
    // Try to read from config file
    const config_file = std.fs.cwd().openFile("ghostkernel.conf", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Create default config
            try writeDefaultConfig();
            return config;
        },
        else => return err,
    };
    defer config_file.close();
    
    // TODO: Parse config file
    
    return config;
}

fn writeDefaultConfig() !void {
    const default_config = 
        \\# GhostKernel Configuration
        \\# Edit this file to customize your kernel build
        \\
        \\cpu_arch=znver4
        \\gpu_support=true
        \\nvidia_support=true
        \\gaming_mode=true
        \\ai_acceleration=true
        \\debug_mode=false
        \\
    ;
    
    try std.fs.cwd().writeFile("ghostkernel.conf", default_config);
}

fn configureSystemdBoot() !void {
    // Create systemd-boot entry
    const entry_content = 
        \\title   GhostKernel
        \\linux   /linux-ghost
        \\initrd  /amd-ucode.img
        \\initrd  /initramfs-linux-ghost.img
        \\options root=PARTUUID=00000000-0000-0000-0000-000000000000 rw
        \\
    ;
    
    // Write boot entry
    const boot_dir = std.fs.openDirAbsolute("/boot", .{}) catch {
        print("Error: Cannot access /boot directory\n");
        return;
    };
    defer boot_dir.close();
    
    const loader_dir = boot_dir.openDir("loader", .{}) catch {
        print("Error: /boot/loader directory not found\n");
        return;
    };
    defer loader_dir.close();
    
    const entries_dir = loader_dir.openDir("entries", .{}) catch {
        print("Creating /boot/loader/entries directory...\n");
        try loader_dir.makeDir("entries");
        return loader_dir.openDir("entries", .{});
    };
    defer entries_dir.close();
    
    // Write linux-ghost.conf
    try entries_dir.writeFile("linux-ghost.conf", entry_content);
    print("Created /boot/loader/entries/linux-ghost.conf\n");
    
    // Update loader.conf to default to linux-ghost
    const loader_content = 
        \\timeout 3
        \\default linux-ghost.conf
        \\console-mode keep
        \\editor no
        \\
    ;
    
    try loader_dir.writeFile("loader.conf", loader_content);
    print("Updated /boot/loader/loader.conf to default to linux-ghost\n");
    
    // Detect root partition UUID
    print("Note: Update the PARTUUID in /boot/loader/entries/linux-ghost.conf with your root partition UUID\n");
    print("Find it with: blkid -s PARTUUID -o value /dev/sdXY\n");
}

fn createMkinitcpioPreset() !void {
    const preset_content = 
        \\# mkinitcpio preset file for linux-ghost
        \\# Only build default image, no fallback
        \\
        \\ALL_config="/etc/mkinitcpio.conf"
        \\ALL_kver="/boot/linux-ghost"
        \\
        \\PRESETS=('default')
        \\
        \\#default_config="/etc/mkinitcpio.conf"
        \\default_image="/boot/initramfs-linux-ghost.img"
        \\#default_options=""
        \\
        \\# No fallback image
        \\#fallback_config="/etc/mkinitcpio.conf"
        \\#fallback_image="/boot/initramfs-linux-ghost-fallback.img"
        \\#fallback_options="-S autodetect"
        \\
    ;
    
    const preset_dir = std.fs.openDirAbsolute("/etc/mkinitcpio.d", .{}) catch {
        print("Error: /etc/mkinitcpio.d directory not found\n");
        return;
    };
    defer preset_dir.close();
    
    try preset_dir.writeFile("linux-ghost.preset", preset_content);
    print("Created /etc/mkinitcpio.d/linux-ghost.preset\n");
}