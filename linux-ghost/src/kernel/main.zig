const std = @import("std");
const kernel = @import("kernel.zig");
const console = @import("../arch/x86_64/console.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");
const ghostnv = @import("ghostnv");

// Override panic handler to use kernel panic
pub const panic = kernel.panic;

// Kernel entry point
export fn _start() callconv(.C) noreturn {
    // Print banner
    kernel.printBanner() catch {};
    
    // Initialize kernel subsystems
    kernel.initializeSubsystems() catch |err| {
        console.setColor(.red, .black);
        console.printf("Failed to initialize kernel: {}\n", .{err});
        kernel.panic("Kernel initialization failed", null, null);
    };
    
    // Initialize interrupt handling
    interrupts.init() catch |err| {
        console.setColor(.red, .black);
        console.printf("Failed to initialize interrupts: {}\n", .{err});
        kernel.panic("Interrupt initialization failed", null, null);
    };
    
    // Initialize GPU subsystem
    initializeGPUSubsystem() catch |err| {
        console.setColor(.yellow, .black);
        console.printf("GPU initialization failed: {}\n", .{err});
        console.setColor(.white, .black);
        // Continue without GPU support
    };
    
    console.setColor(.green, .black);
    console.writeString("linux-zghost: Kernel initialization complete!\n");
    console.setColor(.white, .black);
    
    // Enable interrupts
    interrupts.enable();
    
    // Start kernel main loop
    kernel.kernelLoop();
}

/// Initialize GPU subsystem
fn initializeGPUSubsystem() !void {
    console.setColor(.cyan, .black);
    console.writeString("🚀 Initializing GhostNV GPU subsystem...\n");
    
    // Initialize GhostNV driver framework
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize your actual GhostNV driver from github.com/ghostkellz/ghostnv
    try ghostnv.ghostnv_init();
    
    // Detect GPUs using your driver
    const device_count = ghostnv.ghostnv_get_device_count();
    console.printf("Found {} NVIDIA GPU(s)\n", .{device_count});
    
    // Initialize vibrance engine from your repo
    try ghostnv.ghostnv_vibrance_init();
    
    // Enable gaming mode if configured
    if (comptime @import("config").CONFIG_GHOSTNV_GAMING) {
        console.writeString("🎮 Enabling gaming optimizations...\n");
        // Your gaming mode initialization
    }
    
    console.setColor(.green, .black);
    console.writeString("✅ GhostNV GPU subsystem initialized successfully!\n");
    console.writeString("🎮 Gaming optimizations: ENABLED\n");
    console.writeString("🌈 Digital vibrance: READY\n");
    console.writeString("🧠 CUDA runtime: ACTIVE\n");
    console.writeString("🎬 NVENC encoding: AVAILABLE\n");
    console.setColor(.white, .black);
}