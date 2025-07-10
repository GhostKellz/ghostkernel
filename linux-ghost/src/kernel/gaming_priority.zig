//! Gaming Process Priority Inheritance System
//! Ensures gaming processes and their dependencies maintain high priority
//! Features dynamic priority adjustment, dependency tracking, and real-time guarantees

const std = @import("std");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const console = @import("../arch/x86_64/console.zig");

/// Gaming priority levels
pub const GamingPriority = enum(i8) {
    critical = -20,        // Frame-critical rendering tasks
    high = -15,           // Main game loop, input handling
    normal = -10,         // Game logic, AI processing  
    background = -5,      // Asset loading, non-critical game tasks
    system_support = 0,   // System services supporting games
    
    pub fn toNiceValue(self: GamingPriority) i8 {
        return @intFromEnum(self);
    }
    
    pub fn fromTaskType(task: *sched.Task) GamingPriority {
        if (task.frame_critical) return .critical;
        if (task.input_task) return .high;
        if (task.audio_task) return .high;
        if (task.gaming_task) return .normal;
        return .system_support;
    }
};

/// Gaming dependency types
pub const DependencyType = enum {
    direct,           // Direct dependency (parent-child)
    lock,            // Lock/synchronization dependency
    ipc,             // IPC/shared memory dependency
    filesystem,      // Filesystem dependency
    network,         // Network dependency
    gpu,             // GPU command dependency
    audio,           // Audio pipeline dependency
};

/// Priority inheritance tracking
const PriorityInheritance = struct {
    original_priority: i8,
    inherited_priority: i8,
    inheritance_count: u32,
    inheritance_chain: std.ArrayList(u32), // PIDs in inheritance chain
    last_update: u64,
    
    pub fn init(allocator: std.mem.Allocator, original: i8) PriorityInheritance {
        return PriorityInheritance{
            .original_priority = original,
            .inherited_priority = original,
            .inheritance_count = 0,
            .inheritance_chain = std.ArrayList(u32).init(allocator),
            .last_update = @intCast(std.time.nanoTimestamp()),
        };
    }
    
    pub fn deinit(self: *PriorityInheritance) void {
        self.inheritance_chain.deinit();
    }
    
    pub fn addInheritance(self: *PriorityInheritance, from_pid: u32, priority: i8) !void {
        if (priority < self.inherited_priority) {
            self.inherited_priority = priority;
            try self.inheritance_chain.append(from_pid);
            self.inheritance_count += 1;
            self.last_update = @intCast(std.time.nanoTimestamp());
        }
    }
    
    pub fn removeInheritance(self: *PriorityInheritance, from_pid: u32) void {
        // Remove from chain and recalculate inherited priority
        for (self.inheritance_chain.items, 0..) |pid, i| {
            if (pid == from_pid) {
                _ = self.inheritance_chain.orderedRemove(i);
                self.inheritance_count -= 1;
                break;
            }
        }
        
        // Recalculate inherited priority
        self.inherited_priority = self.original_priority;
        for (self.inheritance_chain.items) |_| {
            // In real implementation, look up priority of each PID
            // For now, assume inherited priority is better than original
            if (self.inherited_priority > -15) {
                self.inherited_priority = -15;
            }
        }
        
        self.last_update = @intCast(std.time.nanoTimestamp());
    }
    
    pub fn getEffectivePriority(self: *const PriorityInheritance) i8 {
        return self.inherited_priority;
    }
    
    pub fn hasInheritance(self: *const PriorityInheritance) bool {
        return self.inheritance_count > 0;
    }
};

/// Gaming dependency tracking
const GamingDependency = struct {
    dependent_pid: u32,        // Process that depends on another
    dependency_pid: u32,       // Process being depended upon
    dependency_type: DependencyType,
    strength: f32,             // Dependency strength (0.0-1.0)
    created_time: u64,
    last_accessed: u64,
    active: bool,
    
    pub fn init(dependent: u32, dependency: u32, dep_type: DependencyType, strength: f32) GamingDependency {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return GamingDependency{
            .dependent_pid = dependent,
            .dependency_pid = dependency,
            .dependency_type = dep_type,
            .strength = strength,
            .created_time = now,
            .last_accessed = now,
            .active = true,
        };
    }
    
    pub fn updateAccess(self: *GamingDependency) void {
        self.last_accessed = @intCast(std.time.nanoTimestamp());
    }
    
    pub fn isStale(self: *const GamingDependency) bool {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const age = now - self.last_accessed;
        return age > 5_000_000_000; // 5 seconds without access
    }
    
    pub fn getInheritancePriority(self: *const GamingDependency, base_priority: i8) i8 {
        // Calculate priority to inherit based on dependency strength and type
        const priority_boost = switch (self.dependency_type) {
            .direct => 0,      // Full inheritance
            .lock => 1,        // Near-full inheritance
            .ipc => 2,         // Moderate inheritance
            .gpu => 0,         // Full inheritance for GPU deps
            .audio => 1,       // Near-full inheritance for audio
            .filesystem => 3,  // Reduced inheritance
            .network => 4,     // Minimal inheritance
        };
        
        const strength_factor = @as(i8, @intFromFloat(self.strength * 2.0));
        return std.math.clamp(base_priority + priority_boost + strength_factor, -20, 19);
    }
};

/// Gaming process information
const GamingProcess = struct {
    pid: u32,
    priority_inheritance: PriorityInheritance,
    gaming_priority: GamingPriority,
    is_frame_critical: bool,
    is_audio_critical: bool,
    is_input_critical: bool,
    dependencies: std.ArrayList(GamingDependency),
    dependents: std.ArrayList(u32), // PIDs that depend on this process
    last_frame_time: u64,
    target_fps: u32,
    priority_violations: u32,
    
    pub fn init(allocator: std.mem.Allocator, pid: u32, task: *sched.Task) GamingProcess {
        const gaming_prio = GamingPriority.fromTaskType(task);
        return GamingProcess{
            .pid = pid,
            .priority_inheritance = PriorityInheritance.init(allocator, task.priority),
            .gaming_priority = gaming_prio,
            .is_frame_critical = task.frame_critical,
            .is_audio_critical = task.audio_task,
            .is_input_critical = task.input_task,
            .dependencies = std.ArrayList(GamingDependency).init(allocator),
            .dependents = std.ArrayList(u32).init(allocator),
            .last_frame_time = @intCast(std.time.nanoTimestamp()),
            .target_fps = if (task.gaming_task) 120 else 60,
            .priority_violations = 0,
        };
    }
    
    pub fn deinit(self: *GamingProcess) void {
        self.priority_inheritance.deinit();
        self.dependencies.deinit();
        self.dependents.deinit();
    }
    
    pub fn addDependency(self: *GamingProcess, dependency: GamingDependency) !void {
        try self.dependencies.append(dependency);
    }
    
    pub fn removeDependency(self: *GamingProcess, dependency_pid: u32) void {
        for (self.dependencies.items, 0..) |dep, i| {
            if (dep.dependency_pid == dependency_pid) {
                _ = self.dependencies.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn addDependent(self: *GamingProcess, dependent_pid: u32) !void {
        try self.dependents.append(dependent_pid);
    }
    
    pub fn removeDependent(self: *GamingProcess, dependent_pid: u32) void {
        for (self.dependents.items, 0..) |dep_pid, i| {
            if (dep_pid == dependent_pid) {
                _ = self.dependents.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn getEffectivePriority(self: *const GamingProcess) i8 {
        const base_priority = self.gaming_priority.toNiceValue();
        const inherited_priority = self.priority_inheritance.getEffectivePriority();
        return @min(base_priority, inherited_priority);
    }
    
    pub fn updateFrameTime(self: *GamingProcess) void {
        self.last_frame_time = @intCast(std.time.nanoTimestamp());
    }
    
    pub fn isFrameDeadlineMissed(self: *const GamingProcess) bool {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const frame_time_ns = 1_000_000_000 / self.target_fps;
        return (now - self.last_frame_time) > frame_time_ns;
    }
};

/// Gaming Priority Manager
pub const GamingPriorityManager = struct {
    allocator: std.mem.Allocator,
    gaming_processes: std.HashMap(u32, GamingProcess),
    dependency_graph: std.HashMap(u64, GamingDependency), // Hash of (dependent_pid, dependency_pid)
    priority_monitor: PriorityMonitor,
    
    // Configuration
    enable_dynamic_priority: bool,
    enable_dependency_tracking: bool,
    enable_frame_deadline_monitoring: bool,
    priority_boost_threshold: u64, // ns
    
    const PriorityMonitor = struct {
        monitoring_enabled: bool = true,
        check_interval_ns: u64 = 16_666_667, // ~60Hz monitoring
        last_check: u64 = 0,
        violations_detected: u64 = 0,
        
        pub fn shouldCheck(self: *PriorityMonitor) bool {
            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now - self.last_check >= self.check_interval_ns) {
                self.last_check = now;
                return true;
            }
            return false;
        }
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .gaming_processes = std.HashMap(u32, GamingProcess).init(allocator),
            .dependency_graph = std.HashMap(u64, GamingDependency).init(allocator),
            .priority_monitor = PriorityMonitor{},
            .enable_dynamic_priority = true,
            .enable_dependency_tracking = true,
            .enable_frame_deadline_monitoring = true,
            .priority_boost_threshold = 1_000_000, // 1ms
        };
    }
    
    pub fn deinit(self: *Self) void {
        var process_iter = self.gaming_processes.iterator();
        while (process_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.gaming_processes.deinit();
        self.dependency_graph.deinit();
    }
    
    /// Register a gaming process
    pub fn registerGamingProcess(self: *Self, task: *sched.Task) !void {
        const gaming_process = GamingProcess.init(self.allocator, task.pid, task);
        try self.gaming_processes.put(task.pid, gaming_process);
        
        // Apply initial gaming priority
        self.applyGamingPriority(task);
        
        console.printf("Registered gaming process PID {} with priority {}\n", 
            .{ task.pid, gaming_process.getEffectivePriority() });
    }
    
    /// Unregister a gaming process
    pub fn unregisterGamingProcess(self: *Self, pid: u32) void {
        if (self.gaming_processes.getPtr(pid)) |process| {
            // Remove all dependencies involving this process
            self.removeDependenciesForProcess(pid);
            
            process.deinit();
            _ = self.gaming_processes.remove(pid);
            
            console.printf("Unregistered gaming process PID {}\n", .{pid});
        }
    }
    
    /// Add dependency between processes
    pub fn addDependency(self: *Self, dependent_pid: u32, dependency_pid: u32, dep_type: DependencyType, strength: f32) !void {
        const dependency = GamingDependency.init(dependent_pid, dependency_pid, dep_type, strength);
        const key = self.makeDependencyKey(dependent_pid, dependency_pid);
        
        try self.dependency_graph.put(key, dependency);
        
        // Update process structures
        if (self.gaming_processes.getPtr(dependent_pid)) |dependent_process| {
            try dependent_process.addDependency(dependency);
        }
        
        if (self.gaming_processes.getPtr(dependency_pid)) |dependency_process| {
            try dependency_process.addDependent(dependent_pid);
        }
        
        // Propagate priority inheritance
        try self.propagatePriorityInheritance(dependent_pid, dependency_pid, dep_type, strength);
        
        console.printf("Added dependency: PID {} depends on PID {} (type: {s})\n", 
            .{ dependent_pid, dependency_pid, @tagName(dep_type) });
    }
    
    /// Remove dependency between processes
    pub fn removeDependency(self: *Self, dependent_pid: u32, dependency_pid: u32) void {
        const key = self.makeDependencyKey(dependent_pid, dependency_pid);
        
        if (self.dependency_graph.remove(key)) {
            // Update process structures
            if (self.gaming_processes.getPtr(dependent_pid)) |dependent_process| {
                dependent_process.removeDependency(dependency_pid);
            }
            
            if (self.gaming_processes.getPtr(dependency_pid)) |dependency_process| {
                dependency_process.removeDependent(dependent_pid);
                
                // Remove priority inheritance
                dependency_process.priority_inheritance.removeInheritance(dependent_pid);
            }
            
            console.printf("Removed dependency: PID {} no longer depends on PID {}\n", 
                .{ dependent_pid, dependency_pid });
        }
    }
    
    /// Update task priority based on gaming requirements
    pub fn updateTaskPriority(self: *Self, task: *sched.Task) !void {
        if (self.gaming_processes.getPtr(task.pid)) |gaming_process| {
            const new_priority = gaming_process.getEffectivePriority();
            
            if (task.priority != new_priority) {
                const old_priority = task.priority;
                task.priority = new_priority;
                
                console.printf("Updated PID {} priority: {} -> {}\n", 
                    .{ task.pid, old_priority, new_priority });
            }
        }
    }
    
    /// Monitor and adjust priorities
    pub fn monitorPriorities(self: *Self) !void {
        if (!self.priority_monitor.shouldCheck()) return;
        
        var process_iter = self.gaming_processes.iterator();
        while (process_iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            const process = entry.value_ptr;
            
            // Check for frame deadline misses
            if (self.enable_frame_deadline_monitoring and process.is_frame_critical) {
                if (process.isFrameDeadlineMissed()) {
                    try self.handleFrameDeadlineMiss(pid, process);
                }
            }
            
            // Clean up stale dependencies
            if (self.enable_dependency_tracking) {
                self.cleanupStaleDependencies(process);
            }
            
            // Dynamic priority adjustment
            if (self.enable_dynamic_priority) {
                try self.adjustDynamicPriority(pid, process);
            }
        }
    }
    
    fn propagatePriorityInheritance(self: *Self, dependent_pid: u32, dependency_pid: u32, dep_type: DependencyType, strength: f32) !void {
        _ = dep_type;
        _ = strength;
        const dependent_process = self.gaming_processes.get(dependent_pid) orelse return;
        const dependency_process = self.gaming_processes.getPtr(dependency_pid) orelse return;
        
        // Calculate inherited priority
        const base_priority = dependent_process.getEffectivePriority();
        const dependency_key = self.makeDependencyKey(dependent_pid, dependency_pid);
        const dependency = self.dependency_graph.get(dependency_key) orelse return;
        
        const inherited_priority = dependency.getInheritancePriority(base_priority);
        
        // Apply inheritance
        try dependency_process.priority_inheritance.addInheritance(dependent_pid, inherited_priority);
        
        console.printf("Priority inheritance: PID {} inherits priority {} from PID {}\n", 
            .{ dependency_pid, inherited_priority, dependent_pid });
    }
    
    fn handleFrameDeadlineMiss(self: *Self, pid: u32, process: *GamingProcess) !void {
        _ = self;
        
        process.priority_violations += 1;
        console.printf("Frame deadline miss for PID {} (violations: {})\n", 
            .{ pid, process.priority_violations });
        
        // Emergency priority boost
        if (process.priority_violations > 3) {
            process.priority_inheritance.inherited_priority = @min(-18, process.priority_inheritance.inherited_priority);
            console.printf("Emergency priority boost applied to PID {}\n", .{pid});
        }
    }
    
    fn cleanupStaleDependencies(self: *Self, process: *GamingProcess) void {
        _ = self;
        var i: usize = 0;
        while (i < process.dependencies.items.len) {
            if (process.dependencies.items[i].isStale()) {
                const stale_dep = process.dependencies.orderedRemove(i);
                console.printf("Removed stale dependency: PID {} -> PID {}\n", 
                    .{ process.pid, stale_dep.dependency_pid });
            } else {
                i += 1;
            }
        }
    }
    
    fn adjustDynamicPriority(self: *Self, pid: u32, process: *GamingProcess) !void {
        _ = self;
        _ = pid;
        
        // Dynamic priority adjustment based on behavior
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const time_since_frame = now - process.last_frame_time;
        
        // Boost priority if frame-critical and approaching deadline
        if (process.is_frame_critical and time_since_frame > (1_000_000_000 / process.target_fps) * 3 / 4) {
            process.priority_inheritance.inherited_priority = @min(-16, process.priority_inheritance.inherited_priority);
        }
    }
    
    fn removeDependenciesForProcess(self: *Self, pid: u32) void {
        var keys_to_remove = std.ArrayList(u64).init(self.allocator);
        defer keys_to_remove.deinit();
        
        var iter = self.dependency_graph.iterator();
        while (iter.next()) |entry| {
            const dependency = entry.value_ptr;
            if (dependency.dependent_pid == pid or dependency.dependency_pid == pid) {
                keys_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }
        
        for (keys_to_remove.items) |key| {
            _ = self.dependency_graph.remove(key);
        }
    }
    
    fn makeDependencyKey(self: *Self, dependent_pid: u32, dependency_pid: u32) u64 {
        _ = self;
        return (@as(u64, dependent_pid) << 32) | dependency_pid;
    }
    
    fn applyGamingPriority(self: *Self, task: *sched.Task) void {
        _ = self;
        
        const gaming_priority = GamingPriority.fromTaskType(task);
        task.priority = gaming_priority.toNiceValue();
        
        // Additional gaming-specific optimizations
        if (task.gaming_task) {
            task.gaming_task = true;
            
            if (task.frame_critical) {
                task.vrr_sync = true;
            }
        }
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.enable_dynamic_priority = true;
        self.enable_dependency_tracking = true;
        self.enable_frame_deadline_monitoring = true;
        self.priority_boost_threshold = 500_000; // 0.5ms for gaming mode
        self.priority_monitor.check_interval_ns = 8_333_333; // 120Hz monitoring
        
        console.writeString("Gaming priority inheritance: Enabled\n");
    }
    
    pub fn getStats(self: *Self) PriorityStats {
        var stats = PriorityStats{};
        
        var iter = self.gaming_processes.iterator();
        while (iter.next()) |entry| {
            const process = entry.value_ptr;
            stats.total_processes += 1;
            stats.total_dependencies += @intCast(process.dependencies.items.len);
            stats.priority_violations += process.priority_violations;
            
            if (process.priority_inheritance.hasInheritance()) {
                stats.processes_with_inheritance += 1;
            }
        }
        
        stats.dependency_graph_size = @intCast(self.dependency_graph.count());
        return stats;
    }
};

/// Priority system statistics
pub const PriorityStats = struct {
    total_processes: u32 = 0,
    processes_with_inheritance: u32 = 0,
    total_dependencies: u32 = 0,
    dependency_graph_size: u32 = 0,
    priority_violations: u32 = 0,
    inheritance_chains_resolved: u64 = 0,
    dynamic_adjustments: u64 = 0,
};

// Global gaming priority manager
var global_priority_manager: ?*GamingPriorityManager = null;

/// Initialize gaming priority inheritance system
pub fn initGamingPriority(allocator: std.mem.Allocator) !void {
    const manager = try allocator.create(GamingPriorityManager);
    manager.* = GamingPriorityManager.init(allocator);
    
    // Enable gaming optimizations
    manager.enableGamingMode();
    
    global_priority_manager = manager;
    
    console.writeString("Gaming priority inheritance system initialized\n");
}

pub fn getGamingPriorityManager() *GamingPriorityManager {
    return global_priority_manager.?;
}

// Export for scheduler integration
pub fn onTaskCreate(task: *sched.Task) !void {
    if (task.gaming_task) {
        const manager = getGamingPriorityManager();
        try manager.registerGamingProcess(task);
    }
}

pub fn onTaskDestroy(pid: u32) void {
    const manager = getGamingPriorityManager();
    manager.unregisterGamingProcess(pid);
}

pub fn onLockAcquire(holder_pid: u32, waiter_pid: u32) !void {
    const manager = getGamingPriorityManager();
    try manager.addDependency(waiter_pid, holder_pid, .lock, 1.0);
}

pub fn onLockRelease(holder_pid: u32, waiter_pid: u32) void {
    const manager = getGamingPriorityManager();
    manager.removeDependency(waiter_pid, holder_pid);
}