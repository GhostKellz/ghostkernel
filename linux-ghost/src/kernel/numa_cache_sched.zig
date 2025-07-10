//! CPU Cache-Aware NUMA Scheduling for Gaming
//! Optimizes task placement for AMD X3D cache and Intel cache hierarchies
//! Features cache topology awareness, memory affinity, and gaming workload optimization

const std = @import("std");
const sched = @import("sched.zig");
const hybrid_sched = @import("hybrid_sched.zig");
const memory = @import("../mm/memory.zig");
const console = @import("../arch/x86_64/console.zig");

/// NUMA node information
pub const NUMANode = struct {
    node_id: u32,
    memory_size: u64,        // Total memory on this node
    free_memory: u64,        // Available memory on this node
    memory_speed: u32,       // Memory speed in MT/s
    cpu_cores: std.ArrayList(u32), // CPU cores on this node
    cache_info: NUMACacheInfo,
    
    // Gaming optimization metrics
    gaming_tasks: u32,       // Number of gaming tasks on this node
    cache_pressure: f32,     // Cache utilization (0.0-1.0)
    memory_bandwidth_usage: f32, // Memory bandwidth utilization
    last_gaming_activity: u64,   // Last gaming activity timestamp
    
    pub fn init(allocator: std.mem.Allocator, node_id: u32) NUMANode {
        return NUMANode{
            .node_id = node_id,
            .memory_size = 0,
            .free_memory = 0,
            .memory_speed = 3200, // Default DDR4-3200
            .cpu_cores = std.ArrayList(u32).init(allocator),
            .cache_info = NUMACacheInfo{},
            .gaming_tasks = 0,
            .cache_pressure = 0.0,
            .memory_bandwidth_usage = 0.0,
            .last_gaming_activity = 0,
        };
    }
    
    pub fn deinit(self: *NUMANode) void {
        self.cpu_cores.deinit();
    }
    
    pub fn addCPUCore(self: *NUMANode, core_id: u32) !void {
        try self.cpu_cores.append(core_id);
    }
    
    pub fn getGamingScore(self: *const NUMANode) f32 {
        var score: f32 = 100.0;
        
        // Prefer nodes with X3D cache
        if (self.cache_info.has_x3d_cache) score += 50.0;
        
        // Prefer nodes with larger cache
        score += @as(f32, @floatFromInt(self.cache_info.total_cache_mb)) * 0.1;
        
        // Penalize high cache pressure
        score -= self.cache_pressure * 30.0;
        
        // Penalize high memory bandwidth usage
        score -= self.memory_bandwidth_usage * 20.0;
        
        // Prefer nodes with recent gaming activity (locality)
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const time_since_activity = now - self.last_gaming_activity;
        if (time_since_activity < 1_000_000_000) { // < 1 second
            score += 20.0;
        }
        
        return @max(0.0, score);
    }
    
    pub fn updateGamingActivity(self: *NUMANode) void {
        self.last_gaming_activity = @intCast(std.time.nanoTimestamp());
    }
};

/// Cache information for NUMA nodes
const NUMACacheInfo = struct {
    // L1 cache (per core)
    l1_data_size_kb: u32 = 32,      // L1 data cache size
    l1_inst_size_kb: u32 = 32,      // L1 instruction cache size
    
    // L2 cache (per core or shared)
    l2_size_kb: u32 = 512,          // L2 cache size
    l2_shared_cores: u8 = 1,        // Cores sharing L2
    
    // L3 cache (shared)
    l3_size_mb: u32 = 16,           // L3 cache size in MB
    l3_shared_cores: u8 = 8,        // Cores sharing L3
    
    // Special cache features
    has_x3d_cache: bool = false,    // AMD 3D V-Cache
    x3d_cache_size_mb: u32 = 0,     // Additional X3D cache
    has_smart_cache: bool = false,  // Intel Smart Cache
    victim_cache_enabled: bool = false, // Victim cache present
    
    // Cache performance characteristics
    cache_line_size: u8 = 64,       // Cache line size in bytes
    cache_associativity: u8 = 16,   // Cache associativity
    prefetcher_aggressiveness: u8 = 2, // 0=conservative, 3=aggressive
    
    pub fn getTotalCacheMB(self: *const NUMACacheInfo) u32 {
        return self.l3_size_mb + self.x3d_cache_size_mb;
    }
    
    pub fn isGamingOptimal(self: *const NUMACacheInfo) bool {
        // Gaming benefits from large cache and X3D
        return self.has_x3d_cache or self.l3_size_mb >= 32;
    }
    
    pub fn getCacheAffinityScore(self: *const NUMACacheInfo, workload_type: WorkloadCacheProfile) f32 {
        return switch (workload_type) {
            .cache_intensive => {
                var score: f32 = @as(f32, @floatFromInt(self.getTotalCacheMB()));
                if (self.has_x3d_cache) score *= 1.5;
                return score;
            },
            .memory_intensive => {
                // Memory-intensive workloads benefit less from large cache
                return @as(f32, @floatFromInt(self.l3_size_mb)) * 0.5;
            },
            .latency_sensitive => {
                // Latency-sensitive prefers smaller, faster cache
                var score: f32 = 50.0;
                if (self.l1_data_size_kb >= 32) score += 10.0;
                if (self.has_x3d_cache) score += 15.0; // X3D is still beneficial
                return score;
            },
            .balanced => {
                return @as(f32, @floatFromInt(self.getTotalCacheMB())) * 0.8;
            },
        };
    }
    
    total_cache_mb: u32 = 0, // Added field for compatibility
};

/// Workload cache profile for optimization
const WorkloadCacheProfile = enum {
    cache_intensive,     // Benefits heavily from large cache (game worlds, AI)
    memory_intensive,    // High memory bandwidth needs (streaming, decompression)
    latency_sensitive,   // Low latency critical (input, audio)
    balanced,           // Mixed workload
    
    pub fn fromTask(task: *sched.Task) WorkloadCacheProfile {
        if (task.input_task or task.audio_task) return .latency_sensitive;
        if (task.frame_critical) return .cache_intensive;
        if (task.gaming_task) return .cache_intensive;
        return .balanced;
    }
};

/// CPU cache topology
pub const CacheTopology = struct {
    cpu_id: u32,
    numa_node: u32,
    cache_info: hybrid_sched.CacheInfo,
    
    // Cache sharing relationships
    l1_shared_with: std.ArrayList(u32), // CPUs sharing L1 (usually just self)
    l2_shared_with: std.ArrayList(u32), // CPUs sharing L2
    l3_shared_with: std.ArrayList(u32), // CPUs sharing L3
    
    // Performance characteristics
    cache_latency_cycles: [3]u16,       // L1, L2, L3 latency in cycles
    memory_latency_ns: u16,             // Main memory latency
    cache_bandwidth_gbps: [3]f32,       // L1, L2, L3 bandwidth
    
    pub fn init(allocator: std.mem.Allocator, cpu_id: u32, numa_node: u32) CacheTopology {
        return CacheTopology{
            .cpu_id = cpu_id,
            .numa_node = numa_node,
            .cache_info = hybrid_sched.CacheInfo{},
            .l1_shared_with = std.ArrayList(u32).init(allocator),
            .l2_shared_with = std.ArrayList(u32).init(allocator),
            .l3_shared_with = std.ArrayList(u32).init(allocator),
            .cache_latency_cycles = .{ 4, 12, 40 }, // Typical latencies
            .memory_latency_ns = 100,               // ~100ns to main memory
            .cache_bandwidth_gbps = .{ 1000.0, 500.0, 200.0 }, // Rough estimates
        };
    }
    
    pub fn deinit(self: *CacheTopology) void {
        self.l1_shared_with.deinit();
        self.l2_shared_with.deinit();
        self.l3_shared_with.deinit();
    }
    
    pub fn sharesCache(self: *const CacheTopology, other_cpu: u32, cache_level: u8) bool {
        return switch (cache_level) {
            1 => self.containsCPU(self.l1_shared_with.items, other_cpu),
            2 => self.containsCPU(self.l2_shared_with.items, other_cpu),
            3 => self.containsCPU(self.l3_shared_with.items, other_cpu),
            else => false,
        };
    }
    
    fn containsCPU(self: *const CacheTopology, cpu_list: []const u32, cpu_id: u32) bool {
        _ = self;
        for (cpu_list) |cpu| {
            if (cpu == cpu_id) return true;
        }
        return false;
    }
    
    pub fn getCacheAffinityWith(self: *const CacheTopology, other: *const CacheTopology) f32 {
        var affinity: f32 = 0.0;
        
        // Same NUMA node is best
        if (self.numa_node == other.numa_node) affinity += 100.0;
        
        // Shared caches provide affinity
        if (self.sharesCache(other.cpu_id, 3)) affinity += 50.0;
        if (self.sharesCache(other.cpu_id, 2)) affinity += 30.0;
        if (self.sharesCache(other.cpu_id, 1)) affinity += 20.0;
        
        return affinity;
    }
};

/// NUMA-aware cache scheduler
pub const NUMACacheScheduler = struct {
    allocator: std.mem.Allocator,
    numa_nodes: std.ArrayList(NUMANode),
    cache_topology: std.HashMap(u32, CacheTopology), // CPU ID -> topology
    
    // Task placement tracking
    task_placements: std.HashMap(u32, TaskPlacement), // PID -> placement
    cache_usage: std.HashMap(u64, CacheUsage),        // Cache ID -> usage
    
    // Gaming optimizations
    gaming_preferred_nodes: std.ArrayList(u32),       // Preferred NUMA nodes for gaming
    cache_warming_enabled: bool,                       // Enable cache warming
    migration_hysteresis: f32,                        // Prevent task ping-ponging
    
    // Performance monitoring
    scheduler_stats: NUMASchedulerStats,
    
    const TaskPlacement = struct {
        current_numa_node: u32,
        current_cpu: u32,
        last_migration: u64,
        migration_count: u32,
        cache_misses: u64,
        memory_accesses: u64,
        workload_profile: WorkloadCacheProfile,
        
        pub fn getCacheMissRate(self: *const TaskPlacement) f32 {
            if (self.memory_accesses == 0) return 0.0;
            return @as(f32, @floatFromInt(self.cache_misses)) / @as(f32, @floatFromInt(self.memory_accesses));
        }
        
        pub fn shouldConsiderMigration(self: *const TaskPlacement) bool {
            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            const time_since_migration = now - self.last_migration;
            
            // Don't migrate too frequently
            return time_since_migration > 10_000_000_000; // 10 seconds
        }
    };
    
    const CacheUsage = struct {
        cache_id: u64,
        utilization: f32,      // 0.0 - 1.0
        gaming_tasks: u32,     // Number of gaming tasks using this cache
        last_updated: u64,
        
        pub fn addGamingTask(self: *CacheUsage) void {
            self.gaming_tasks += 1;
            self.last_updated = @intCast(std.time.nanoTimestamp());
        }
        
        pub fn removeGamingTask(self: *CacheUsage) void {
            if (self.gaming_tasks > 0) {
                self.gaming_tasks -= 1;
            }
            self.last_updated = @intCast(std.time.nanoTimestamp());
        }
    };
    
    const NUMASchedulerStats = struct {
        total_migrations: u64 = 0,
        gaming_task_migrations: u64 = 0,
        cache_miss_improvements: u64 = 0,
        numa_violations: u64 = 0,
        optimal_placements: u64 = 0,
        
        pub fn recordMigration(self: *NUMASchedulerStats, was_gaming: bool, improved_cache: bool) void {
            self.total_migrations += 1;
            if (was_gaming) self.gaming_task_migrations += 1;
            if (improved_cache) self.cache_miss_improvements += 1;
        }
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .numa_nodes = std.ArrayList(NUMANode).init(allocator),
            .cache_topology = std.HashMap(u32, CacheTopology).init(allocator),
            .task_placements = std.HashMap(u32, TaskPlacement).init(allocator),
            .cache_usage = std.HashMap(u64, CacheUsage).init(allocator),
            .gaming_preferred_nodes = std.ArrayList(u32).init(allocator),
            .cache_warming_enabled = true,
            .migration_hysteresis = 0.2, // 20% improvement needed to migrate
            .scheduler_stats = NUMASchedulerStats{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.numa_nodes.items) |*node| {
            node.deinit();
        }
        self.numa_nodes.deinit();
        
        var topo_iter = self.cache_topology.iterator();
        while (topo_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.cache_topology.deinit();
        
        self.task_placements.deinit();
        self.cache_usage.deinit();
        self.gaming_preferred_nodes.deinit();
    }
    
    /// Discover system NUMA topology
    pub fn discoverTopology(self: *Self) !void {
        // Discover NUMA nodes (mock implementation)
        for (0..2) |node_id| { // Assume 2 NUMA nodes
            var numa_node = NUMANode.init(self.allocator, @intCast(node_id));
            numa_node.memory_size = 32 * 1024 * 1024 * 1024; // 32GB per node
            numa_node.free_memory = numa_node.memory_size;
            
            // Configure cache info based on node
            if (node_id == 0) {
                // Node 0: AMD X3D configuration
                numa_node.cache_info.has_x3d_cache = true;
                numa_node.cache_info.x3d_cache_size_mb = 96; // 96MB X3D cache
                numa_node.cache_info.l3_size_mb = 32;
                try self.gaming_preferred_nodes.append(@intCast(node_id));
            } else {
                // Node 1: Standard configuration
                numa_node.cache_info.l3_size_mb = 16;
            }
            
            // Add CPU cores to node
            const cores_per_node = 8;
            for (0..cores_per_node) |core_offset| {
                const cpu_id = @as(u32, @intCast(node_id * cores_per_node + core_offset));
                try numa_node.addCPUCore(cpu_id);
                
                // Create cache topology for each CPU
                var cache_topo = CacheTopology.init(self.allocator, cpu_id, @intCast(node_id));
                cache_topo.cache_info = numa_node.cache_info;
                
                try self.cache_topology.put(cpu_id, cache_topo);
            }
            
            try self.numa_nodes.append(numa_node);
        }
        
        console.printf("NUMA topology discovered: {} nodes, {} CPUs\n", 
            .{ self.numa_nodes.items.len, self.cache_topology.count() });
    }
    
    /// Find optimal CPU for a task
    pub fn findOptimalCPU(self: *Self, task: *sched.Task) u32 {
        const workload_profile = WorkloadCacheProfile.fromTask(task);
        
        var best_cpu: u32 = 0;
        var best_score: f32 = 0.0;
        
        // Evaluate each CPU
        var topo_iter = self.cache_topology.iterator();
        while (topo_iter.next()) |entry| {
            const cpu_id = entry.key_ptr.*;
            const topology = entry.value_ptr;
            
            const score = self.calculateCPUScore(cpu_id, topology, task, workload_profile);
            
            if (score > best_score) {
                best_score = score;
                best_cpu = cpu_id;
            }
        }
        
        console.printf("NUMA scheduler: Selected CPU {} for PID {} (score: {d:.1})\n", 
            .{ best_cpu, task.pid, best_score });
        
        return best_cpu;
    }
    
    fn calculateCPUScore(self: *Self, cpu_id: u32, topology: *const CacheTopology, task: *sched.Task, workload_profile: WorkloadCacheProfile) f32 {
        var score: f32 = 100.0;
        
        // Get NUMA node for this CPU
        const numa_node = &self.numa_nodes.items[topology.numa_node];
        
        // Gaming tasks prefer gaming-optimal nodes
        if (task.gaming_task) {
            if (numa_node.cache_info.isGamingOptimal()) {
                score += 50.0;
            }
            
            // Prefer nodes with fewer gaming tasks (load balancing)
            score -= @as(f32, @floatFromInt(numa_node.gaming_tasks)) * 5.0;
        }
        
        // Cache affinity scoring
        const cache_score = numa_node.cache_info.getCacheAffinityScore(workload_profile);
        score += cache_score * 0.3;
        
        // Memory pressure penalty
        const memory_pressure = 1.0 - (numa_node.free_memory / numa_node.memory_size);
        score -= memory_pressure * 20.0;
        
        // Cache pressure penalty
        score -= numa_node.cache_pressure * 15.0;
        
        // Current task affinity
        if (self.task_placements.get(task.pid)) |placement| {
            if (placement.current_numa_node == topology.numa_node) {
                score += 10.0; // Prefer current node for stability
            }
            
            // Apply migration hysteresis
            if (placement.current_cpu != cpu_id) {
                score *= (1.0 - self.migration_hysteresis);
            }
        }
        
        return score;
    }
    
    /// Place task on optimal CPU
    pub fn placeTask(self: *Self, task: *sched.Task) !void {
        const optimal_cpu = self.findOptimalCPU(task);
        const topology = self.cache_topology.get(optimal_cpu).?;
        
        // Update task placement tracking
        const placement = TaskPlacement{
            .current_numa_node = topology.numa_node,
            .current_cpu = optimal_cpu,
            .last_migration = @intCast(std.time.nanoTimestamp()),
            .migration_count = 0,
            .cache_misses = 0,
            .memory_accesses = 0,
            .workload_profile = WorkloadCacheProfile.fromTask(task),
        };
        
        try self.task_placements.put(task.pid, placement);
        
        // Update NUMA node statistics
        var numa_node = &self.numa_nodes.items[topology.numa_node];
        if (task.gaming_task) {
            numa_node.gaming_tasks += 1;
            numa_node.updateGamingActivity();
        }
        
        // Assign task to CPU (in real implementation, this would call scheduler)
        task.preferred_cpu = optimal_cpu;
        
        console.printf("NUMA scheduler: Placed PID {} on CPU {} (NUMA node {})\n", 
            .{ task.pid, optimal_cpu, topology.numa_node });
    }
    
    /// Monitor and potentially migrate tasks
    pub fn monitorAndMigrate(self: *Self) !void {
        var placement_iter = self.task_placements.iterator();
        
        while (placement_iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            const placement = entry.value_ptr;
            
            if (!placement.shouldConsiderMigration()) continue;
            
            // Get current task (mock - in real implementation, look up by PID)
            var mock_task = sched.Task{
                .pid = pid,
                .state = .running,
                .sched_class = .normal,
                .priority = 0,
                .vruntime = 0,
                .deadline = 0,
                .slice = 0,
                .lag = 0,
                .burst_time = 0,
                .burst_score = 0,
                .prev_burst = 0,
                .bore_penalty = 0,
                .gaming_task = true, // Assume gaming for demo
                .frame_critical = false,
                .input_task = false,
                .audio_task = false,
                .vrr_sync = false,
                .preferred_cpu = placement.current_cpu,
            };
            
            // Check if migration would be beneficial
            const current_score = self.calculateCPUScore(
                placement.current_cpu,
                &self.cache_topology.get(placement.current_cpu).?,
                &mock_task,
                placement.workload_profile
            );
            
            const optimal_cpu = self.findOptimalCPU(&mock_task);
            const optimal_score = self.calculateCPUScore(
                optimal_cpu,
                &self.cache_topology.get(optimal_cpu).?,
                &mock_task,
                placement.workload_profile
            );
            
            // Migrate if significant improvement
            const improvement = (optimal_score - current_score) / current_score;
            if (improvement > self.migration_hysteresis and optimal_cpu != placement.current_cpu) {
                try self.migrateTask(pid, optimal_cpu);
            }
        }
    }
    
    fn migrateTask(self: *Self, pid: u32, new_cpu: u32) !void {
        const placement = self.task_placements.getPtr(pid).?;
        const old_cpu = placement.current_cpu;
        const new_topology = self.cache_topology.get(new_cpu).?;
        
        // Update placement
        placement.current_cpu = new_cpu;
        placement.current_numa_node = new_topology.numa_node;
        placement.last_migration = @intCast(std.time.nanoTimestamp());
        placement.migration_count += 1;
        
        // Update statistics
        self.scheduler_stats.recordMigration(true, true); // Assume gaming and improved cache
        
        console.printf("NUMA scheduler: Migrated PID {} from CPU {} to CPU {}\n", 
            .{ pid, old_cpu, new_cpu });
    }
    
    /// Remove task tracking when task exits
    pub fn removeTask(self: *Self, pid: u32) void {
        if (self.task_placements.get(pid)) |placement| {
            // Update NUMA node statistics
            var numa_node = &self.numa_nodes.items[placement.current_numa_node];
            if (numa_node.gaming_tasks > 0) {
                numa_node.gaming_tasks -= 1;
            }
            
            _ = self.task_placements.remove(pid);
            
            console.printf("NUMA scheduler: Removed task tracking for PID {}\n", .{pid});
        }
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.cache_warming_enabled = true;
        self.migration_hysteresis = 0.15; // More aggressive migration for gaming
        
        console.writeString("NUMA cache scheduler: Gaming mode enabled\n");
    }
    
    pub fn getStats(self: *Self) NUMASchedulerStats {
        return self.scheduler_stats;
    }
};

// Global NUMA cache scheduler
var global_numa_scheduler: ?*NUMACacheScheduler = null;

/// Initialize NUMA cache-aware scheduling
pub fn initNUMACacheScheduler(allocator: std.mem.Allocator) !void {
    const scheduler = try allocator.create(NUMACacheScheduler);
    scheduler.* = NUMACacheScheduler.init(allocator);
    
    // Discover system topology
    try scheduler.discoverTopology();
    
    // Enable gaming optimizations
    scheduler.enableGamingMode();
    
    global_numa_scheduler = scheduler;
    
    console.writeString("NUMA cache-aware scheduler initialized\n");
}

pub fn getNUMAScheduler() *NUMACacheScheduler {
    return global_numa_scheduler.?;
}

// Export for scheduler integration
pub fn onTaskCreate(task: *sched.Task) !void {
    const scheduler = getNUMAScheduler();
    try scheduler.placeTask(task);
}

pub fn onTaskDestroy(pid: u32) void {
    const scheduler = getNUMAScheduler();
    scheduler.removeTask(pid);
}

pub fn periodicNUMABalancing() !void {
    const scheduler = getNUMAScheduler();
    try scheduler.monitorAndMigrate();
}