// Intel Thread Director support for Alder Lake and Raptor Lake
// Hardware-guided scheduling for hybrid P/E core architectures

const std = @import("std");
const msr = @import("msr.zig");
const sched = @import("sched.zig");

pub const ThreadClassification = enum(u8) {
    unknown = 0,
    performance_sensitive = 1,
    balanced = 2,
    efficiency_preferred = 3,
    background = 4,
};

pub const CoreRecommendation = enum(u8) {
    no_preference = 0,
    prefer_p_core = 1,
    prefer_e_core = 2,
    avoid_p_core = 3,
    avoid_e_core = 4,
};

pub const ThreadDirectorData = struct {
    classification: ThreadClassification,
    performance_class: u8,
    efficiency_class: u8,
    recommendation: CoreRecommendation,
    confidence: u8,
    
    // Performance characteristics
    ipc_score: f32,           // Instructions per cycle
    branch_mispredict_rate: f32,
    cache_miss_rate: f32,
    memory_bandwidth_usage: f32,
    
    // Temporal characteristics
    runtime_estimate: u64,    // Expected runtime in cycles
    deadline_urgency: u8,     // Deadline urgency (0-255)
    
    // Hardware feedback
    hardware_feedback_valid: bool,
    hardware_class: u8,
    hardware_confidence: u8,
};

pub const IntelThreadDirector = struct {
    enabled: bool,
    hardware_feedback_available: bool,
    
    // Per-core feedback data
    p_core_feedback: [8]CoreFeedback,
    e_core_feedback: [16]CoreFeedback,
    
    // Thread classification cache
    thread_cache: std.HashMap(u32, ThreadDirectorData, std.hash_map.DefaultHasher(u32), std.heap.page_allocator),
    
    // MSR definitions for Thread Director
    const INTEL_HFI_ENABLE = 0x17D0;
    const INTEL_HFI_STATUS = 0x17D1;
    const INTEL_HFI_PERF_CAPS = 0x17D2;
    const INTEL_HFI_EFF_CAPS = 0x17D3;
    const INTEL_HFI_FEEDBACK_BASE = 0x17D4;
    
    // Thread Director MSRs
    const INTEL_TD_ENABLE = 0x17E0;
    const INTEL_TD_STATUS = 0x17E1;
    const INTEL_TD_CLASSIFICATION = 0x17E2;
    const INTEL_TD_RECOMMENDATION = 0x17E3;
    
    const Self = @This();
    
    pub fn init() !Self {
        var director = Self{
            .enabled = false,
            .hardware_feedback_available = false,
            .p_core_feedback = undefined,
            .e_core_feedback = undefined,
            .thread_cache = std.HashMap(u32, ThreadDirectorData, std.hash_map.DefaultHasher(u32), std.heap.page_allocator).init(std.heap.page_allocator),
        };
        
        // Initialize core feedback arrays
        for (0..8) |i| {
            director.p_core_feedback[i] = CoreFeedback.init(@intCast(i), .performance);
        }
        
        for (0..16) |i| {
            director.e_core_feedback[i] = CoreFeedback.init(@intCast(i), .efficiency);
        }
        
        try director.detectCapabilities();
        if (director.hardware_feedback_available) {
            try director.enableThreadDirector();
        }
        
        return director;
    }
    
    fn detectCapabilities(self: *Self) !void {
        // Check for Thread Director support via CPUID
        const cpuid_result = asm volatile (
            "cpuid"
            : [eax] "={eax}" (-> u32),
              [ebx] "={ebx}" (-> u32),
              [ecx] "={ecx}" (-> u32),
              [edx] "={edx}" (-> u32)
            : [eax] "{eax}" (@as(u32, 0x06))
        );
        
        // Check for HFI (Hardware Feedback Interface) support
        self.hardware_feedback_available = (cpuid_result[0] & (1 << 19)) != 0;
        
        // Check for Thread Director support (Intel specific)
        const cpuid_ext = asm volatile (
            "cpuid"
            : [eax] "={eax}" (-> u32),
              [ebx] "={ebx}" (-> u32),
              [ecx] "={ecx}" (-> u32),
              [edx] "={edx}" (-> u32)
            : [eax] "{eax}" (@as(u32, 0x1F))
        );
        
        const has_thread_director = (cpuid_ext[2] & (1 << 15)) != 0;
        
        if (self.hardware_feedback_available and has_thread_director) {
            std.log.info("Intel Thread Director with HFI support detected", .{});
            self.enabled = true;
        } else {
            std.log.warn("Intel Thread Director not available", .{});
        }
    }
    
    fn enableThreadDirector(self: *Self) !void {
        if (!self.hardware_feedback_available) {
            return error.ThreadDirectorNotSupported;
        }
        
        // Enable Hardware Feedback Interface
        var hfi_enable = try msr.read(INTEL_HFI_ENABLE);
        hfi_enable |= 1;  // Enable HFI
        try msr.write(INTEL_HFI_ENABLE, hfi_enable);
        
        // Enable Thread Director
        var td_enable = try msr.read(INTEL_TD_ENABLE);
        td_enable |= 1;  // Enable Thread Director
        td_enable |= (1 << 1);  // Enable automatic classification
        try msr.write(INTEL_TD_ENABLE, td_enable);
        
        // Configure feedback collection
        try self.configureFeedback();
        
        std.log.info("Intel Thread Director enabled", .{});
    }
    
    fn configureFeedback(self: *Self) !void {
        // Configure performance monitoring for Thread Director
        var perf_caps = try msr.read(INTEL_HFI_PERF_CAPS);
        perf_caps |= (1 << 0);  // Enable performance monitoring
        perf_caps |= (1 << 1);  // Enable IPC monitoring
        perf_caps |= (1 << 2);  // Enable branch prediction monitoring
        try msr.write(INTEL_HFI_PERF_CAPS, perf_caps);
        
        var eff_caps = try msr.read(INTEL_HFI_EFF_CAPS);
        eff_caps |= (1 << 0);  // Enable efficiency monitoring
        eff_caps |= (1 << 1);  // Enable power monitoring
        try msr.write(INTEL_HFI_EFF_CAPS, eff_caps);
        
        std.log.info("Thread Director feedback collection configured", .{});
    }
    
    pub fn classifyThread(self: *Self, thread_id: u32, task_info: TaskInfo) !ThreadDirectorData {
        // Check cache first
        if (self.thread_cache.get(thread_id)) |cached| {
            return cached;
        }
        
        var data = ThreadDirectorData{
            .classification = .unknown,
            .performance_class = 0,
            .efficiency_class = 0,
            .recommendation = .no_preference,
            .confidence = 0,
            .ipc_score = 0.0,
            .branch_mispredict_rate = 0.0,
            .cache_miss_rate = 0.0,
            .memory_bandwidth_usage = 0.0,
            .runtime_estimate = 0,
            .deadline_urgency = 0,
            .hardware_feedback_valid = false,
            .hardware_class = 0,
            .hardware_confidence = 0,
        };
        
        // Use hardware feedback if available
        if (self.enabled and self.hardware_feedback_available) {
            data = try self.getHardwareFeedback(thread_id);
        }
        
        // Supplement with software heuristics
        try self.applySoftwareHeuristics(&data, task_info);
        
        // Generate core recommendation
        data.recommendation = self.generateCoreRecommendation(data);
        
        // Cache the result
        try self.thread_cache.put(thread_id, data);
        
        return data;
    }
    
    fn getHardwareFeedback(self: *Self, thread_id: u32) !ThreadDirectorData {
        _ = thread_id;
        
        var data = ThreadDirectorData{
            .classification = .unknown,
            .performance_class = 0,
            .efficiency_class = 0,
            .recommendation = .no_preference,
            .confidence = 0,
            .ipc_score = 0.0,
            .branch_mispredict_rate = 0.0,
            .cache_miss_rate = 0.0,
            .memory_bandwidth_usage = 0.0,
            .runtime_estimate = 0,
            .deadline_urgency = 0,
            .hardware_feedback_valid = false,
            .hardware_class = 0,
            .hardware_confidence = 0,
        };
        
        // Read Thread Director classification
        const classification_msr = try msr.read(INTEL_TD_CLASSIFICATION);
        data.hardware_class = @truncate(classification_msr & 0xFF);
        data.hardware_confidence = @truncate((classification_msr >> 8) & 0xFF);
        data.hardware_feedback_valid = (classification_msr & (1 << 31)) != 0;
        
        if (data.hardware_feedback_valid) {
            // Read performance characteristics from HFI
            const perf_feedback = try msr.read(INTEL_HFI_FEEDBACK_BASE);
            data.performance_class = @truncate(perf_feedback & 0xFF);
            data.efficiency_class = @truncate((perf_feedback >> 8) & 0xFF);
            
            // Convert hardware class to our classification
            data.classification = switch (data.hardware_class) {
                0...63 => .efficiency_preferred,
                64...127 => .balanced,
                128...191 => .performance_sensitive,
                192...255 => .performance_sensitive,
            };
            
            data.confidence = data.hardware_confidence;
        }
        
        return data;
    }
    
    fn applySoftwareHeuristics(self: *Self, data: *ThreadDirectorData, task_info: TaskInfo) !void {
        _ = self;
        
        // Analyze task characteristics
        var sw_classification = ThreadClassification.balanced;
        var sw_confidence: u8 = 128;
        
        // Gaming workloads
        if (task_info.is_gaming_thread) {
            sw_classification = .performance_sensitive;
            sw_confidence = 240;
        }
        // Real-time threads
        else if (task_info.is_realtime) {
            sw_classification = .performance_sensitive;
            sw_confidence = 200;
        }
        // Background threads
        else if (task_info.nice_value > 5) {
            sw_classification = .efficiency_preferred;
            sw_confidence = 180;
        }
        // I/O bound threads
        else if (task_info.io_wait_ratio > 0.7) {
            sw_classification = .efficiency_preferred;
            sw_confidence = 160;
        }
        // CPU bound threads
        else if (task_info.cpu_usage > 0.8) {
            sw_classification = .performance_sensitive;
            sw_confidence = 180;
        }
        
        // Combine with hardware feedback if available
        if (data.hardware_feedback_valid) {
            // Weighted average of hardware and software classification
            const hw_weight = data.hardware_confidence;
            const sw_weight = sw_confidence;
            const total_weight = hw_weight + sw_weight;
            
            if (total_weight > 0) {
                const hw_score = @intFromEnum(data.classification) * hw_weight;
                const sw_score = @intFromEnum(sw_classification) * sw_weight;
                const combined_score = (hw_score + sw_score) / total_weight;
                
                data.classification = @enumFromInt(@min(combined_score, 4));
                data.confidence = @min(255, (hw_weight + sw_weight) / 2);
            }
        } else {
            data.classification = sw_classification;
            data.confidence = sw_confidence;
        }
        
        // Estimate performance characteristics
        data.ipc_score = switch (data.classification) {
            .performance_sensitive => 2.5,
            .balanced => 1.8,
            .efficiency_preferred => 1.2,
            .background => 0.8,
            else => 1.0,
        };
        
        data.runtime_estimate = task_info.avg_runtime_us * 1000; // Convert to ns
        data.deadline_urgency = if (task_info.is_realtime) 255 else 128;
    }
    
    fn generateCoreRecommendation(self: *Self, data: ThreadDirectorData) CoreRecommendation {
        _ = self;
        
        return switch (data.classification) {
            .performance_sensitive => .prefer_p_core,
            .balanced => .no_preference,
            .efficiency_preferred => .prefer_e_core,
            .background => .prefer_e_core,
            else => .no_preference,
        };
    }
    
    pub fn scheduleThread(self: *Self, thread_id: u32, task_info: TaskInfo) !SchedulingDecision {
        const td_data = try self.classifyThread(thread_id, task_info);
        
        var decision = SchedulingDecision{
            .preferred_core_type = .any,
            .preferred_core_id = null,
            .priority_boost = 0,
            .affinity_mask = 0xFFFFFFFF, // All cores by default
            .confidence = td_data.confidence,
        };
        
        // Apply core recommendation
        switch (td_data.recommendation) {
            .prefer_p_core => {
                decision.preferred_core_type = .performance;
                decision.affinity_mask = 0x000000FF; // P-cores 0-7
                decision.priority_boost = 5;
            },
            .prefer_e_core => {
                decision.preferred_core_type = .efficiency;
                decision.affinity_mask = 0xFFFFFF00; // E-cores 8-23
                decision.priority_boost = 0;
            },
            .avoid_p_core => {
                decision.preferred_core_type = .efficiency;
                decision.affinity_mask = 0xFFFFFF00; // E-cores only
                decision.priority_boost = -5;
            },
            .avoid_e_core => {
                decision.preferred_core_type = .performance;
                decision.affinity_mask = 0x000000FF; // P-cores only
                decision.priority_boost = 10;
            },
            else => {
                // No specific preference
            }
        }
        
        // Find the best specific core
        decision.preferred_core_id = try self.findBestCore(td_data, decision.preferred_core_type);
        
        return decision;
    }
    
    fn findBestCore(self: *Self, td_data: ThreadDirectorData, preferred_type: CoreType) !?u32 {
        var best_core: ?u32 = null;
        var best_score: f32 = -1.0;
        
        switch (preferred_type) {
            .performance => {
                for (0..8) |i| {
                    const score = self.p_core_feedback[i].getScore(td_data);
                    if (score > best_score) {
                        best_score = score;
                        best_core = @intCast(i);
                    }
                }
            },
            .efficiency => {
                for (8..24) |i| {
                    const score = self.e_core_feedback[i - 8].getScore(td_data);
                    if (score > best_score) {
                        best_score = score;
                        best_core = @intCast(i);
                    }
                }
            },
            .any => {
                // Check both P and E cores
                for (0..8) |i| {
                    const score = self.p_core_feedback[i].getScore(td_data);
                    if (score > best_score) {
                        best_score = score;
                        best_core = @intCast(i);
                    }
                }
                
                for (8..24) |i| {
                    const score = self.e_core_feedback[i - 8].getScore(td_data);
                    if (score > best_score) {
                        best_score = score;
                        best_core = @intCast(i);
                    }
                }
            },
        }
        
        return best_core;
    }
    
    pub fn updateCoreFeedback(self: *Self, core_id: u32, utilization: f32, temperature: u8) !void {
        if (core_id < 8) {
            self.p_core_feedback[core_id].updateLoad(utilization, temperature);
        } else if (core_id < 24) {
            self.e_core_feedback[core_id - 8].updateLoad(utilization, temperature);
        }
    }
    
    pub fn getOptimalCoreConfiguration(self: *Self, workload: WorkloadType) !CoreConfiguration {
        return switch (workload) {
            .gaming => CoreConfiguration{
                .p_core_count = 8,
                .e_core_count = 8,
                .p_core_priority = 10,
                .e_core_priority = 0,
                .prefer_p_cores = true,
            },
            .productivity => CoreConfiguration{
                .p_core_count = 6,
                .e_core_count = 12,
                .p_core_priority = 5,
                .e_core_priority = 3,
                .prefer_p_cores = false,
            },
            .background => CoreConfiguration{
                .p_core_count = 2,
                .e_core_count = 16,
                .p_core_priority = 0,
                .e_core_priority = 5,
                .prefer_p_cores = false,
            },
            else => CoreConfiguration{
                .p_core_count = 8,
                .e_core_count = 16,
                .p_core_priority = 5,
                .e_core_priority = 5,
                .prefer_p_cores = false,
            },
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.thread_cache.deinit();
    }
};

pub const TaskInfo = struct {
    is_gaming_thread: bool,
    is_realtime: bool,
    nice_value: i8,
    cpu_usage: f32,
    io_wait_ratio: f32,
    avg_runtime_us: u64,
    memory_footprint: u64,
    cache_miss_rate: f32,
};

pub const SchedulingDecision = struct {
    preferred_core_type: CoreType,
    preferred_core_id: ?u32,
    priority_boost: i8,
    affinity_mask: u32,
    confidence: u8,
};

pub const CoreType = enum {
    performance,
    efficiency,
    any,
};

pub const CoreConfiguration = struct {
    p_core_count: u8,
    e_core_count: u8,
    p_core_priority: u8,
    e_core_priority: u8,
    prefer_p_cores: bool,
};

pub const WorkloadType = enum {
    gaming,
    productivity,
    background,
    compute,
};

pub const CoreFeedback = struct {
    core_id: u32,
    core_type: CoreType,
    load_average: f32,
    temperature: u8,
    utilization_history: [16]f32,
    history_index: usize,
    
    const Self = @This();
    
    pub fn init(core_id: u32, core_type: CoreType) Self {
        return Self{
            .core_id = core_id,
            .core_type = core_type,
            .load_average = 0.0,
            .temperature = 0,
            .utilization_history = [_]f32{0.0} ** 16,
            .history_index = 0,
        };
    }
    
    pub fn updateLoad(self: *Self, utilization: f32, temperature: u8) void {
        self.utilization_history[self.history_index] = utilization;
        self.history_index = (self.history_index + 1) % 16;
        
        // Calculate exponential moving average
        self.load_average = (self.load_average * 0.8) + (utilization * 0.2);
        self.temperature = temperature;
    }
    
    pub fn getScore(self: *const Self, td_data: ThreadDirectorData) f32 {
        // Calculate a score for how well this core matches the thread
        var score: f32 = 0.0;
        
        // Load factor (lower load is better)
        score += (1.0 - self.load_average) * 40.0;
        
        // Temperature factor (lower temperature is better)
        const temp_factor = 1.0 - (@as(f32, @floatFromInt(self.temperature)) / 100.0);
        score += temp_factor * 20.0;
        
        // Core type matching
        switch (td_data.classification) {
            .performance_sensitive => {
                if (self.core_type == .performance) {
                    score += 30.0;
                }
            },
            .efficiency_preferred => {
                if (self.core_type == .efficiency) {
                    score += 30.0;
                }
            },
            else => {
                // No preference
                score += 10.0;
            },
        }
        
        // Confidence factor
        score *= (@as(f32, @floatFromInt(td_data.confidence)) / 255.0);
        
        return score;
    }
};