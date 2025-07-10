//! Gaming-Optimized FUTEX Implementation
//! Ultra-low latency synchronization primitives for gaming workloads
//! Features priority inheritance, spin-then-sleep, and gaming-aware scheduling

const std = @import("std");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const memory = @import("../mm/memory.zig");
const console = @import("../arch/x86_64/console.zig");

/// FUTEX operations for gaming
pub const GamingFutexOp = enum(u32) {
    wait = 0,              // Standard wait
    wake = 1,              // Standard wake
    requeue = 3,           // Requeue waiters
    gaming_wait = 128,     // Gaming-optimized wait
    gaming_wake = 129,     // Gaming-optimized wake
    frame_sync_wait = 130, // Frame synchronization wait
    frame_sync_wake = 131, // Frame synchronization wake
    audio_wait = 132,      // Audio thread wait
    audio_wake = 133,      // Audio thread wake
    input_wait = 134,      // Input thread wait
    input_wake = 135,      // Input thread wake
};

/// Gaming FUTEX flags
pub const GamingFutexFlags = struct {
    priority_inherit: bool = false,    // Enable priority inheritance
    adaptive_spin: bool = false,       // Adaptive spinning before sleep
    gaming_boost: bool = false,        // Boost for gaming threads
    frame_critical: bool = false,      // Frame-critical synchronization
    audio_critical: bool = false,      // Audio-critical synchronization
    input_critical: bool = false,      // Input-critical synchronization
    no_timeout: bool = false,          // Never timeout (use with caution)
    zero_latency: bool = false,        // Use zero-latency optimizations
};

/// FUTEX statistics for performance monitoring
pub const FutexStats = struct {
    total_operations: u64 = 0,
    gaming_operations: u64 = 0,
    fast_path_hits: u64 = 0,
    spin_successes: u64 = 0,
    priority_inversions: u64 = 0,
    average_wait_time_ns: u64 = 0,
    max_wait_time_ns: u64 = 0,
    frame_sync_operations: u64 = 0,
    
    pub fn update(self: *FutexStats, wait_time_ns: u64, was_gaming: bool, fast_path: bool) void {
        self.total_operations += 1;
        if (was_gaming) self.gaming_operations += 1;
        if (fast_path) self.fast_path_hits += 1;
        
        // Update wait time statistics
        const old_avg = self.average_wait_time_ns;
        self.average_wait_time_ns = (old_avg * (self.total_operations - 1) + wait_time_ns) / self.total_operations;
        
        if (wait_time_ns > self.max_wait_time_ns) {
            self.max_wait_time_ns = wait_time_ns;
        }
    }
};

/// Gaming FUTEX waiter information
const GamingFutexWaiter = struct {
    task: *sched.Task,
    futex_addr: *u32,
    expected_value: u32,
    flags: GamingFutexFlags,
    wait_start_time: u64,
    original_priority: i8,
    boosted_priority: i8,
    is_gaming: bool,
    waiter_type: WaiterType,
    
    const WaiterType = enum {
        normal,
        frame_critical,
        audio_critical,
        input_critical,
        gpu_sync,
    };
    
    pub fn init(task: *sched.Task, futex_addr: *u32, expected_value: u32, flags: GamingFutexFlags) GamingFutexWaiter {
        return GamingFutexWaiter{
            .task = task,
            .futex_addr = futex_addr,
            .expected_value = expected_value,
            .flags = flags,
            .wait_start_time = @intCast(std.time.nanoTimestamp()),
            .original_priority = task.priority,
            .boosted_priority = task.priority,
            .is_gaming = task.gaming_task,
            .waiter_type = detectWaiterType(task, flags),
        };
    }
    
    fn detectWaiterType(task: *sched.Task, flags: GamingFutexFlags) WaiterType {
        if (flags.frame_critical or task.frame_critical) return .frame_critical;
        if (flags.audio_critical or task.audio_task) return .audio_critical;
        if (flags.input_critical or task.input_task) return .input_critical;
        if (task.gaming_task) return .gpu_sync;
        return .normal;
    }
    
    pub fn getPriority(self: *const GamingFutexWaiter) i8 {
        var priority = self.boosted_priority;
        
        // Gaming tasks get priority boost
        if (self.is_gaming) priority -= 5;
        
        // Critical tasks get additional boosts
        switch (self.waiter_type) {
            .frame_critical => priority -= 10,
            .audio_critical => priority -= 8,
            .input_critical => priority -= 6,
            .gpu_sync => priority -= 4,
            .normal => {},
        }
        
        return std.math.clamp(priority, -20, 19);
    }
};

/// Gaming FUTEX hash bucket
const GamingFutexBucket = struct {
    lock: sync.SpinLock,
    waiters: std.ArrayList(GamingFutexWaiter),
    
    pub fn init(allocator: std.mem.Allocator) GamingFutexBucket {
        return GamingFutexBucket{
            .lock = sync.SpinLock.init(),
            .waiters = std.ArrayList(GamingFutexWaiter).init(allocator),
        };
    }
    
    pub fn deinit(self: *GamingFutexBucket) void {
        self.waiters.deinit();
    }
    
    pub fn addWaiter(self: *GamingFutexBucket, waiter: GamingFutexWaiter) !void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Insert waiter in priority order
        var insert_pos: usize = 0;
        const waiter_priority = waiter.getPriority();
        
        for (self.waiters.items, 0..) |existing_waiter, i| {
            if (waiter_priority < existing_waiter.getPriority()) {
                insert_pos = i;
                break;
            }
            insert_pos = i + 1;
        }
        
        try self.waiters.insert(insert_pos, waiter);
    }
    
    pub fn removeWaiter(self: *GamingFutexBucket, task: *sched.Task) ?GamingFutexWaiter {
        self.lock.acquire();
        defer self.lock.release();
        
        for (self.waiters.items, 0..) |waiter, i| {
            if (waiter.task == task) {
                return self.waiters.orderedRemove(i);
            }
        }
        return null;
    }
    
    pub fn wakeWaiters(self: *GamingFutexBucket, futex_addr: *u32, max_wake: u32) u32 {
        self.lock.acquire();
        defer self.lock.release();
        
        var woken: u32 = 0;
        var i: usize = 0;
        
        while (i < self.waiters.items.len and woken < max_wake) {
            if (self.waiters.items[i].futex_addr == futex_addr) {
                const waiter = self.waiters.orderedRemove(i);
                
                // Wake the task
                waiter.task.state = .ready;
                
                // Restore original priority if it was boosted
                if (waiter.boosted_priority != waiter.original_priority) {
                    waiter.task.priority = waiter.original_priority;
                }
                
                woken += 1;
            } else {
                i += 1;
            }
        }
        
        return woken;
    }
};

/// Gaming-optimized FUTEX implementation
pub const GamingFutex = struct {
    allocator: std.mem.Allocator,
    hash_buckets: []GamingFutexBucket,
    bucket_count: u32,
    stats: FutexStats,
    
    // Gaming optimizations
    adaptive_spin_config: AdaptiveSpinConfig,
    priority_inheritance_enabled: bool,
    gaming_boost_enabled: bool,
    
    const AdaptiveSpinConfig = struct {
        base_spin_cycles: u32 = 1000,     // Base spin cycles before sleep
        gaming_spin_cycles: u32 = 5000,   // Enhanced spin for gaming tasks
        frame_critical_cycles: u32 = 10000, // Maximum spin for frame-critical
        adaptive_threshold: u32 = 100,    // Adapt based on success rate
        current_multiplier: f32 = 1.0,    // Current spin multiplier
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const bucket_count = 1024; // Power of 2 for fast hashing
        const buckets = try allocator.alloc(GamingFutexBucket, bucket_count);
        
        for (buckets) |*bucket| {
            bucket.* = GamingFutexBucket.init(allocator);
        }
        
        return Self{
            .allocator = allocator,
            .hash_buckets = buckets,
            .bucket_count = bucket_count,
            .stats = FutexStats{},
            .adaptive_spin_config = AdaptiveSpinConfig{},
            .priority_inheritance_enabled = true,
            .gaming_boost_enabled = true,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.hash_buckets) |*bucket| {
            bucket.deinit();
        }
        self.allocator.free(self.hash_buckets);
    }
    
    /// Main FUTEX operation entry point
    pub fn futexOp(self: *Self, futex_addr: *u32, op: GamingFutexOp, val: u32, timeout_ns: ?u64, val2: u32, val3: u32) !i32 {
        const start_time = std.time.nanoTimestamp();
        const current_task = sched.getCurrentTask();
        
        const result = switch (op) {
            .wait, .gaming_wait => try self.futexWait(futex_addr, val, timeout_ns, createFlags(op)),
            .wake, .gaming_wake => try self.futexWake(futex_addr, val),
            .frame_sync_wait => try self.futexWait(futex_addr, val, timeout_ns, GamingFutexFlags{ .frame_critical = true, .adaptive_spin = true }),
            .frame_sync_wake => try self.futexWake(futex_addr, val),
            .audio_wait => try self.futexWait(futex_addr, val, timeout_ns, GamingFutexFlags{ .audio_critical = true, .adaptive_spin = true }),
            .audio_wake => try self.futexWake(futex_addr, val),
            .input_wait => try self.futexWait(futex_addr, val, timeout_ns, GamingFutexFlags{ .input_critical = true, .adaptive_spin = true }),
            .input_wake => try self.futexWake(futex_addr, val),
            .requeue => try self.futexRequeue(futex_addr, val, val2, @as(*u32, @ptrFromInt(val3))),
        };
        
        // Update statistics
        const end_time = std.time.nanoTimestamp();
        const wait_time = @as(u64, @intCast(end_time - start_time));
        const was_gaming = current_task.gaming_task;
        const fast_path = result >= 0 and wait_time < 1000; // < 1μs is fast path
        
        self.stats.update(wait_time, was_gaming, fast_path);
        
        return result;
    }
    
    fn futexWait(self: *Self, futex_addr: *u32, expected_val: u32, timeout_ns: ?u64, flags: GamingFutexFlags) !i32 {
        const current_task = sched.getCurrentTask();
        
        // Fast path: check if value already changed
        if (@atomicLoad(u32, futex_addr, .Acquire) != expected_val) {
            return -11; // -EAGAIN
        }
        
        // Try adaptive spinning for gaming tasks
        if (flags.adaptive_spin and (current_task.gaming_task or flags.frame_critical)) {
            if (self.tryAdaptiveSpin(futex_addr, expected_val, flags)) {
                self.stats.spin_successes += 1;
                return 0;
            }
        }
        
        // Slow path: add to wait queue
        const bucket = self.getBucket(futex_addr);
        const waiter = GamingFutexWaiter.init(current_task, futex_addr, expected_val, flags);
        
        try bucket.addWaiter(waiter);
        
        // Apply priority inheritance if enabled
        if (flags.priority_inherit and self.priority_inheritance_enabled) {
            self.applyPriorityInheritance(bucket, waiter);
        }
        
        // Block the task
        current_task.state = .blocked;
        
        // Handle timeout
        if (timeout_ns) |timeout| {
            // Set up timeout handling
            _ = timeout;
            // In real implementation, set up timer for wakeup
        }
        
        // Yield to scheduler
        try sched.yield();
        
        // Clean up when woken
        _ = bucket.removeWaiter(current_task);
        
        return 0;
    }
    
    fn futexWake(self: *Self, futex_addr: *u32, max_wake: u32) !i32 {
        const bucket = self.getBucket(futex_addr);
        const woken = bucket.wakeWaiters(futex_addr, max_wake);
        
        // Update frame sync statistics
        if (max_wake == 1) {
            self.stats.frame_sync_operations += 1;
        }
        
        return @intCast(woken);
    }
    
    fn futexRequeue(self: *Self, futex_addr1: *u32, max_wake: u32, max_requeue: u32, futex_addr2: *u32) !i32 {
        _ = self;
        _ = futex_addr1;
        _ = max_wake;
        _ = max_requeue;
        _ = futex_addr2;
        
        // Implementation would requeue waiters from futex_addr1 to futex_addr2
        return 0;
    }
    
    fn tryAdaptiveSpin(self: *Self, futex_addr: *u32, expected_val: u32, flags: GamingFutexFlags) bool {
        var spin_cycles = self.adaptive_spin_config.base_spin_cycles;
        
        // Adjust spin cycles based on task importance
        if (flags.frame_critical) {
            spin_cycles = self.adaptive_spin_config.frame_critical_cycles;
        } else if (flags.gaming_boost) {
            spin_cycles = self.adaptive_spin_config.gaming_spin_cycles;
        }
        
        // Apply adaptive multiplier
        spin_cycles = @as(u32, @intFromFloat(@as(f32, @floatFromInt(spin_cycles)) * self.adaptive_spin_config.current_multiplier));
        
        // Spin and check
        for (0..spin_cycles) |_| {
            // Pause instruction for better performance
            asm volatile ("pause");
            
            if (@atomicLoad(u32, futex_addr, .Acquire) != expected_val) {
                // Success! Update adaptive multiplier
                self.adaptive_spin_config.current_multiplier = @min(2.0, self.adaptive_spin_config.current_multiplier * 1.1);
                return true;
            }
        }
        
        // Failed to acquire in spin, reduce multiplier
        self.adaptive_spin_config.current_multiplier = @max(0.5, self.adaptive_spin_config.current_multiplier * 0.9);
        return false;
    }
    
    fn applyPriorityInheritance(self: *Self, bucket: *GamingFutexBucket, waiter: GamingFutexWaiter) void {
        _ = self;
        _ = bucket;
        
        // Find the current lock holder and boost their priority
        // In real implementation, this would traverse the ownership chain
        
        const boosted_priority = waiter.getPriority();
        waiter.task.priority = boosted_priority;
        
        // Track priority inheritance for statistics
        self.stats.priority_inversions += 1;
    }
    
    fn getBucket(self: *Self, futex_addr: *u32) *GamingFutexBucket {
        const addr_int = @intFromPtr(futex_addr);
        const hash = hashAddress(addr_int);
        const bucket_index = hash & (self.bucket_count - 1);
        return &self.hash_buckets[bucket_index];
    }
    
    fn hashAddress(addr: usize) u32 {
        // Simple hash function for FUTEX addresses
        var hash = @as(u32, @truncate(addr));
        hash ^= hash >> 16;
        hash *= 0x85ebca6b;
        hash ^= hash >> 13;
        hash *= 0xc2b2ae35;
        hash ^= hash >> 16;
        return hash;
    }
    
    fn createFlags(op: GamingFutexOp) GamingFutexFlags {
        return switch (op) {
            .gaming_wait, .gaming_wake => GamingFutexFlags{ .gaming_boost = true, .adaptive_spin = true },
            .frame_sync_wait, .frame_sync_wake => GamingFutexFlags{ .frame_critical = true, .adaptive_spin = true, .priority_inherit = true },
            .audio_wait, .audio_wake => GamingFutexFlags{ .audio_critical = true, .adaptive_spin = true },
            .input_wait, .input_wake => GamingFutexFlags{ .input_critical = true, .adaptive_spin = true },
            else => GamingFutexFlags{},
        };
    }
    
    pub fn enableGamingMode(self: *Self) void {
        // Optimize for gaming workloads
        self.adaptive_spin_config.gaming_spin_cycles = 10000;
        self.adaptive_spin_config.frame_critical_cycles = 20000;
        self.priority_inheritance_enabled = true;
        self.gaming_boost_enabled = true;
        
        console.writeString("Gaming FUTEX optimizations enabled\n");
    }
    
    pub fn getStats(self: *Self) FutexStats {
        return self.stats;
    }
};

/// System call interface for gaming FUTEX
pub fn sys_gaming_futex(futex_addr: *u32, op: u32, val: u32, timeout_ns: ?u64, val2: u32, val3: u32) !i32 {
    const gaming_futex = getGamingFutex();
    const futex_op = @as(GamingFutexOp, @enumFromInt(op));
    
    return gaming_futex.futexOp(futex_addr, futex_op, val, timeout_ns, val2, val3);
}

// Global gaming FUTEX instance
var global_gaming_futex: ?*GamingFutex = null;

pub fn initGamingFutex(allocator: std.mem.Allocator) !void {
    const futex = try allocator.create(GamingFutex);
    futex.* = try GamingFutex.init(allocator);
    
    // Enable gaming optimizations
    futex.enableGamingMode();
    
    global_gaming_futex = futex;
    
    console.writeString("Gaming FUTEX system initialized\n");
}

fn getGamingFutex() *GamingFutex {
    return global_gaming_futex.?;
}

// Export for scheduler integration
pub fn onTaskBlock(task: *sched.Task, futex_addr: *u32) void {
    // Called when a task blocks on a FUTEX
    _ = task;
    _ = futex_addr;
    
    console.writeString("Task blocked on gaming FUTEX\n");
}

pub fn onTaskWake(task: *sched.Task, futex_addr: *u32) void {
    // Called when a task is woken from a FUTEX
    _ = task;
    _ = futex_addr;
    
    console.writeString("Task woken from gaming FUTEX\n");
}