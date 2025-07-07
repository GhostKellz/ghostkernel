//! Linux ZGhost Kernel Core
//! Pure Zig implementation of Linux kernel fundamentals

const std = @import("std");
const console = @import("../arch/x86_64/console.zig");
const memory = @import("../mm/memory.zig");
const sched = @import("../kernel/sched.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");

pub const KernelInfo = struct {
    version: Version,
    build_date: []const u8,
    compiler: []const u8,
    features: Features,
    
    pub const Version = struct {
        major: u8 = 6,
        minor: u8 = 15,
        patch: u8 = 5,
        ghost: []const u8 = "0.1.0-experimental",
        
        pub fn toString(self: Version, buffer: []u8) ![]u8 {
            return std.fmt.bufPrint(buffer, "{d}.{d}.{d}-zghost-{s}", .{
                self.major, self.minor, self.patch, self.ghost
            });
        }
    };
    
    pub const Features = packed struct {
        bore_scheduler: bool = true,
        sched_ext: bool = true,
        memory_safety: bool = true,
        async_io: bool = true,
        zero_copy: bool = true,
        live_patching: bool = false,
        _reserved: u58 = 0,
    };
};

pub var kernel_info = KernelInfo{
    .version = KernelInfo.Version{},
    .build_date = @import("builtin").timestamp,
    .compiler = "Zig " ++ @import("builtin").zig_version_string,
    .features = KernelInfo.Features{},
};

/// Kernel subsystem states
pub const SubsystemState = enum {
    uninitialized,
    initializing,
    running,
    suspended,
    error_state,
};

pub var subsystem_states = struct {
    memory: SubsystemState = .uninitialized,
    scheduler: SubsystemState = .uninitialized,
    filesystem: SubsystemState = .uninitialized,
    network: SubsystemState = .uninitialized,
    drivers: SubsystemState = .uninitialized,
    console: SubsystemState = .uninitialized,
}{};

/// Kernel panic handler
pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = stack_trace;
    _ = ret_addr;
    
    console.setColor(.red, .black);
    console.writeString("\n*** KERNEL PANIC ***\n");
    console.writeString("linux-zghost: ");
    console.writeString(message);
    console.writeString("\n");
    
    // TODO: Dump registers, stack trace, system state
    console.writeString("System halted.\n");
    
    // Disable interrupts and halt
    interrupts.disable();
    while (true) {
        asm volatile ("hlt");
    }
}

/// Initialize kernel subsystems
pub fn initializeSubsystems() !void {
    console.writeString("linux-zghost: Initializing kernel subsystems...\n");
    
    // Initialize console first for early debugging
    subsystem_states.console = .initializing;
    try console.init();
    subsystem_states.console = .running;
    console.writeString("  Console: OK\n");
    
    // Initialize memory management
    subsystem_states.memory = .initializing;
    try memory.init();
    subsystem_states.memory = .running;
    console.writeString("  Memory Management: OK\n");
    
    // Initialize scheduler
    subsystem_states.scheduler = .initializing;
    try sched.init();
    subsystem_states.scheduler = .running;
    console.writeString("  Scheduler: OK\n");
    
    // TODO: Initialize other subsystems
    console.writeString("linux-zghost: Subsystem initialization complete\n");
}

/// Print kernel banner and information
pub fn printBanner() !void {
    var version_buffer: [64]u8 = undefined;
    const version_str = try kernel_info.version.toString(&version_buffer);
    
    console.setColor(.cyan, .black);
    console.writeString("\n");
    console.writeString("  _____ _               _      _____           _   \n");
    console.writeString(" |  ___| |             | |    |  __ \\         | |  \n");
    console.writeString(" | |__ | |__   __ _ ___| |_   | |  \\/| |__ ___ | |_ \n");
    console.writeString(" |  __|| '_ \\ / _` / __| __|  | | __ | '_ \\ / _ \\| __|\n");
    console.writeString(" | |___| | | | (_| \\__ \\ |_   | |_\\ \\| | | |  __/| |_ \n");
    console.writeString(" \\____/|_| |_|\\__,_|___/\\__|   \\____/|_| |_|\\___| \\__|\n");
    console.writeString("\n");
    
    console.setColor(.white, .black);
    console.writeString("Linux ZGhost Experimental Kernel\n");
    console.writeString("Version: ");
    console.writeString(version_str);
    console.writeString("\n");
    console.writeString("Compiler: ");
    console.writeString(kernel_info.compiler);
    console.writeString("\n");
    
    console.setColor(.green, .black);
    console.writeString("Features: ");
    if (kernel_info.features.bore_scheduler) console.writeString("BORE ");
    if (kernel_info.features.sched_ext) console.writeString("SCHED-EXT ");
    if (kernel_info.features.memory_safety) console.writeString("MEMORY-SAFETY ");
    if (kernel_info.features.async_io) console.writeString("ASYNC-IO ");
    if (kernel_info.features.zero_copy) console.writeString("ZERO-COPY ");
    console.writeString("\n");
    
    console.setColor(.white, .black);
    console.writeString("\n");
}

/// Kernel main loop
pub fn kernelLoop() noreturn {
    console.writeString("linux-zghost: Entering kernel main loop\n");
    
    var tick_count: u64 = 0;
    
    while (true) {
        // Process scheduler
        sched.tick();
        
        // Handle memory management tasks
        memory.tick();
        
        // Periodic kernel housekeeping
        tick_count += 1;
        if (tick_count % 1000 == 0) {
            // Every 1000 ticks, do some maintenance
            console.writeString(".");
        }
        
        // Yield to scheduler or halt if idle
        if (sched.hasRunnableTasks()) {
            sched.schedule();
        } else {
            // No runnable tasks, halt until interrupt
            asm volatile ("hlt");
        }
    }
}

/// Get kernel uptime in ticks
pub fn getUptime() u64 {
    // TODO: Implement proper timer/RTC integration
    return 0;
}

/// Check if kernel is in a healthy state
pub fn isHealthy() bool {
    return subsystem_states.memory == .running and
           subsystem_states.scheduler == .running and
           subsystem_states.console == .running;
}