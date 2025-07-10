//! Gaming-Specific System Calls
//! Bypass generic kernel paths for common gaming operations
//! Features optimized I/O, memory, scheduling, and synchronization calls

const std = @import("std");
const sched = @import("sched.zig");
const memory = @import("../mm/memory.zig");
const vfs = @import("../fs/vfs.zig");
const direct_storage = @import("../fs/direct_storage.zig");
const gaming_futex = @import("gaming_futex.zig");
const console = @import("../arch/x86_64/console.zig");

/// Gaming system call numbers (starting at 1000 to avoid conflicts)
pub const GamingSyscall = enum(u64) {
    // Memory operations
    gaming_mmap = 1000,           // Gaming-optimized memory mapping
    gaming_munmap = 1001,         // Gaming-optimized memory unmapping
    gaming_madvise = 1002,        // Gaming memory advice
    gaming_mlock = 1003,          // Lock gaming memory (no swap)
    
    // I/O operations
    gaming_read = 1010,           // Zero-copy gaming read
    gaming_write = 1011,          // Zero-copy gaming write
    gaming_pread = 1012,          // Positioned gaming read
    gaming_sendfile = 1013,       // Zero-copy file transfer
    
    // Asset loading
    gaming_load_asset = 1020,     // Direct Storage asset loading
    gaming_stream_asset = 1021,   // Streaming asset loading
    gaming_preload_assets = 1022, // Batch asset preloading
    
    // Synchronization
    gaming_futex = 1030,          // Gaming-optimized FUTEX
    gaming_mutex_lock = 1031,     // Fast gaming mutex
    gaming_cond_wait = 1032,      // Gaming condition variables
    gaming_barrier_wait = 1033,   // Gaming thread barriers
    
    // Scheduling
    gaming_sched_boost = 1040,    // Boost task priority
    gaming_sched_frame = 1041,    // Mark frame boundary
    gaming_sched_yield = 1042,    // Gaming-aware yield
    gaming_set_affinity = 1043,   // Gaming CPU affinity
    
    // Time operations
    gaming_nanosleep = 1050,      // High-precision gaming sleep
    gaming_get_time = 1051,       // Fast time retrieval
    gaming_set_timer = 1052,      // Gaming timer
    
    // GPU operations
    gaming_gpu_submit = 1060,     // Submit GPU commands
    gaming_gpu_sync = 1061,       // GPU synchronization
    gaming_gpu_memory = 1062,     // GPU memory operations
};

/// Gaming system call parameters
pub const GamingMmapParams = struct {
    addr: ?*anyopaque,
    length: usize,
    prot: u32,
    flags: u32,
    gaming_flags: GamingMmapFlags,
};

pub const GamingMmapFlags = struct {
    frame_buffer: bool = false,    // Frame buffer memory
    asset_cache: bool = false,     // Asset cache memory
    zero_copy: bool = false,       // Zero-copy optimized
    numa_local: bool = false,      // NUMA-local allocation
    huge_pages: bool = false,      // Use huge pages
    lock_memory: bool = false,     // Lock in physical memory
};

pub const GamingIOParams = struct {
    fd: i32,
    buffer: [*]u8,
    count: usize,
    offset: i64,
    flags: GamingIOFlags,
};

pub const GamingIOFlags = struct {
    zero_copy: bool = false,       // Use zero-copy I/O
    direct: bool = false,          // Direct I/O (bypass cache)
    asynchronous: bool = false,    // Asynchronous I/O
    priority: IOPriority = .normal, // I/O priority
    
    const IOPriority = enum {
        immediate,
        high,
        normal,
        background,
    };
};

pub const GamingAssetParams = struct {
    path: [*:0]const u8,
    buffer: ?[*]u8,
    size: usize,
    asset_type: direct_storage.AssetType,
    priority: direct_storage.AssetPriority,
    flags: direct_storage.DirectStorageFlags,
};

pub const GamingSchedParams = struct {
    pid: u32,
    priority_boost: i8,
    affinity_mask: u64,
    frame_rate: u32,
    gaming_flags: GamingSchedFlags,
};

pub const GamingSchedFlags = struct {
    frame_critical: bool = false,
    audio_critical: bool = false,
    input_critical: bool = false,
    vrr_sync: bool = false,
    deadline_scheduling: bool = false,
};

/// Gaming system call statistics
pub const GamingSyscallStats = struct {
    total_calls: u64 = 0,
    fast_path_hits: u64 = 0,
    zero_copy_operations: u64 = 0,
    cache_bypasses: u64 = 0,
    gaming_boosts_applied: u64 = 0,
    average_latency_ns: u64 = 0,
    
    pub fn update(self: *GamingSyscallStats, latency_ns: u64, fast_path: bool, zero_copy: bool) void {
        self.total_calls += 1;
        if (fast_path) self.fast_path_hits += 1;
        if (zero_copy) self.zero_copy_operations += 1;
        
        // Update average latency
        const old_avg = self.average_latency_ns;
        self.average_latency_ns = (old_avg * (self.total_calls - 1) + latency_ns) / self.total_calls;
    }
};

/// Gaming System Call Handler
pub const GamingSyscallHandler = struct {
    stats: GamingSyscallStats,
    
    /// Main system call dispatcher
    pub fn handleSyscall(self: *GamingSyscallHandler, syscall_num: u64, args: [6]u64) !i64 {
        const start_time = std.time.nanoTimestamp();
        const gaming_syscall = @as(GamingSyscall, @enumFromInt(syscall_num));
        
        const result = switch (gaming_syscall) {
            // Memory operations
            .gaming_mmap => try self.sys_gaming_mmap(args),
            .gaming_munmap => try self.sys_gaming_munmap(args),
            .gaming_madvise => try self.sys_gaming_madvise(args),
            .gaming_mlock => try self.sys_gaming_mlock(args),
            
            // I/O operations
            .gaming_read => try self.sys_gaming_read(args),
            .gaming_write => try self.sys_gaming_write(args),
            .gaming_pread => try self.sys_gaming_pread(args),
            .gaming_sendfile => try self.sys_gaming_sendfile(args),
            
            // Asset loading
            .gaming_load_asset => try self.sys_gaming_load_asset(args),
            .gaming_stream_asset => try self.sys_gaming_stream_asset(args),
            .gaming_preload_assets => try self.sys_gaming_preload_assets(args),
            
            // Synchronization
            .gaming_futex => try self.sys_gaming_futex(args),
            .gaming_mutex_lock => try self.sys_gaming_mutex_lock(args),
            .gaming_cond_wait => try self.sys_gaming_cond_wait(args),
            .gaming_barrier_wait => try self.sys_gaming_barrier_wait(args),
            
            // Scheduling
            .gaming_sched_boost => try self.sys_gaming_sched_boost(args),
            .gaming_sched_frame => try self.sys_gaming_sched_frame(args),
            .gaming_sched_yield => try self.sys_gaming_sched_yield(args),
            .gaming_set_affinity => try self.sys_gaming_set_affinity(args),
            
            // Time operations
            .gaming_nanosleep => try self.sys_gaming_nanosleep(args),
            .gaming_get_time => try self.sys_gaming_get_time(args),
            .gaming_set_timer => try self.sys_gaming_set_timer(args),
            
            // GPU operations
            .gaming_gpu_submit => try self.sys_gaming_gpu_submit(args),
            .gaming_gpu_sync => try self.sys_gaming_gpu_sync(args),
            .gaming_gpu_memory => try self.sys_gaming_gpu_memory(args),
        };
        
        // Update statistics
        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));
        const fast_path = latency < 1000; // < 1μs is fast path
        
        self.stats.update(latency, fast_path, false);
        
        return result;
    }
    
    // Memory operations
    fn sys_gaming_mmap(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const params_ptr = @as(*const GamingMmapParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        // Gaming-optimized memory mapping
        _ = params.addr;
        
        // Apply gaming optimizations
        if (params.gaming_flags.numa_local) {
            // Allocate on local NUMA node for better performance
        }
        
        if (params.gaming_flags.huge_pages) {
            // Use huge pages for better TLB performance
        }
        
        if (params.gaming_flags.lock_memory) {
            // Lock memory to prevent swapping
        }
        
        // Mock successful allocation
        const result_addr = 0x7f0000000000; // Mock address
        
        console.printf("Gaming mmap: allocated {} bytes at 0x{X}\\n", .{ params.length, result_addr });
        return @intCast(result_addr);
    }
    
    fn sys_gaming_munmap(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const addr = args[0];
        const length = args[1];
        
        console.printf("Gaming munmap: freed {} bytes at 0x{X}\\n", .{ length, addr });
        return 0;
    }
    
    fn sys_gaming_madvise(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const addr = args[0];
        const length = args[1];
        const advice = args[2];
        
        // Gaming-specific memory advice
        switch (advice) {
            1 => console.writeString("Gaming madvise: WILLNEED optimization\\n"),
            2 => console.writeString("Gaming madvise: DONTNEED optimization\\n"),
            else => {},
        }
        
        _ = addr;
        _ = length;
        return 0;
    }
    
    fn sys_gaming_mlock(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const addr = args[0];
        const length = args[1];
        
        console.printf("Gaming mlock: locked {} bytes at 0x{X}\\n", .{ length, addr });
        return 0;
    }
    
    // I/O operations
    fn sys_gaming_read(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        const params_ptr = @as(*const GamingIOParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        // Fast path for gaming I/O
        if (params.flags.zero_copy) {
            self.stats.zero_copy_operations += 1;
            console.writeString("Gaming read: zero-copy optimization\\n");
        }
        
        if (params.flags.direct) {
            self.stats.cache_bypasses += 1;
            console.writeString("Gaming read: direct I/O bypass\\n");
        }
        
        // Mock successful read
        return @intCast(params.count);
    }
    
    fn sys_gaming_write(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const params_ptr = @as(*const GamingIOParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        console.printf("Gaming write: {} bytes\\n", .{params.count});
        return @intCast(params.count);
    }
    
    fn sys_gaming_pread(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const params_ptr = @as(*const GamingIOParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        console.printf("Gaming pread: {} bytes at offset {}\\n", .{ params.count, params.offset });
        return @intCast(params.count);
    }
    
    fn sys_gaming_sendfile(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const out_fd = @as(i32, @intCast(args[0]));
        const in_fd = @as(i32, @intCast(args[1]));
        const count = args[2];
        
        console.printf("Gaming sendfile: {} bytes from fd {} to fd {}\\n", .{ count, in_fd, out_fd });
        return @intCast(count);
    }
    
    // Asset loading
    fn sys_gaming_load_asset(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const params_ptr = @as(*const GamingAssetParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        // Use Direct Storage API for asset loading
        const path = std.mem.span(params.path);
        console.printf("Gaming load asset: {}\\n", .{path});
        
        // Mock asset loading
        return @intCast(params.size);
    }
    
    fn sys_gaming_stream_asset(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const params_ptr = @as(*const GamingAssetParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        console.printf("Gaming stream asset: streaming mode\\n");
        _ = params;
        return 0;
    }
    
    fn sys_gaming_preload_assets(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const asset_list = @as([*]GamingAssetParams, @ptrFromInt(args[0]));
        const count = args[1];
        
        console.printf("Gaming preload: {} assets\\n", .{count});
        _ = asset_list;
        return @intCast(count);
    }
    
    // Synchronization
    fn sys_gaming_futex(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const futex_addr = @as(*u32, @ptrFromInt(args[0]));
        const op = @as(u32, @intCast(args[1]));
        const val = @as(u32, @intCast(args[2]));
        const timeout_ns = if (args[3] != 0) @as(u64, args[3]) else null;
        const val2 = @as(u32, @intCast(args[4]));
        const val3 = @as(u32, @intCast(args[5]));
        
        return gaming_futex.sys_gaming_futex(futex_addr, op, val, timeout_ns, val2, val3);
    }
    
    fn sys_gaming_mutex_lock(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const mutex_addr = @as(*u32, @ptrFromInt(args[0]));
        const timeout_ns = if (args[1] != 0) @as(u64, args[1]) else null;
        
        // Fast mutex lock for gaming
        if (@cmpxchgWeak(u32, mutex_addr, 0, 1, .Acquire, .Monotonic) == null) {
            return 0; // Fast path: acquired immediately
        }
        
        // Slow path: use gaming FUTEX
        return gaming_futex.sys_gaming_futex(mutex_addr, @intFromEnum(gaming_futex.GamingFutexOp.gaming_wait), 1, timeout_ns, 0, 0);
    }
    
    fn sys_gaming_cond_wait(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const cond_addr = @as(*u32, @ptrFromInt(args[0]));
        const mutex_addr = @as(*u32, @ptrFromInt(args[1]));
        
        // Gaming condition variable wait
        console.writeString("Gaming cond wait\\n");
        _ = cond_addr;
        _ = mutex_addr;
        return 0;
    }
    
    fn sys_gaming_barrier_wait(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const barrier_addr = @as(*u32, @ptrFromInt(args[0]));
        
        console.writeString("Gaming barrier wait\\n");
        _ = barrier_addr;
        return 0;
    }
    
    // Scheduling
    fn sys_gaming_sched_boost(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        const params_ptr = @as(*const GamingSchedParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        // Apply gaming priority boost
        const current_task = sched.getCurrentTask();
        if (params.pid == 0 or params.pid == current_task.pid) {
            current_task.priority = @max(-20, current_task.priority - params.priority_boost);
            
            if (params.gaming_flags.frame_critical) {
                current_task.frame_critical = true;
            }
            
            self.stats.gaming_boosts_applied += 1;
            console.printf("Gaming sched boost: PID {} priority -> {}\\n", .{ current_task.pid, current_task.priority });
        }
        
        return 0;
    }
    
    fn sys_gaming_sched_frame(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const frame_number = args[0];
        const frame_time_ns = args[1];
        
        // Mark frame boundary for VRR sync
        const current_task = sched.getCurrentTask();
        current_task.vrr_sync = true;
        
        console.printf("Gaming frame boundary: #{} ({}ns)\\n", .{ frame_number, frame_time_ns });
        return 0;
    }
    
    fn sys_gaming_sched_yield(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        _ = args;
        
        // Gaming-aware yield
        try sched.yield();
        return 0;
    }
    
    fn sys_gaming_set_affinity(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        const params_ptr = @as(*const GamingSchedParams, @ptrFromInt(args[0]));
        const params = params_ptr.*;
        
        console.printf("Gaming set affinity: PID {} mask 0x{X}\\n", .{ params.pid, params.affinity_mask });
        _ = self;
        return 0;
    }
    
    // Time operations
    fn sys_gaming_nanosleep(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const nanoseconds = args[0];
        
        // High-precision gaming sleep
        console.printf("Gaming nanosleep: {}ns\\n", .{nanoseconds});
        std.time.sleep(nanoseconds);
        return 0;
    }
    
    fn sys_gaming_get_time(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const time_ptr = @as(*u64, @ptrFromInt(args[0]));
        
        // Fast time retrieval
        time_ptr.* = @intCast(std.time.nanoTimestamp());
        return 0;
    }
    
    fn sys_gaming_set_timer(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const timer_ns = args[0];
        const callback_addr = args[1];
        
        console.printf("Gaming timer: {}ns callback at 0x{X}\\n", .{ timer_ns, callback_addr });
        return 0;
    }
    
    // GPU operations
    fn sys_gaming_gpu_submit(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const command_buffer = @as([*]u8, @ptrFromInt(args[0]));
        const size = args[1];
        const priority = args[2];
        
        console.printf("Gaming GPU submit: {} bytes (priority {})\\n", .{ size, priority });
        _ = command_buffer;
        return 0;
    }
    
    fn sys_gaming_gpu_sync(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const fence_id = args[0];
        const timeout_ns = args[1];
        
        console.printf("Gaming GPU sync: fence {} (timeout {}ns)\\n", .{ fence_id, timeout_ns });
        return 0;
    }
    
    fn sys_gaming_gpu_memory(self: *GamingSyscallHandler, args: [6]u64) !i64 {
        _ = self;
        const operation = args[0]; // 0=alloc, 1=free, 2=map
        const size = args[1];
        const flags = args[2];
        
        console.printf("Gaming GPU memory: op {} size {} flags 0x{X}\\n", .{ operation, size, flags });
        return 0x80000000; // Mock GPU memory address
    }
    
    pub fn getStats(self: *GamingSyscallHandler) GamingSyscallStats {
        return self.stats;
    }
};

// Global gaming syscall handler
var global_gaming_syscall_handler: ?*GamingSyscallHandler = null;

/// Initialize gaming system calls
pub fn initGamingSyscalls(allocator: std.mem.Allocator) !void {
    const handler = try allocator.create(GamingSyscallHandler);
    handler.* = GamingSyscallHandler{
        .stats = GamingSyscallStats{},
    };
    
    global_gaming_syscall_handler = handler;
    console.writeString("Gaming system calls initialized\\n");
}

pub fn getGamingSyscallHandler() *GamingSyscallHandler {
    return global_gaming_syscall_handler.?;
}

/// Main system call entry point for gaming syscalls
pub fn handleGamingSyscall(syscall_num: u64, args: [6]u64) !i64 {
    const handler = getGamingSyscallHandler();
    return handler.handleSyscall(syscall_num, args);
}