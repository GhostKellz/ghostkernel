//! Hardware Timestamp Scheduling
//! Uses CPU cycle counters and hardware timers for precise gaming timing
//! Features sub-microsecond precision, VRR sync, and frame deadline management

const std = @import("std");
const sched = @import("sched.zig");
const console = @import("../arch/x86_64/console.zig");

/// Hardware timestamp sources
pub const TimestampSource = enum {
    rdtsc,           // CPU Time Stamp Counter
    hpet,            // High Precision Event Timer
    tsc_deadline,    // TSC deadline timer
    apic_timer,      // Local APIC timer
    perf_counter,    // Performance monitoring counter
};

/// Gaming timing requirements
pub const GamingTimingRequirements = struct {
    target_fps: u32,             // Target frame rate (60, 120, 144, 240, etc.)
    frame_time_ns: u64,          // Target frame time in nanoseconds
    deadline_margin_ns: u64,     // Safety margin before deadline
    vrr_enabled: bool,           // Variable refresh rate support
    vrr_min_fps: u32,           // Minimum VRR frame rate
    vrr_max_fps: u32,           // Maximum VRR frame rate
    timing_precision: TimingPrecision,
    
    const TimingPrecision = enum {
        microsecond,    // ±1μs precision
        submicrosecond, // ±100ns precision  
        nanosecond,     // ±10ns precision (best effort)
    };
    
    pub fn fromFPS(fps: u32) GamingTimingRequirements {
        const frame_time = 1_000_000_000 / fps;
        return GamingTimingRequirements{
            .target_fps = fps,
            .frame_time_ns = frame_time,
            .deadline_margin_ns = frame_time / 10, // 10% margin
            .vrr_enabled = fps >= 120, // Enable VRR for high refresh rates
            .vrr_min_fps = @max(60, fps * 2 / 3),
            .vrr_max_fps = @min(240, fps * 4 / 3),
            .timing_precision = if (fps >= 240) .nanosecond 
                               else if (fps >= 120) .submicrosecond 
                               else .microsecond,
        };
    }
};

/// Hardware timer capabilities
pub const HardwareTimerCaps = struct {
    rdtsc_frequency: u64,        // TSC frequency in Hz
    rdtsc_reliable: bool,        // TSC is invariant and reliable
    hpet_available: bool,        // HPET is available
    hpet_frequency: u64,         // HPET frequency in Hz
    apic_timer_frequency: u64,   // Local APIC timer frequency
    tsc_deadline_supported: bool, // TSC deadline timer support
    precision_ns: u64,           // Timer precision in nanoseconds
    
    pub fn detectCapabilities() HardwareTimerCaps {
        // Mock hardware detection - in real implementation, use CPUID and ACPI
        return HardwareTimerCaps{
            .rdtsc_frequency = 3_000_000_000, // 3 GHz
            .rdtsc_reliable = true,
            .hpet_available = true,
            .hpet_frequency = 14_318_180, // 14.31818 MHz
            .apic_timer_frequency = 100_000_000, // 100 MHz
            .tsc_deadline_supported = true,
            .precision_ns = 1, // 1ns precision with TSC
        };
    }
    
    pub fn getBestTimestampSource(self: *const HardwareTimerCaps) TimestampSource {
        if (self.tsc_deadline_supported and self.rdtsc_reliable) {
            return .tsc_deadline;
        } else if (self.rdtsc_reliable) {
            return .rdtsc;
        } else if (self.hpet_available) {
            return .hpet;
        } else {
            return .apic_timer;
        }
    }
};

/// Frame timing statistics
pub const FrameTimingStats = struct {
    frames_rendered: u64 = 0,
    deadlines_met: u64 = 0,
    deadlines_missed: u64 = 0,
    early_completions: u64 = 0,
    average_frame_time_ns: u64 = 0,
    min_frame_time_ns: u64 = std.math.maxInt(u64),
    max_frame_time_ns: u64 = 0,
    frame_time_variance_ns: u64 = 0,
    vrr_adjustments: u64 = 0,
    
    pub fn update(self: *FrameTimingStats, frame_time_ns: u64, target_time_ns: u64, deadline_met: bool) void {
        self.frames_rendered += 1;
        
        if (deadline_met) {
            self.deadlines_met += 1;
        } else {
            self.deadlines_missed += 1;
        }
        
        if (frame_time_ns < target_time_ns * 9 / 10) { // Completed 10% early
            self.early_completions += 1;
        }
        
        // Update frame time statistics
        const old_avg = self.average_frame_time_ns;
        self.average_frame_time_ns = (old_avg * (self.frames_rendered - 1) + frame_time_ns) / self.frames_rendered;
        
        self.min_frame_time_ns = @min(self.min_frame_time_ns, frame_time_ns);
        self.max_frame_time_ns = @max(self.max_frame_time_ns, frame_time_ns);
        
        // Calculate frame time variance
        const variance = if (frame_time_ns > self.average_frame_time_ns) 
            frame_time_ns - self.average_frame_time_ns 
        else 
            self.average_frame_time_ns - frame_time_ns;
        self.frame_time_variance_ns = (self.frame_time_variance_ns + variance) / 2;
    }
    
    pub fn getDeadlineMissRate(self: *const FrameTimingStats) f32 {
        if (self.frames_rendered == 0) return 0.0;
        return @as(f32, @floatFromInt(self.deadlines_missed)) / @as(f32, @floatFromInt(self.frames_rendered));
    }
    
    pub fn getFrameTimeConsistency(self: *const FrameTimingStats) f32 {
        if (self.average_frame_time_ns == 0) return 1.0;
        const consistency = 1.0 - (@as(f32, @floatFromInt(self.frame_time_variance_ns)) / @as(f32, @floatFromInt(self.average_frame_time_ns)));
        return @max(0.0, consistency);
    }
};

/// Gaming task with hardware timing
const GamingTaskTiming = struct {
    task: *sched.Task,
    timing_requirements: GamingTimingRequirements,
    next_deadline_cycles: u64,   // Next frame deadline in CPU cycles
    last_frame_start_cycles: u64, // When last frame started
    last_frame_time_ns: u64,     // Last frame execution time
    consecutive_misses: u32,     // Consecutive deadline misses
    timing_stats: FrameTimingStats,
    vrr_state: VRRState,
    
    const VRRState = struct {
        enabled: bool = false,
        current_fps: u32 = 60,
        target_fps: u32 = 60,
        adjustment_direction: i8 = 0, // -1 slower, 0 stable, 1 faster
        stability_counter: u32 = 0,
    };
    
    pub fn init(task: *sched.Task, requirements: GamingTimingRequirements) GamingTaskTiming {
        return GamingTaskTiming{
            .task = task,
            .timing_requirements = requirements,
            .next_deadline_cycles = 0,
            .last_frame_start_cycles = 0,
            .last_frame_time_ns = 0,
            .consecutive_misses = 0,
            .timing_stats = FrameTimingStats{},
            .vrr_state = VRRState{
                .enabled = requirements.vrr_enabled,
                .current_fps = requirements.target_fps,
                .target_fps = requirements.target_fps,
            },
        };
    }
    
    pub fn setNextDeadline(self: *GamingTaskTiming, scheduler: *HardwareTimestampScheduler) void {
        const current_cycles = scheduler.getCurrentCycles();
        const frame_time_cycles = scheduler.nanosecondsToCycles(self.timing_requirements.frame_time_ns);
        
        if (self.next_deadline_cycles == 0) {
            // First frame
            self.next_deadline_cycles = current_cycles + frame_time_cycles;
        } else {
            // Subsequent frames - maintain consistent timing
            self.next_deadline_cycles += frame_time_cycles;
            
            // Prevent deadline drift
            if (self.next_deadline_cycles < current_cycles) {
                self.next_deadline_cycles = current_cycles + frame_time_cycles;
            }
        }
        
        self.last_frame_start_cycles = current_cycles;
    }
    
    pub fn updateVRR(self: *GamingTaskTiming, scheduler: *HardwareTimestampScheduler) void {
        if (!self.vrr_state.enabled) return;
        
        const current_cycles = scheduler.getCurrentCycles();
        const actual_frame_time_cycles = current_cycles - self.last_frame_start_cycles;
        const actual_frame_time_ns = scheduler.cyclesToNanoseconds(actual_frame_time_cycles);
        
        // Calculate actual FPS
        const actual_fps = @as(u32, @intFromFloat(1_000_000_000.0 / @as(f32, @floatFromInt(actual_frame_time_ns))));
        
        // Adjust VRR target based on performance
        if (actual_fps < self.vrr_state.current_fps * 95 / 100) {
            // Performance dropping, reduce target FPS
            if (self.vrr_state.adjustment_direction <= 0) {
                self.vrr_state.stability_counter += 1;
            } else {
                self.vrr_state.stability_counter = 0;
            }
            self.vrr_state.adjustment_direction = -1;
        } else if (actual_fps > self.vrr_state.current_fps * 105 / 100) {
            // Performance good, can increase target FPS
            if (self.vrr_state.adjustment_direction >= 0) {
                self.vrr_state.stability_counter += 1;
            } else {
                self.vrr_state.stability_counter = 0;
            }
            self.vrr_state.adjustment_direction = 1;
        } else {
            // Stable performance
            self.vrr_state.adjustment_direction = 0;
            self.vrr_state.stability_counter += 1;
        }
        
        // Apply VRR adjustment if stable for several frames
        if (self.vrr_state.stability_counter >= 5) {
            const old_fps = self.vrr_state.current_fps;
            
            if (self.vrr_state.adjustment_direction < 0) {
                self.vrr_state.current_fps = @max(self.timing_requirements.vrr_min_fps, self.vrr_state.current_fps - 1);
            } else if (self.vrr_state.adjustment_direction > 0) {
                self.vrr_state.current_fps = @min(self.timing_requirements.vrr_max_fps, self.vrr_state.current_fps + 1);
            }
            
            if (old_fps != self.vrr_state.current_fps) {
                // Update frame time for new target FPS
                self.timing_requirements.frame_time_ns = 1_000_000_000 / self.vrr_state.current_fps;
                self.timing_stats.vrr_adjustments += 1;
                
                console.printf("VRR adjustment: PID {} FPS {} -> {}\\n", 
                    .{ self.task.pid, old_fps, self.vrr_state.current_fps });
            }
            
            self.vrr_state.stability_counter = 0;
        }
    }
    
    pub fn isDeadlineMissed(self: *const GamingTaskTiming, scheduler: *HardwareTimestampScheduler) bool {
        const current_cycles = scheduler.getCurrentCycles();
        return current_cycles > self.next_deadline_cycles;
    }
    
    pub fn getCyclesUntilDeadline(self: *const GamingTaskTiming, scheduler: *HardwareTimestampScheduler) u64 {
        const current_cycles = scheduler.getCurrentCycles();
        if (current_cycles >= self.next_deadline_cycles) {
            return 0;
        }
        return self.next_deadline_cycles - current_cycles;
    }
};

/// Hardware Timestamp Scheduler
pub const HardwareTimestampScheduler = struct {
    allocator: std.mem.Allocator,
    timer_caps: HardwareTimerCaps,
    timestamp_source: TimestampSource,
    gaming_tasks: std.HashMap(u32, GamingTaskTiming),
    
    // Timing calibration
    tsc_frequency: u64,
    cycles_per_nanosecond: f64,
    nanoseconds_per_cycle: f64,
    calibration_timestamp: u64,
    
    // Scheduling state
    next_deadline_cycles: u64,
    current_deadline_task: ?u32,
    deadline_timer_set: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const timer_caps = HardwareTimerCaps.detectCapabilities();
        const timestamp_source = timer_caps.getBestTimestampSource();
        
        var scheduler = Self{
            .allocator = allocator,
            .timer_caps = timer_caps,
            .timestamp_source = timestamp_source,
            .gaming_tasks = std.HashMap(u32, GamingTaskTiming).init(allocator),
            .tsc_frequency = timer_caps.rdtsc_frequency,
            .cycles_per_nanosecond = @as(f64, @floatFromInt(timer_caps.rdtsc_frequency)) / 1_000_000_000.0,
            .nanoseconds_per_cycle = 1_000_000_000.0 / @as(f64, @floatFromInt(timer_caps.rdtsc_frequency)),
            .calibration_timestamp = 0,
            .next_deadline_cycles = 0,
            .current_deadline_task = null,
            .deadline_timer_set = false,
        };
        
        // Calibrate timing
        try scheduler.calibrateTiming();
        
        return scheduler;
    }
    
    pub fn deinit(self: *Self) void {
        self.gaming_tasks.deinit();
    }
    
    /// Get current hardware timestamp in CPU cycles
    pub fn getCurrentCycles(self: *Self) u64 {
        return switch (self.timestamp_source) {
            .rdtsc, .tsc_deadline => self.readTSC(),
            .hpet => self.readHPET(),
            .apic_timer => self.readAPICTimer(),
            .perf_counter => self.readPerfCounter(),
        };
    }
    
    /// Convert nanoseconds to CPU cycles
    pub fn nanosecondsToCycles(self: *Self, nanoseconds: u64) u64 {
        return @as(u64, @intFromFloat(@as(f64, @floatFromInt(nanoseconds)) * self.cycles_per_nanosecond));
    }
    
    /// Convert CPU cycles to nanoseconds
    pub fn cyclesToNanoseconds(self: *Self, cycles: u64) u64 {
        return @as(u64, @intFromFloat(@as(f64, @floatFromInt(cycles)) * self.nanoseconds_per_cycle));
    }
    
    /// Register gaming task for hardware timestamp scheduling
    pub fn registerGamingTask(self: *Self, task: *sched.Task, fps: u32) !void {
        const requirements = GamingTimingRequirements.fromFPS(fps);
        const gaming_timing = GamingTaskTiming.init(task, requirements);
        
        try self.gaming_tasks.put(task.pid, gaming_timing);
        
        console.printf("Registered gaming task PID {} for {}fps hardware timing\\n", .{ task.pid, fps });
    }
    
    /// Unregister gaming task
    pub fn unregisterGamingTask(self: *Self, pid: u32) void {
        _ = self.gaming_tasks.remove(pid);
        console.printf("Unregistered gaming task PID {}\\n", .{pid});
    }
    
    /// Mark frame start for a gaming task
    pub fn markFrameStart(self: *Self, pid: u32) !void {
        if (self.gaming_tasks.getPtr(pid)) |gaming_timing| {
            gaming_timing.setNextDeadline(self);
            
            // Set hardware deadline timer if this is the next deadline
            try self.updateDeadlineTimer();
            
            console.printf("Frame start: PID {} deadline in {}ns\\n", 
                .{ pid, self.cyclesToNanoseconds(gaming_timing.getCyclesUntilDeadline(self)) });
        }
    }
    
    /// Mark frame completion for a gaming task
    pub fn markFrameComplete(self: *Self, pid: u32) !void {
        if (self.gaming_tasks.getPtr(pid)) |gaming_timing| {
            const current_cycles = self.getCurrentCycles();
            const frame_time_cycles = current_cycles - gaming_timing.last_frame_start_cycles;
            const frame_time_ns = self.cyclesToNanoseconds(frame_time_cycles);
            
            // Check if deadline was met
            const deadline_met = !gaming_timing.isDeadlineMissed(self);
            
            // Update statistics
            gaming_timing.timing_stats.update(
                frame_time_ns, 
                gaming_timing.timing_requirements.frame_time_ns, 
                deadline_met
            );
            
            // Update VRR if enabled
            gaming_timing.updateVRR(self);
            
            // Track consecutive misses
            if (deadline_met) {
                gaming_timing.consecutive_misses = 0;
            } else {
                gaming_timing.consecutive_misses += 1;
                
                // Emergency priority boost for repeated misses
                if (gaming_timing.consecutive_misses >= 3) {
                    gaming_timing.task.priority = @max(-20, gaming_timing.task.priority - 5);
                    console.printf("Emergency priority boost for PID {} (misses: {})\\n", 
                        .{ pid, gaming_timing.consecutive_misses });
                }
            }
            
            console.printf("Frame complete: PID {} time {}ns deadline {} miss_rate {d:.1}%\\n", 
                .{ pid, frame_time_ns, if (deadline_met) "MET" else "MISSED", 
                   gaming_timing.timing_stats.getDeadlineMissRate() * 100 });
        }
    }
    
    /// Check for deadline violations and schedule accordingly
    pub fn checkDeadlines(self: *Self) !void {
        const current_cycles = self.getCurrentCycles();
        var next_deadline: ?u64 = null;
        var next_deadline_pid: ?u32 = null;
        
        var iter = self.gaming_tasks.iterator();
        while (iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            const gaming_timing = entry.value_ptr;
            
            // Check if task missed its deadline
            if (gaming_timing.isDeadlineMissed(self) and gaming_timing.task.state == .running) {
                // Immediate priority boost for deadline miss
                gaming_timing.task.priority = @max(-20, gaming_timing.task.priority - 2);
                console.printf("Deadline miss: PID {} boosted to priority {}\\n", 
                    .{ pid, gaming_timing.task.priority });
            }
            
            // Find next upcoming deadline
            if (gaming_timing.next_deadline_cycles > current_cycles) {
                if (next_deadline == null or gaming_timing.next_deadline_cycles < next_deadline.?) {
                    next_deadline = gaming_timing.next_deadline_cycles;
                    next_deadline_pid = pid;
                }
            }
        }
        
        // Update deadline timer if needed
        if (next_deadline) |deadline_cycles| {
            if (deadline_cycles != self.next_deadline_cycles) {
                self.next_deadline_cycles = deadline_cycles;
                self.current_deadline_task = next_deadline_pid;
                try self.setHardwareDeadlineTimer(deadline_cycles);
            }
        }
    }
    
    fn calibrateTiming(self: *Self) !void {
        // Calibrate TSC frequency and timing conversion
        const calibration_start_ns = std.time.nanoTimestamp();
        const calibration_start_cycles = self.readTSC();
        
        // Wait for calibration period
        std.time.sleep(10_000_000); // 10ms
        
        const calibration_end_ns = std.time.nanoTimestamp();
        const calibration_end_cycles = self.readTSC();
        
        // Calculate actual frequencies
        const elapsed_ns = @as(u64, @intCast(calibration_end_ns - calibration_start_ns));
        const elapsed_cycles = calibration_end_cycles - calibration_start_cycles;
        
        if (elapsed_ns > 0 and elapsed_cycles > 0) {
            self.cycles_per_nanosecond = @as(f64, @floatFromInt(elapsed_cycles)) / @as(f64, @floatFromInt(elapsed_ns));
            self.nanoseconds_per_cycle = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(elapsed_cycles));
            self.tsc_frequency = elapsed_cycles * 1_000_000_000 / elapsed_ns;
            
            console.printf("Timing calibrated: TSC frequency {}Hz precision {}ns\\n", 
                .{ self.tsc_frequency, self.cyclesToNanoseconds(1) });
        }
    }
    
    fn updateDeadlineTimer(self: *Self) !void {
        // Find the earliest deadline among all gaming tasks
        var earliest_deadline: ?u64 = null;
        var earliest_pid: ?u32 = null;
        
        var iter = self.gaming_tasks.iterator();
        while (iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            const gaming_timing = entry.value_ptr;
            
            if (gaming_timing.next_deadline_cycles > 0) {
                if (earliest_deadline == null or gaming_timing.next_deadline_cycles < earliest_deadline.?) {
                    earliest_deadline = gaming_timing.next_deadline_cycles;
                    earliest_pid = pid;
                }
            }
        }
        
        if (earliest_deadline) |deadline_cycles| {
            if (deadline_cycles != self.next_deadline_cycles) {
                self.next_deadline_cycles = deadline_cycles;
                self.current_deadline_task = earliest_pid;
                try self.setHardwareDeadlineTimer(deadline_cycles);
            }
        }
    }
    
    fn setHardwareDeadlineTimer(self: *Self, deadline_cycles: u64) !void {
        switch (self.timestamp_source) {
            .tsc_deadline => {
                // Set TSC deadline timer
                self.setTSCDeadlineTimer(deadline_cycles);
            },
            .apic_timer => {
                // Set APIC timer
                const current_cycles = self.getCurrentCycles();
                if (deadline_cycles > current_cycles) {
                    const cycles_until_deadline = deadline_cycles - current_cycles;
                    const timer_value = cycles_until_deadline * self.timer_caps.apic_timer_frequency / self.tsc_frequency;
                    self.setAPICTimer(@intCast(timer_value));
                }
            },
            else => {
                // Software-based timer fallback
            },
        }
        
        self.deadline_timer_set = true;
    }
    
    // Hardware timer access functions (architecture-specific)
    fn readTSC(self: *Self) u64 {
        _ = self;
        // In real implementation, use inline assembly: rdtsc
        return @as(u64, @intCast(std.time.nanoTimestamp())); // Mock with system timer
    }
    
    fn readHPET(self: *Self) u64 {
        _ = self;
        // In real implementation, read HPET counter register
        return @as(u64, @intCast(std.time.nanoTimestamp()));
    }
    
    fn readAPICTimer(self: *Self) u64 {
        _ = self;
        // In real implementation, read APIC timer current count
        return @as(u64, @intCast(std.time.nanoTimestamp()));
    }
    
    fn readPerfCounter(self: *Self) u64 {
        _ = self;
        // In real implementation, read performance monitoring counter
        return @as(u64, @intCast(std.time.nanoTimestamp()));
    }
    
    fn setTSCDeadlineTimer(self: *Self, deadline_cycles: u64) void {
        _ = self;
        _ = deadline_cycles;
        // In real implementation, write to IA32_TSC_DEADLINE MSR
    }
    
    fn setAPICTimer(self: *Self, timer_value: u32) void {
        _ = self;
        _ = timer_value;
        // In real implementation, write to APIC timer registers
    }
    
    pub fn getGamingTaskStats(self: *Self, pid: u32) ?FrameTimingStats {
        if (self.gaming_tasks.get(pid)) |gaming_timing| {
            return gaming_timing.timing_stats;
        }
        return null;
    }
    
    pub fn enableGamingMode(self: *Self) void {
        // Optimize for gaming workloads
        console.printf("Hardware timestamp scheduler: Gaming mode enabled (source: {s})\\n", 
            .{@tagName(self.timestamp_source)});
    }
};

// Global hardware timestamp scheduler
var global_hw_timestamp_scheduler: ?*HardwareTimestampScheduler = null;

/// Initialize hardware timestamp scheduling
pub fn initHardwareTimestampScheduling(allocator: std.mem.Allocator) !void {
    const scheduler = try allocator.create(HardwareTimestampScheduler);
    scheduler.* = try HardwareTimestampScheduler.init(allocator);
    
    // Enable gaming optimizations
    scheduler.enableGamingMode();
    
    global_hw_timestamp_scheduler = scheduler;
    
    console.writeString("Hardware timestamp scheduling initialized\\n");
}

pub fn getHardwareTimestampScheduler() *HardwareTimestampScheduler {
    return global_hw_timestamp_scheduler.?;
}

// Export for scheduler integration
pub fn onGamingTaskCreate(task: *sched.Task, target_fps: u32) !void {
    const scheduler = getHardwareTimestampScheduler();
    try scheduler.registerGamingTask(task, target_fps);
}

pub fn onGamingTaskDestroy(pid: u32) void {
    const scheduler = getHardwareTimestampScheduler();
    scheduler.unregisterGamingTask(pid);
}

pub fn onFrameStart(pid: u32) !void {
    const scheduler = getHardwareTimestampScheduler();
    try scheduler.markFrameStart(pid);
}

pub fn onFrameComplete(pid: u32) !void {
    const scheduler = getHardwareTimestampScheduler();
    try scheduler.markFrameComplete(pid);
}

pub fn periodicDeadlineCheck() !void {
    const scheduler = getHardwareTimestampScheduler();
    try scheduler.checkDeadlines();
}