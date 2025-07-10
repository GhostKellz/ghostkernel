//! Linux Ghost Kernel - Main Entry Point
//! Pure Zig implementation of Linux kernel 6.15.5 with gaming optimizations

const std = @import("std");
const kernel = @import("kernel/kernel.zig");
const console = @import("arch/x86_64/console.zig");
const interrupts = @import("arch/x86_64/interrupts.zig");
const memory = @import("mm/memory.zig");
const config = @import("config");

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    console.panic_print("KERNEL PANIC: {s}\n", .{message});
    while (true) {
        asm volatile ("hlt");
    }
}

export fn _start() noreturn {
    // Initialize console first
    console.init() catch {
        // If console init fails, we can't even print an error
        while (true) {
            asm volatile ("hlt");
        }
    };
    console.printf("Linux Ghost Kernel v6.15.5 Starting...\n", .{});
    
    // Initialize memory management
    memory.init() catch {
        panic("Failed to initialize memory management");
    };
    
    // Initialize interrupt handling
    interrupts.init() catch {
        panic("Failed to initialize interrupt handling");
    };
    
    // Initialize kernel subsystems
    kernel.initializeSubsystems() catch {
        panic("Failed to initialize kernel subsystems");
    };
    
    console.printf("Kernel initialization complete\n", .{});
    
    // Main kernel loop - basic idle loop
    while (true) {
        asm volatile ("hlt");
    }
}