//! Hybrid CPU Core Scheduler for Ghost Kernel
//! Optimized for Intel P/E cores (12th gen+) and AMD X3D cache architectures
//! Enhanced BORE-EEVDF with cache-aware and hybrid-aware scheduling

const std = @import("std");
const sched = @import("sched.zig");
const sync = @import("sync.zig");

/// CPU core types for hybrid architectures
pub const CoreType = enum(u8) {
    performance = 0,    // Intel P-cores, AMD standard cores
    efficiency = 1,     // Intel E-cores
    cache_optimized = 2, // AMD X3D cores with extra cache
    unknown = 255,
};

/// CPU cache levels and characteristics
pub const CacheInfo = struct {
    l1_data_size: u32,      // L1 data cache size in KB
    l1_inst_size: u32,      // L1 instruction cache size in KB
    l2_size: u32,           // L2 cache size in KB
    l3_size: u32,           // L3 cache size in KB (or X3D cache)
    l3_shared_cores: u8,    // Number of cores sharing L3
    cache_line_size: u8,    // Cache line size (typically 64 bytes)
    x3d_cache: bool,        // Has 3D V-Cache (AMD)
    smart_cache: bool,      // Has Intel Smart Cache
};

/// Workload characteristics for scheduling decisions
pub const WorkloadType = enum(u8) {
    interactive = 0,        // UI, gaming, low-latency
    background = 1,         // Background tasks, batch processing
    compute_intensive = 2,  // CPU-bound workloads
    cache_sensitive = 3,    // Benefits from large caches (simulations, databases)
    memory_bound = 4,       // Memory bandwidth limited
    mixed = 5,              // Mixed workload
};

/// CPU core information
pub const CPUCore = struct {
    id: u32,                // Logical CPU ID
    physical_id: u32,       // Physical core ID
    core_type: CoreType,    // Core type (P/E/X3D)
    cache_info: CacheInfo,  // Cache characteristics
    base_freq_mhz: u32,     // Base frequency in MHz
    max_freq_mhz: u32,      // Max boost frequency in MHz
    power_rating: u8,       // Power efficiency rating (0-255)
    
    // Current state
    current_freq_mhz: u32,  // Current frequency
    temperature: u8,        // Temperature in Celsius
    utilization: u8,        // Utilization percentage (0-100)
    
    // Scheduling state
    current_task: ?*sched.Task = null,
    runqueue: sched.RunQueue,
    load_avg: f32 = 0.0,    // Load average for this core
    cache_pressure: f32 = 0.0, // Cache pressure metric
    
    // Gaming optimizations
    gaming_preferred: bool = false,  // Preferred for gaming tasks
    low_latency_mode: bool = false,  // Low latency scheduling
    
    // ISA support
    supports_avx512: bool = true,    // AVX-512 support
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, id: u32, core_type: CoreType) Self {
        return Self{
            .id = id,
            .physical_id = id,
            .core_type = core_type,
            .cache_info = std.mem.zeroes(CacheInfo),
            .base_freq_mhz = 3000, // Default
            .max_freq_mhz = 4000,  // Default
            .power_rating = 128,   // Default
            .current_freq_mhz = 3000,
            .temperature = 50,     // Default temp
            .utilization = 0,
            .runqueue = sched.RunQueue.init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.runqueue.deinit();
    }
    
    pub fn isPerformanceCore(self: Self) bool {
        return self.core_type == .performance or self.core_type == .cache_optimized;
    }
    
    pub fn isEfficiencyCore(self: Self) bool {
        return self.core_type == .efficiency;
    }
    
    pub fn hasX3DCache(self: Self) bool {
        return self.cache_info.x3d_cache;
    }
    
    pub fn getEfficiencyScore(self: Self) f32 {
        // Calculate efficiency based on perf/power ratio
        const perf_score = @as(f32, @floatFromInt(self.max_freq_mhz)) / 1000.0;
        const power_score = @as(f32, @floatFromInt(self.power_rating)) / 255.0;
        return perf_score / (1.0 + (1.0 - power_score));
    }
    
    pub fn getCacheScore(self: Self) f32 {
        // Higher score for larger caches (especially X3D)
        var score = @as(f32, @floatFromInt(self.cache_info.l3_size)) / 1024.0; // MB
        if (self.cache_info.x3d_cache) {
            score *= 2.0; // X3D cache is much more effective
        }
        return score;
    }
    
    pub fn updateLoadAvg(self: *Self) void {
        const current_load = @as(f32, @floatFromInt(self.runqueue.tasks.items.len));
        self.load_avg = (self.load_avg * 0.9) + (current_load * 0.1);
    }
    
    pub fn updateCachePressure(self: *Self) void {
        // Estimate cache pressure based on task memory footprints
        var total_working_set: u64 = 0;
        for (self.runqueue.tasks.items) |task| {
            total_working_set += task.memory_footprint;
        }
        
        const l3_size_bytes = @as(u64, self.cache_info.l3_size) * 1024;
        self.cache_pressure = @min(1.0, @as(f32, @floatFromInt(total_working_set)) / @as(f32, @floatFromInt(l3_size_bytes)));
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_preferred = enabled;
        self.low_latency_mode = enabled;
        
        if (enabled) {
            // Boost frequency for gaming
            self.current_freq_mhz = self.max_freq_mhz;
        }
    }
};

/// Enhanced task structure with hybrid scheduling metadata
pub const HybridTask = struct {
    base_task: sched.Task,
    
    // Workload characteristics
    workload_type: WorkloadType = .mixed,
    memory_footprint: u64 = 0,     // Working set size in bytes
    cache_sensitivity: f32 = 0.5,  // 0.0 = cache insensitive, 1.0 = very sensitive
    compute_intensity: f32 = 0.5,  // 0.0 = I/O bound, 1.0 = CPU bound
    latency_sensitivity: f32 = 0.5, // 0.0 = batch, 1.0 = interactive
    
    // Performance counters
    instructions_per_cycle: f32 = 0.0,
    cache_miss_rate: f32 = 0.0,
    memory_bandwidth_usage: f32 = 0.0,
    
    // Hybrid scheduling state
    preferred_core_type: CoreType = .performance,
    last_core_id: u32 = 0,
    core_affinity_score: f32 = 0.0,
    migration_count: u32 = 0,
    
    // Gaming optimizations
    is_gaming_task: bool = false,
    real_time_priority: bool = false,
    
    const Self = @This();
    
    pub fn analyzeWorkload(self: *Self) void {
        // Analyze performance counters to determine workload type
        if (self.cache_miss_rate > 0.3) {
            // High cache miss rate - might benefit from larger cache
            self.cache_sensitivity = 0.8;
            if (self.memory_footprint > 32 * 1024 * 1024) { // > 32MB
                self.workload_type = .cache_sensitive;
                self.preferred_core_type = .cache_optimized;
            }
        }
        
        if (self.latency_sensitivity > 0.7) {
            // Interactive/gaming task
            self.workload_type = .interactive;
            self.preferred_core_type = .performance;
        } else if (self.compute_intensity > 0.8) {
            // CPU-intensive task
            self.workload_type = .compute_intensive;
            self.preferred_core_type = .performance;
        } else if (self.compute_intensity < 0.3) {
            // Background/batch task
            self.workload_type = .background;
            self.preferred_core_type = .efficiency;
        }
    }
    
    pub fn setGamingTask(self: *Self, is_gaming: bool) void {
        self.is_gaming_task = is_gaming;
        if (is_gaming) {
            self.workload_type = .interactive;
            self.preferred_core_type = .performance;
            self.latency_sensitivity = 1.0;
            self.real_time_priority = true;
            self.base_task.priority = -20; // Highest priority
        }
    }
    
    pub fn calculateAffinityScore(self: *Self, core: *CPUCore) f32 {
        var score: f32 = 0.0;
        
        // Core type preference
        if (core.core_type == self.preferred_core_type) {
            score += 10.0;
        } else if (self.preferred_core_type == .cache_optimized and core.isPerformanceCore()) {
            score += 7.0; // Fallback to P-cores if no X3D available
        } else if (self.preferred_core_type == .performance and core.core_type == .efficiency) {
            score += 2.0; // Can run on E-cores but not preferred
        }
        
        // Cache considerations
        if (self.cache_sensitivity > 0.6) {
            score += core.getCacheScore() * self.cache_sensitivity * 5.0;
        }
        
        // Gaming tasks prefer fast cores
        if (self.is_gaming_task and core.isPerformanceCore()) {
            score += 15.0;
            if (core.gaming_preferred) {
                score += 5.0;
            }
        }
        
        // Load balancing - prefer less loaded cores
        score += (1.0 - core.load_avg) * 3.0;
        
        // Cache pressure consideration
        if (self.cache_sensitivity > 0.5) {
            score -= core.cache_pressure * 5.0;
        }
        
        // Efficiency considerations for background tasks
        if (self.workload_type == .background) {
            score += core.getEfficiencyScore() * 3.0;
        }
        
        // Temperature throttling avoidance
        if (core.temperature > 80) {
            score -= 10.0;
        }
        
        // Migration penalty - prefer to stay on same core
        if (core.id == self.last_core_id) {
            score += 2.0;
        }
        
        return score;
    }
};

/// Hybrid CPU topology detection
pub const CPUTopology = struct {
    cores: std.ArrayList(*CPUCore),
    performance_cores: std.ArrayList(*CPUCore),
    efficiency_cores: std.ArrayList(*CPUCore),
    x3d_cores: std.ArrayList(*CPUCore),
    
    // Topology information
    total_cores: u32,
    performance_core_count: u32,
    efficiency_core_count: u32,
    x3d_core_count: u32,
    
    // Platform detection
    is_intel_hybrid: bool = false,  // 12th gen+ with P/E cores
    is_amd_x3d: bool = false,       // Zen 3D/4 with 3D V-Cache
    is_apple_silicon: bool = false, // Apple M-series
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .cores = std.ArrayList(*CPUCore).init(allocator),
            .performance_cores = std.ArrayList(*CPUCore).init(allocator),
            .efficiency_cores = std.ArrayList(*CPUCore).init(allocator),
            .x3d_cores = std.ArrayList(*CPUCore).init(allocator),
            .total_cores = 0,
            .performance_core_count = 0,
            .efficiency_core_count = 0,
            .x3d_core_count = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up cores
        for (self.cores.items) |core| {
            core.deinit();
            self.allocator.destroy(core);
        }
        self.cores.deinit();
        self.performance_cores.deinit();
        self.efficiency_cores.deinit();
        self.x3d_cores.deinit();
    }
    
    pub fn detectTopology(self: *Self) !void {
        // This would use CPUID and ACPI information to detect CPU topology
        // For now, we'll simulate common configurations
        
        // Detect CPU vendor and model
        const cpu_info = try self.getCPUInfo();
        
        if (std.mem.indexOf(u8, cpu_info.vendor, "GenuineIntel") != null) {
            try self.detectIntelHybrid(cpu_info);
        } else if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            try self.detectAMDX3D(cpu_info);
        }
        
        // Update counts
        self.total_cores = @intCast(self.cores.items.len);
        self.performance_core_count = @intCast(self.performance_cores.items.len);
        self.efficiency_core_count = @intCast(self.efficiency_cores.items.len);
        self.x3d_core_count = @intCast(self.x3d_cores.items.len);
    }
    
    fn detectIntelHybrid(self: *Self, cpu_info: CPUInfo) !void {
        // Detect Intel 12th gen+ hybrid architecture
        if (cpu_info.family == 6 and cpu_info.model >= 0x97) { // Alder Lake+
            self.is_intel_hybrid = true;
            
            // Example: Intel i7-12700K (8P + 4E cores)
            // Create P-cores
            for (0..8) |i| {
                const core = try self.allocator.create(CPUCore);
                core.* = CPUCore.init(self.allocator, @intCast(i), .performance);
                core.cache_info = CacheInfo{
                    .l1_data_size = 48,    // 48KB L1D
                    .l1_inst_size = 32,    // 32KB L1I
                    .l2_size = 1280,       // 1.25MB L2
                    .l3_size = 25600,      // 25MB L3 (shared)
                    .l3_shared_cores = 8,
                    .cache_line_size = 64,
                    .x3d_cache = false,
                    .smart_cache = true,
                };
                core.base_freq_mhz = 3600;
                core.max_freq_mhz = 5000;
                core.power_rating = 200; // Higher power
                core.gaming_preferred = true;
                
                try self.cores.append(core);
                try self.performance_cores.append(core);
            }
            
            // Create E-cores
            for (8..12) |i| {
                const core = try self.allocator.create(CPUCore);
                core.* = CPUCore.init(self.allocator, @intCast(i), .efficiency);
                core.cache_info = CacheInfo{
                    .l1_data_size = 32,    // 32KB L1D
                    .l1_inst_size = 64,    // 64KB L1I
                    .l2_size = 2048,       // 2MB L2 (shared between 4 E-cores)
                    .l3_size = 25600,      // Shared L3
                    .l3_shared_cores = 12,
                    .cache_line_size = 64,
                    .x3d_cache = false,
                    .smart_cache = true,
                };
                core.base_freq_mhz = 2700;
                core.max_freq_mhz = 3800;
                core.power_rating = 100; // Lower power
                
                try self.cores.append(core);
                try self.efficiency_cores.append(core);
            }
        }
    }
    
    fn detectIntelHybridArchitecture(self: *Self, cpu_info: CPUInfo) !void {
        // Detect Intel Alder Lake (12th gen) and Raptor Lake (13th gen)
        if (cpu_info.family == 0x6) {
            switch (cpu_info.model) {
                // Alder Lake
                0x97, 0x9A => {
                    self.is_intel_hybrid = true;
                    // Alder Lake: 8 P-cores + 8 E-cores (i9-12900K)
                    
                    // P-cores (Golden Cove)
                    for (0..8) |i| {
                        const core = try self.allocator.create(CPUCore);
                        core.* = CPUCore.init(self.allocator, @intCast(i), .performance);
                        core.cache_info = CacheInfo{
                            .l1_data_size = 48,    // 48KB L1D
                            .l1_inst_size = 32,    // 32KB L1I
                            .l2_size = 1280,       // 1.25MB L2
                            .l3_size = 30 * 1024,  // 30MB L3 shared
                            .l3_shared_cores = 16,
                            .cache_line_size = 64,
                            .x3d_cache = false,
                            .smart_cache = true,
                        };
                        core.base_freq_mhz = 3200;
                        core.max_freq_mhz = 5200;
                        core.power_rating = 241; // P-cores high power
                        core.supports_avx512 = true;
                        
                        try self.cores.append(core);
                        try self.performance_cores.append(core);
                    }
                    
                    // E-cores (Gracemont)
                    for (8..16) |i| {
                        const core = try self.allocator.create(CPUCore);
                        core.* = CPUCore.init(self.allocator, @intCast(i), .efficiency);
                        core.cache_info = CacheInfo{
                            .l1_data_size = 64,    // 64KB L1D (shared by 4)
                            .l1_inst_size = 64,    // 64KB L1I (shared by 4)
                            .l2_size = 2048,       // 2MB L2 (shared by 4)
                            .l3_size = 30 * 1024,  // 30MB L3 shared
                            .l3_shared_cores = 16,
                            .cache_line_size = 64,
                            .x3d_cache = false,
                            .smart_cache = true,
                        };
                        core.base_freq_mhz = 2400;
                        core.max_freq_mhz = 3900;
                        core.power_rating = 100; // E-cores low power
                        core.supports_avx512 = false; // E-cores don't support AVX-512
                        
                        try self.cores.append(core);
                        try self.efficiency_cores.append(core);
                    }
                },
                // Raptor Lake
                0xB7, 0xBA => {
                    self.is_intel_hybrid = true;
                    // Raptor Lake: 8 P-cores + 16 E-cores (i9-13900K)
                    
                    // P-cores (Raptor Cove)
                    for (0..8) |i| {
                        const core = try self.allocator.create(CPUCore);
                        core.* = CPUCore.init(self.allocator, @intCast(i), .performance);
                        core.cache_info = CacheInfo{
                            .l1_data_size = 48,    // 48KB L1D
                            .l1_inst_size = 32,    // 32KB L1I
                            .l2_size = 2048,       // 2MB L2
                            .l3_size = 36 * 1024,  // 36MB L3 shared
                            .l3_shared_cores = 24,
                            .cache_line_size = 64,
                            .x3d_cache = false,
                            .smart_cache = true,
                        };
                        core.base_freq_mhz = 3000;
                        core.max_freq_mhz = 5800; // Higher boost than Alder Lake
                        core.power_rating = 253;
                        core.supports_avx512 = true;
                        
                        try self.cores.append(core);
                        try self.performance_cores.append(core);
                    }
                    
                    // E-cores (Gracemont) - 16 cores in 4 clusters
                    for (8..24) |i| {
                        const core = try self.allocator.create(CPUCore);
                        core.* = CPUCore.init(self.allocator, @intCast(i), .efficiency);
                        core.cache_info = CacheInfo{
                            .l1_data_size = 64,    // 64KB L1D (shared by 4)
                            .l1_inst_size = 64,    // 64KB L1I (shared by 4)
                            .l2_size = 4096,       // 4MB L2 (shared by 4)
                            .l3_size = 36 * 1024,  // 36MB L3 shared
                            .l3_shared_cores = 24,
                            .cache_line_size = 64,
                            .x3d_cache = false,
                            .smart_cache = true,
                        };
                        core.base_freq_mhz = 2200;
                        core.max_freq_mhz = 4300; // Higher E-core boost
                        core.power_rating = 80;
                        core.supports_avx512 = false;
                        
                        try self.cores.append(core);
                        try self.efficiency_cores.append(core);
                    }
                },
                else => {},
            }
        }
    }

    fn detectAMDX3D(self: *Self, cpu_info: CPUInfo) !void {
        // Detect AMD Zen 3D/4 with 3D V-Cache
        if (cpu_info.family == 0x19) { // Zen 3/4
            // Check for X3D models (simplified detection)
            if (std.mem.indexOf(u8, cpu_info.model_name, "X3D") != null) {
                self.is_amd_x3d = true;
                
                // Example: AMD 7950X3D (8 cores with X3D + 8 cores without)
                // First CCD has X3D cache
                for (0..8) |i| {
                    const core = try self.allocator.create(CPUCore);
                    core.* = CPUCore.init(self.allocator, @intCast(i), .cache_optimized);
                    core.cache_info = CacheInfo{
                        .l1_data_size = 32,    // 32KB L1D
                        .l1_inst_size = 32,    // 32KB L1I
                        .l2_size = 1024,       // 1MB L2
                        .l3_size = 96 * 1024,  // 96MB L3 with 3D V-Cache
                        .l3_shared_cores = 8,
                        .cache_line_size = 64,
                        .x3d_cache = true,     // 3D V-Cache enabled
                        .smart_cache = false,
                    };
                    core.base_freq_mhz = 4200;
                    core.max_freq_mhz = 5700;
                    core.power_rating = 170;
                    
                    try self.cores.append(core);
                    try self.x3d_cores.append(core);
                    try self.performance_cores.append(core);
                }
                
                // Second CCD without X3D (higher clocks)
                for (8..16) |i| {
                    const core = try self.allocator.create(CPUCore);
                    core.* = CPUCore.init(self.allocator, @intCast(i), .performance);
                    core.cache_info = CacheInfo{
                        .l1_data_size = 32,    // 32KB L1D
                        .l1_inst_size = 32,    // 32KB L1I
                        .l2_size = 1024,       // 1MB L2
                        .l3_size = 32 * 1024,  // 32MB L3 (standard)
                        .l3_shared_cores = 8,
                        .cache_line_size = 64,
                        .x3d_cache = false,
                        .smart_cache = false,
                    };
                    core.base_freq_mhz = 4200;
                    core.max_freq_mhz = 5700;
                    core.power_rating = 170;
                    core.gaming_preferred = true; // Higher clocks for gaming
                    
                    try self.cores.append(core);
                    try self.performance_cores.append(core);
                }
            } else {
                // Standard Zen 3/4 cores
                for (0..16) |i| {
                    const core = try self.allocator.create(CPUCore);
                    core.* = CPUCore.init(self.allocator, @intCast(i), .performance);
                    core.cache_info = CacheInfo{
                        .l1_data_size = 32,
                        .l1_inst_size = 32,
                        .l2_size = 1024,
                        .l3_size = 32 * 1024,  // 32MB L3
                        .l3_shared_cores = 8,
                        .cache_line_size = 64,
                        .x3d_cache = false,
                        .smart_cache = false,
                    };
                    core.base_freq_mhz = 4200;
                    core.max_freq_mhz = 5700;
                    core.power_rating = 170;
                    
                    try self.cores.append(core);
                    try self.performance_cores.append(core);
                }
            }
        }
    }
    
    fn getCPUInfo(self: Self) !CPUInfo {
        _ = self;
        // This would use CPUID instruction to get CPU information
        // For now, return a simulated response
        return CPUInfo{
            .vendor = "AuthenticAMD",
            .family = 0x19,
            .model = 0x61,
            .stepping = 2,
            .model_name = "AMD Ryzen 9 7950X3D",
        };
    }
};

/// CPU information structure
pub const CPUInfo = struct {
    vendor: []const u8,
    family: u32,
    model: u32,
    stepping: u32,
    model_name: []const u8,
};

/// Hybrid-aware BORE-EEVDF scheduler
pub const HybridScheduler = struct {
    topology: CPUTopology,
    global_runqueue: sched.RunQueue,
    
    // Gaming mode
    gaming_mode_enabled: bool = false,
    
    // Performance monitoring
    total_migrations: std.atomic.Value(u64),
    cache_optimized_placements: std.atomic.Value(u64),
    gaming_task_count: std.atomic.Value(u32),
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        var scheduler = Self{
            .topology = CPUTopology.init(allocator),
            .global_runqueue = sched.RunQueue.init(allocator),
            .total_migrations = std.atomic.Value(u64).init(0),
            .cache_optimized_placements = std.atomic.Value(u64).init(0),
            .gaming_task_count = std.atomic.Value(u32).init(0),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
        
        try scheduler.topology.detectTopology();
        return scheduler;
    }
    
    pub fn deinit(self: *Self) void {
        self.topology.deinit();
        self.global_runqueue.deinit();
    }
    
    pub fn selectCore(self: *Self, task: *HybridTask) *CPUCore {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var best_core: ?*CPUCore = null;
        var best_score: f32 = -1000.0;
        
        // Analyze task workload characteristics
        task.analyzeWorkload();
        
        // Find best core based on affinity score
        for (self.topology.cores.items) |core| {
            const score = task.calculateAffinityScore(core);
            
            if (score > best_score) {
                best_score = score;
                best_core = core;
            }
        }
        
        // Update statistics
        if (best_core) |core| {
            if (core.core_type == .cache_optimized and task.cache_sensitivity > 0.6) {
                _ = self.cache_optimized_placements.fetchAdd(1, .release);
            }
            
            if (task.last_core_id != 0 and task.last_core_id != core.id) {
                _ = self.total_migrations.fetchAdd(1, .release);
                task.migration_count += 1;
            }
            
            task.last_core_id = core.id;
            task.core_affinity_score = best_score;
            
            return core;
        }
        
        // Fallback to first available core
        return self.topology.cores.items[0];
    }
    
    pub fn scheduleTask(self: *Self, task: *HybridTask) void {
        const selected_core = self.selectCore(task);
        
        // Add task to core's run queue
        selected_core.runqueue.addTask(&task.base_task) catch return;
        
        // Update core load
        selected_core.updateLoadAvg();
        selected_core.updateCachePressure();
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = true;
        
        // Configure cores for gaming
        for (self.topology.performance_cores.items) |core| {
            core.setGamingMode(true);
        }
        
        // Boost X3D cores for cache-sensitive gaming workloads
        for (self.topology.x3d_cores.items) |core| {
            core.setGamingMode(true);
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = false;
        
        for (self.topology.cores.items) |core| {
            core.setGamingMode(false);
        }
    }
    
    pub fn addGamingTask(self: *Self, task: *HybridTask) void {
        task.setGamingTask(true);
        _ = self.gaming_task_count.fetchAdd(1, .release);
        
        // Immediately schedule on best performance core
        self.scheduleTask(task);
    }
    
    pub fn balanceLoad(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Implement load balancing between cores
        // Move tasks from overloaded cores to underutilized ones
        // Consider cache warming costs in migration decisions
        
        for (self.topology.cores.items) |core| {
            core.updateLoadAvg();
            core.updateCachePressure();
            
            // If core is overloaded, consider moving background tasks
            if (core.load_avg > 2.0 and core.runqueue.tasks.items.len > 1) {
                // Find background tasks to migrate
                for (core.runqueue.tasks.items) |task| {
                    const hybrid_task = @as(*HybridTask, @fieldParentPtr("base_task", task));
                    if (hybrid_task.workload_type == .background) {
                        // Find a less loaded core of appropriate type
                        const target_core = self.findLeastLoadedCore(.efficiency);
                        if (target_core != core and target_core.load_avg < 1.0) {
                            // Migrate task
                            // TODO: Implement task migration
                            break;
                        }
                    }
                }
            }
        }
    }
    
    fn findLeastLoadedCore(self: *Self, preferred_type: CoreType) *CPUCore {
        var best_core = self.topology.cores.items[0];
        var lowest_load = best_core.load_avg;
        
        for (self.topology.cores.items) |core| {
            if ((preferred_type == .efficiency and core.isEfficiencyCore()) or
                (preferred_type == .performance and core.isPerformanceCore()) or
                (preferred_type == .cache_optimized and core.hasX3DCache()))
            {
                if (core.load_avg < lowest_load) {
                    lowest_load = core.load_avg;
                    best_core = core;
                }
            }
        }
        
        return best_core;
    }
    
    pub fn getSchedulerMetrics(self: *Self) HybridSchedulerMetrics {
        return HybridSchedulerMetrics{
            .total_cores = self.topology.total_cores,
            .performance_cores = self.topology.performance_core_count,
            .efficiency_cores = self.topology.efficiency_core_count,
            .x3d_cores = self.topology.x3d_core_count,
            .is_intel_hybrid = self.topology.is_intel_hybrid,
            .is_amd_x3d = self.topology.is_amd_x3d,
            .gaming_mode_enabled = self.gaming_mode_enabled,
            .total_migrations = self.total_migrations.load(.acquire),
            .cache_optimized_placements = self.cache_optimized_placements.load(.acquire),
            .gaming_task_count = self.gaming_task_count.load(.acquire),
        };
    }
};

/// Scheduler performance metrics
pub const HybridSchedulerMetrics = struct {
    total_cores: u32,
    performance_cores: u32,
    efficiency_cores: u32,
    x3d_cores: u32,
    is_intel_hybrid: bool,
    is_amd_x3d: bool,
    gaming_mode_enabled: bool,
    total_migrations: u64,
    cache_optimized_placements: u64,
    gaming_task_count: u32,
};

// Global hybrid scheduler
var global_hybrid_scheduler: ?*HybridScheduler = null;

/// Initialize hybrid scheduler
pub fn initHybridScheduler(allocator: std.mem.Allocator) !void {
    const scheduler = try allocator.create(HybridScheduler);
    scheduler.* = try HybridScheduler.init(allocator);
    global_hybrid_scheduler = scheduler;
}

/// Get the global hybrid scheduler
pub fn getHybridScheduler() *HybridScheduler {
    return global_hybrid_scheduler orelse @panic("Hybrid scheduler not initialized");
}

// Tests
test "CPU topology detection" {
    const allocator = std.testing.allocator;
    
    var topology = CPUTopology.init(allocator);
    defer topology.deinit();
    
    try topology.detectTopology();
    try std.testing.expect(topology.total_cores > 0);
}

test "task affinity scoring" {
    const allocator = std.testing.allocator;
    
    var task = HybridTask{
        .base_task = sched.Task{
            .pid = 1,
            .state = .runnable,
            .sched_class = .normal,
            .priority = 0,
            .vruntime = 0,
            .deadline = 0,
            .slice = 0,
            .lag = 0,
            .burst_time = 0,
            .burst_score = 0,
            .memory_footprint = 0,
        },
        .workload_type = .cache_sensitive,
        .cache_sensitivity = 0.8,
        .preferred_core_type = .cache_optimized,
    };
    
    var p_core = CPUCore.init(allocator, 0, .performance);
    defer p_core.deinit();
    
    var x3d_core = CPUCore.init(allocator, 1, .cache_optimized);
    defer x3d_core.deinit();
    x3d_core.cache_info.x3d_cache = true;
    x3d_core.cache_info.l3_size = 96 * 1024; // 96MB
    
    const p_score = task.calculateAffinityScore(&p_core);
    const x3d_score = task.calculateAffinityScore(&x3d_core);
    
    // X3D core should score higher for cache-sensitive tasks
    try std.testing.expect(x3d_score > p_score);
}

test "gaming task optimization" {
    
    var task = HybridTask{
        .base_task = sched.Task{
            .pid = 1,
            .state = .runnable,
            .sched_class = .normal,
            .priority = 0,
            .vruntime = 0,
            .deadline = 0,
            .slice = 0,
            .lag = 0,
            .burst_time = 0,
            .burst_score = 0,
            .memory_footprint = 0,
        },
    };
    
    task.setGamingTask(true);
    
    try std.testing.expect(task.is_gaming_task);
    try std.testing.expect(task.workload_type == .interactive);
    try std.testing.expect(task.preferred_core_type == .performance);
    try std.testing.expect(task.latency_sensitivity == 1.0);
    try std.testing.expect(task.real_time_priority);
}