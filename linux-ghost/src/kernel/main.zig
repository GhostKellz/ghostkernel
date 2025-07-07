const std = @import("std");
const kernel = @import("kernel.zig");
const console = @import("../arch/x86_64/console.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");

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
    
    console.setColor(.green, .black);
    console.writeString("linux-zghost: Kernel initialization complete!\n");
    console.setColor(.white, .black);
    
    // Enable interrupts
    interrupts.enable();
    
    // Start kernel main loop
    kernel.kernelLoop();
}