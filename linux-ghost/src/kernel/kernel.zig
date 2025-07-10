//! Linux ZGhost Kernel Core
//! Pure Zig implementation of Linux kernel fundamentals

const std = @import("std");
const console = @import("../arch/x86_64/console.zig");
const memory = @import("../mm/memory.zig");
const sched = @import("../kernel/sched.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");
const config = @import("config");

// Gaming optimization imports - direct file imports
const gaming_pagefault = if (config.CONFIG_GAMING_OPTIMIZATIONS) @import("../mm/gaming_pagefault.zig") else struct {};
const realtime_compaction = if (config.CONFIG_REALTIME_COMPACTION) @import("../mm/realtime_compaction.zig") else struct {};
const gaming_futex = if (config.CONFIG_GAMING_FUTEX) @import("gaming_futex.zig") else struct {};
const gaming_priority = if (config.CONFIG_GAMING_PRIORITY) @import("gaming_priority.zig") else struct {};
const direct_storage = if (config.CONFIG_DIRECT_STORAGE) @import("../fs/direct_storage.zig") else struct {};
const numa_cache_sched = if (config.CONFIG_NUMA_CACHE_AWARE) @import("numa_cache_sched.zig") else struct {};
const gaming_syscalls = if (config.CONFIG_GAMING_SYSCALLS) @import("gaming_syscalls.zig") else struct {};
const hw_timestamp_sched = if (config.CONFIG_HW_TIMESTAMP_SCHED) @import("hw_timestamp_sched.zig") else struct {};

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
    gaming_subsystems: SubsystemState = .uninitialized,
    direct_storage: SubsystemState = .uninitialized,
    hw_timestamp: SubsystemState = .uninitialized,
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
    
    // Initialize gaming optimizations if enabled
    if (comptime config.CONFIG_GAMING_OPTIMIZATIONS) {
        subsystem_states.gaming_subsystems = .initializing;
        try initializeGamingSubsystems();
        subsystem_states.gaming_subsystems = .running;
        console.setColor(.green, .black);
        console.writeString("  Gaming Optimizations: OK\n");
        console.setColor(.white, .black);
    }
    
    // TODO: Initialize other subsystems
    console.writeString("linux-zghost: Subsystem initialization complete\n");
}

/// Initialize gaming-specific subsystems
fn initializeGamingSubsystems() !void {
    const allocator = memory.getKernelAllocator();
    
    // Initialize gaming page fault handler
    if (comptime config.CONFIG_GAMING_OPTIMIZATIONS) {
        try gaming_pagefault.initGamingPageFault(allocator);
        console.writeString("    Gaming Page Fault Handler: OK\n");
    }
    
    // Initialize real-time memory compaction
    if (comptime config.CONFIG_REALTIME_COMPACTION) {
        _ = try realtime_compaction.initRealtimeCompaction(allocator);
        console.writeString("    Real-time Memory Compaction: OK\n");
    }
    
    // Initialize gaming FUTEX
    if (comptime config.CONFIG_GAMING_FUTEX) {
        try gaming_futex.initGamingFutex(allocator);
        console.writeString("    Gaming FUTEX: OK\n");
    }
    
    // Initialize gaming priority inheritance
    if (comptime config.CONFIG_GAMING_PRIORITY) {
        try gaming_priority.initGamingPriority(allocator);
        console.writeString("    Gaming Priority Inheritance: OK\n");
    }
    
    // Initialize Direct Storage API
    if (comptime config.CONFIG_DIRECT_STORAGE) {
        subsystem_states.direct_storage = .initializing;
        try direct_storage.initDirectStorage(allocator);
        subsystem_states.direct_storage = .running;
        console.writeString("    Direct Storage API: OK\n");
    }
    
    // Initialize NUMA cache-aware scheduling
    if (comptime config.CONFIG_NUMA_CACHE_AWARE) {
        try numa_cache_sched.initNUMACacheScheduler(allocator);
        console.writeString("    NUMA Cache-Aware Scheduling: OK\n");
    }
    
    // Initialize gaming system calls
    if (comptime config.CONFIG_GAMING_SYSCALLS) {
        try gaming_syscalls.initGamingSyscalls(allocator);
        console.writeString("    Gaming System Calls: OK\n");
    }
    
    // Initialize hardware timestamp scheduling
    if (comptime config.CONFIG_HW_TIMESTAMP_SCHED) {
        subsystem_states.hw_timestamp = .initializing;
        try hw_timestamp_sched.initHardwareTimestampScheduling(allocator);
        subsystem_states.hw_timestamp = .running;
        console.writeString("    Hardware Timestamp Scheduling: OK\n");
    }
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