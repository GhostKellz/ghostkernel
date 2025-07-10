//! Linux ZGhost BORE-EEVDF Scheduler
//! Pure Zig implementation of BORE-enhanced EEVDF scheduler

const std = @import("std");
const console = @import("../arch/x86_64/console.zig");

/// Task states in the scheduler
pub const TaskState = enum {
    created,
    ready,
    running,
    blocked,
    zombie,
    dead,
};

/// Scheduling class for tasks
pub const SchedClass = enum {
    idle,       // Idle tasks
    normal,     // Normal EEVDF tasks
    batch,      // Batch/background tasks
    realtime,   // Real-time tasks
    deadline,   // Deadline tasks
};

/// Task Control Block (TCB)
pub const Task = struct {
    pid: u32,
    state: TaskState,
    sched_class: SchedClass,
    priority: i8,           // Nice value (-20 to +19)
    
    // EEVDF scheduling parameters
    vruntime: u64,          // Virtual runtime
    deadline: u64,          // Virtual deadline
    slice: u64,             // Time slice
    lag: i64,               // Lag (negative = ahead, positive = behind)
    
    // BORE enhancements
    burst_time: u64,        // Recent burst duration
    burst_score: u32,       // Burst score (0-39)
    prev_burst: u64,        // Previous burst time
    bore_penalty: u32,      // Current BORE penalty
    
    // Gaming optimizations
    gaming_task: bool,      // Is this a gaming-related task?
    frame_critical: bool,   // Is this frame-critical?
    input_task: bool,       // Is this an input handling task?
    audio_task: bool,       // Is this an audio processing task?
    vrr_sync: bool,         // Is this VRR synchronization task?
    
    // Task timing
    exec_start: u64,        // When task started executing
    sum_exec_runtime: u64,  // Total execution time
    last_ran: u64,          // Last time task ran
    wakeup_time: u64,       // When task was last woken up
    
    // Performance metrics
    avg_runtime: u64,       // Average runtime per execution
    max_runtime: u64,       // Maximum runtime observed
    preemption_count: u32,  // Number of preemptions
    voluntary_switches: u32, // Voluntary context switches
    
    // Scheduling metadata
    weight: u32,            // Load weight based on priority
    inv_weight: u32,        // Inverse weight for calculations
    gaming_boost: u32,      // Gaming performance boost
    
    // Runqueue node
    rb_node: ?*RBNode,      // Red-black tree node for EEVDF timeline
    
    const Self = @This();
    
    pub fn init(pid: u32, priority: i8) Self {
        const weight = priorityToWeight(priority);
        return Self{
            .pid = pid,
            .state = .created,
            .sched_class = .normal,
            .priority = priority,
            .vruntime = 0,
            .deadline = 0,
            .slice = 0,
            .lag = 0,
            .burst_time = 0,
            .burst_score = 0,
            .prev_burst = 0,
            .bore_penalty = 0,
            .gaming_task = false,
            .frame_critical = false,
            .input_task = false,
            .audio_task = false,
            .vrr_sync = false,
            .exec_start = 0,
            .sum_exec_runtime = 0,
            .last_ran = 0,
            .wakeup_time = 0,
            .avg_runtime = 0,
            .max_runtime = 0,
            .preemption_count = 0,
            .voluntary_switches = 0,
            .weight = weight,
            .inv_weight = WMULT_CONST / weight,
            .gaming_boost = 0,
            .rb_node = null,
        };
    }
    
    /// Calculate task's virtual deadline
    pub fn calculateDeadline(self: *Self, now_ns: u64) void {
        _ = now_ns;
        var slice_ns = self.slice;
        
        // Gaming tasks get tighter deadlines for better responsiveness
        if (self.gaming_task) {
            slice_ns = slice_ns * 3 / 4; // 25% tighter deadline
        }
        
        // Frame-critical tasks get even tighter deadlines
        if (self.frame_critical) {
            slice_ns = slice_ns / 2; // 50% tighter deadline
        }
        
        // Input tasks get the tightest deadlines
        if (self.input_task) {
            slice_ns = slice_ns / 3; // 67% tighter deadline
        }
        
        self.deadline = self.vruntime + slice_ns;
    }
    
    /// Mark task as gaming-related
    pub fn setGamingTask(self: *Self, gaming: bool) void {
        self.gaming_task = gaming;
        if (gaming) {
            self.gaming_boost = 2048; // 2x boost
            // Reduce BORE penalty for gaming tasks
            self.bore_penalty = self.bore_penalty / 2;
        } else {
            self.gaming_boost = 0;
        }
    }
    
    /// Mark task as frame-critical
    pub fn setFrameCritical(self: *Self, critical: bool) void {
        self.frame_critical = critical;
        if (critical) {
            self.gaming_task = true; // Frame-critical implies gaming
            self.gaming_boost = 4096; // 4x boost
        }
    }
    
    /// Mark task as input handler
    pub fn setInputTask(self: *Self, input: bool) void {
        self.input_task = input;
        if (input) {
            self.gaming_task = true; // Input handling implies gaming
            self.gaming_boost = 8192; // 8x boost - highest priority
        }
    }
    
    /// Mark task as audio processing
    pub fn setAudioTask(self: *Self, audio: bool) void {
        self.audio_task = audio;
        if (audio) {
            self.gaming_boost = 3072; // 3x boost
        }
    }
    
    /// Get effective weight with gaming boost
    pub fn getEffectiveWeight(self: *Self) u32 {
        if (self.gaming_boost > 0) {
            return self.weight + self.gaming_boost;
        }
        return self.weight;
    }
    
    /// Update BORE burst score based on recent execution
    pub fn updateBurstScore(self: *Self, exec_time: u64) void {
        self.prev_burst = self.burst_time;
        self.burst_time = exec_time;
        
        // Calculate burst score (0-39, higher = more bursty)
        if (exec_time > SCHED_SLICE_MIN * 4) {
            self.burst_score = @min(39, self.burst_score + 1);
        } else if (exec_time < SCHED_SLICE_MIN / 2) {
            self.burst_score = @max(0, self.burst_score - 1);
        }
    }
    
    /// Check if task is eligible to run (EEVDF)
    pub fn isEligible(self: *Self, cfs_rq: *RunQueue) bool {
        return self.vruntime <= cfs_rq.min_vruntime;
    }
};

/// Red-black tree node for EEVDF timeline
pub const RBNode = struct {
    task: *Task,
    parent: ?*RBNode,
    left: ?*RBNode,
    right: ?*RBNode,
    color: Color,
    
    pub const Color = enum { red, black };
};

/// CFS/EEVDF Run Queue
pub const RunQueue = struct {
    // Timeline tree (red-black tree ordered by virtual deadline)
    timeline_root: ?*RBNode,
    leftmost: ?*RBNode,    // Task with earliest deadline
    
    // EEVDF state
    min_vruntime: u64,     // Global virtual time
    avg_vruntime: u64,     // Average virtual runtime
    
    // Load tracking
    load_weight: u32,      // Total weight of runnable tasks
    nr_running: u32,       // Number of runnable tasks
    
    // Current running task
    current: ?*Task,
    
    // BORE parameters
    bore_enabled: bool,
    burst_penalty: u32,    // Penalty for bursty tasks
    
    // Gaming optimizations
    gaming_mode: bool,     // Global gaming mode
    frame_sync_enabled: bool, // Frame synchronization
    input_boost: u32,      // Input task boost multiplier
    audio_boost: u32,      // Audio task boost multiplier
    frame_deadline_ns: u64, // Frame deadline in nanoseconds (for VRR)
    
    // Performance metrics
    gaming_tasks: u32,     // Number of gaming tasks
    frame_critical_tasks: u32, // Number of frame-critical tasks
    input_tasks: u32,      // Number of input tasks
    audio_tasks: u32,      // Number of audio tasks
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .timeline_root = null,
            .leftmost = null,
            .min_vruntime = 0,
            .avg_vruntime = 0,
            .load_weight = 0,
            .nr_running = 0,
            .current = null,
            .bore_enabled = true,
            .burst_penalty = 8, // Default BORE penalty
            .gaming_mode = false,
            .frame_sync_enabled = false,
            .input_boost = 4,
            .audio_boost = 2,
            .frame_deadline_ns = 16666666, // 60 FPS default
            .gaming_tasks = 0,
            .frame_critical_tasks = 0,
            .input_tasks = 0,
            .audio_tasks = 0,
        };
    }
    
    /// Add task to the runqueue
    pub fn enqueueTask(self: *Self, task: *Task) void {
        task.state = .ready;
        
        // Initialize virtual runtime for new tasks
        if (task.vruntime == 0) {
            task.vruntime = self.min_vruntime;
            // Apply lag for new tasks (small boost)
            task.lag = -@as(i64, @intCast(SCHED_SLICE_MIN / 2));
        }
        
        // Calculate time slice based on priority and BORE score
        task.slice = calculateTimeSlice(task);
        
        // Apply BORE penalty for bursty tasks
        if (self.bore_enabled and task.burst_score > 20) {
            const penalty = (task.burst_score - 20) * self.burst_penalty;
            task.vruntime += penalty;
        }
        
        // Calculate deadline
        task.calculateDeadline(getCurrentTime());
        
        // Insert into timeline tree
        self.insertTask(task);
        
        self.nr_running += 1;
        self.load_weight += task.weight;
        
        self.updateMinVruntime();
    }
    
    /// Remove task from runqueue
    pub fn dequeueTask(self: *Self, task: *Task) void {
        self.removeTask(task);
        
        self.nr_running -= 1;
        self.load_weight -= task.weight;
        
        self.updateMinVruntime();
    }
    
    /// Enable gaming mode optimizations
    pub fn enableGamingMode(self: *Self) void {
        self.gaming_mode = true;
        self.burst_penalty = 4; // Reduced BORE penalty for gaming
        self.frame_sync_enabled = true;
        
        // Boost gaming tasks
        // This would typically iterate through tasks and update their priorities
    }
    
    /// Disable gaming mode optimizations
    pub fn disableGamingMode(self: *Self) void {
        self.gaming_mode = false;
        self.burst_penalty = 8; // Default BORE penalty
        self.frame_sync_enabled = false;
    }
    
    /// Set frame rate for VRR synchronization
    pub fn setFrameRate(self: *Self, fps: u32) void {
        if (fps > 0) {
            self.frame_deadline_ns = 1_000_000_000 / fps;
        }
    }
    
    /// Check if we're approaching frame deadline
    pub fn isFrameDeadlineApproaching(self: *Self, current_time: u64) bool {
        if (!self.frame_sync_enabled) return false;
        
        // Calculate time until next frame
        const frame_start = current_time - (current_time % self.frame_deadline_ns);
        const next_frame = frame_start + self.frame_deadline_ns;
        const time_until_frame = next_frame - current_time;
        
        // Consider approaching if less than 25% of frame time remains
        return time_until_frame < (self.frame_deadline_ns / 4);
    }
    
    /// Pick next task to run (EEVDF algorithm with gaming optimizations)
    pub fn pickNext(self: *Self) ?*Task {
        // Start with leftmost (earliest deadline)
        var best = self.leftmost;
        if (best == null) return null;
        
        var node = best;
        var gaming_best: ?*RBNode = null;
        var input_best: ?*RBNode = null;
        
        const current_time = getCurrentTime();
        const frame_deadline_approaching = self.isFrameDeadlineApproaching(current_time);
        
        // Find the eligible task with earliest deadline
        while (node) |n| {
            const task = n.task;
            
            // Check if task is eligible (virtual runtime <= min_vruntime)
            if (task.isEligible(self)) {
                // Prioritize input tasks always
                if (task.input_task) {
                    if (input_best == null or task.deadline < input_best.?.task.deadline) {
                        input_best = n;
                    }
                }
                
                // Prioritize frame-critical tasks when frame deadline approaches
                if (frame_deadline_approaching and task.frame_critical) {
                    if (gaming_best == null or task.deadline < gaming_best.?.task.deadline) {
                        gaming_best = n;
                    }
                }
                
                // Among eligible tasks, prefer the one with earliest deadline
                if (best == null or task.deadline < best.?.task.deadline) {
                    best = n;
                }
            }
            
            node = getNextNode(n);
        }
        
        // Priority order: input > frame-critical (when deadline approaching) > normal
        if (input_best) |ib| {
            return ib.task;
        }
        
        if (gaming_best) |gb| {
            return gb.task;
        }
        
        return if (best) |b| b.task else null;
    }
    
    /// Update task's virtual runtime after execution
    pub fn updateCurrent(self: *Self, exec_time: u64) void {
        if (self.current) |task| {
            // Calculate virtual runtime delta
            const delta_vruntime = calcDeltaVruntime(exec_time, task.weight);
            task.vruntime += delta_vruntime;
            
            // Update BORE burst tracking
            task.updateBurstScore(exec_time);
            
            // Update total execution time
            task.sum_exec_runtime += exec_time;
            task.last_ran = getCurrentTime();
            
            self.updateMinVruntime();
        }
    }
    
    /// Check if current task should be preempted
    pub fn shouldPreempt(self: *Self) bool {
        const current = self.current orelse return false;
        
        // Check if there's a better task to run
        const next = self.pickNext() orelse return false;
        
        // Don't preempt self
        if (next.pid == current.pid) return false;
        
        // Preempt if next task has earlier deadline and is eligible
        if (next.deadline < current.deadline and next.isEligible(self)) {
            return true;
        }
        
        // BORE: Preempt bursty tasks more aggressively
        if (self.bore_enabled and current.burst_score > 25) {
            const lag_threshold = @as(i64, @intCast(SCHED_SLICE_MIN));
            if (next.lag < -lag_threshold) {
                return true;
            }
        }
        
        return false;
    }
    
    // Internal helper methods
    fn insertTask(self: *Self, task: *Task) void {
        // TODO: Implement red-black tree insertion
        // For now, simple linked list simulation
        _ = self;
        _ = task;
    }
    
    fn removeTask(self: *Self, task: *Task) void {
        // TODO: Implement red-black tree removal
        _ = self;
        _ = task;
    }
    
    fn updateMinVruntime(self: *Self) void {
        if (self.current) |task| {
            self.min_vruntime = @max(self.min_vruntime, task.vruntime);
        }
        
        if (self.leftmost) |node| {
            const leftmost_vruntime = node.task.vruntime;
            if (self.current == null) {
                self.min_vruntime = leftmost_vruntime;
            } else {
                self.min_vruntime = @min(self.min_vruntime, leftmost_vruntime);
            }
        }
    }
};

// Scheduler constants
const SCHED_SLICE_MIN: u64 = 750_000; // 0.75ms minimum slice
const SCHED_SLICE_MAX: u64 = 6_000_000; // 6ms maximum slice
const WMULT_CONST: u32 = 1 << 32;

/// Scheduler performance metrics
pub const SchedulerMetrics = struct {
    nr_running: u32 = 0,
    gaming_tasks: u32 = 0,
    frame_critical_tasks: u32 = 0,
    input_tasks: u32 = 0,
    audio_tasks: u32 = 0,
    gaming_mode: bool = false,
    frame_deadline_ns: u64 = 0,
    min_vruntime: u64 = 0,
    avg_vruntime: u64 = 0,
    bore_enabled: bool = false,
    burst_penalty: u32 = 0,
};

// Priority to weight mapping (from Linux kernel)
const PRIO_WEIGHTS = [_]u32{
    88761, 71755, 56483, 46273, 36291, // -20 to -16
    29154, 23254, 18705, 14949, 11916, // -15 to -11  
    9548,  7620,  6100,  4904,  3906,  // -10 to -6
    3121,  2501,  1991,  1586,  1277,  // -5 to -1
    1024,  820,   655,   526,   423,   // 0 to 4
    335,   272,   215,   172,   137,   // 5 to 9
    110,   87,    70,    56,    45,    // 10 to 14
    36,    29,    23,    18,    15,    // 15 to 19
};

/// Global scheduler state
var main_runqueue: RunQueue = undefined;
var scheduler_initialized = false;
var gaming_mode_enabled = false;

/// Initialize the scheduler
pub fn init() !void {
    main_runqueue = RunQueue.init();
    scheduler_initialized = true;
    
    console.writeString("BORE-EEVDF scheduler initialized\n");
}

/// Main scheduler tick
pub fn tick() void {
    if (!scheduler_initialized) return;
    
    // Update current task's runtime
    if (main_runqueue.current) |task| {
        const now = getCurrentTime();
        const exec_time = now - task.exec_start;
        
        if (exec_time > 0) {
            main_runqueue.updateCurrent(exec_time);
            
            // Check for preemption
            if (main_runqueue.shouldPreempt()) {
                schedule();
            }
        }
    }
}

/// Main scheduling function
pub fn schedule() void {
    if (!scheduler_initialized) return;
    
    // Save current task
    if (main_runqueue.current) |current| {
        if (current.state == .running) {
            current.state = .ready;
            main_runqueue.enqueueTask(current);
        }
    }
    
    // Pick next task
    const next = main_runqueue.pickNext();
    
    if (next) |task| {
        main_runqueue.current = task;
        task.state = .running;
        task.exec_start = getCurrentTime();
        main_runqueue.dequeueTask(task);
        
        // TODO: Perform actual context switch
        switchTo(task);
    } else {
        main_runqueue.current = null;
        // No runnable tasks, idle
    }
}

/// Check if there are runnable tasks
pub fn hasRunnableTasks() bool {
    return scheduler_initialized and main_runqueue.nr_running > 0;
}

/// Enable global gaming mode
pub fn enableGamingMode() void {
    if (!scheduler_initialized) return;
    
    gaming_mode_enabled = true;
    main_runqueue.enableGamingMode();
    
    console.writeString("Gaming mode enabled - BORE-EEVDF optimized for gaming\n");
}

/// Disable global gaming mode
pub fn disableGamingMode() void {
    if (!scheduler_initialized) return;
    
    gaming_mode_enabled = false;
    main_runqueue.disableGamingMode();
    
    console.writeString("Gaming mode disabled - BORE-EEVDF back to normal\n");
}

/// Set frame rate for VRR synchronization
pub fn setGamingFrameRate(fps: u32) void {
    if (!scheduler_initialized) return;
    
    main_runqueue.setFrameRate(fps);
    console.writeString("Gaming frame rate set to ");
    // TODO: Add number printing
    console.writeString(" FPS\n");
}

/// Mark a task as gaming-related
pub fn markTaskAsGaming(task: *Task) void {
    task.setGamingTask(true);
    if (gaming_mode_enabled) {
        main_runqueue.gaming_tasks += 1;
    }
}

/// Mark a task as frame-critical
pub fn markTaskAsFrameCritical(task: *Task) void {
    task.setFrameCritical(true);
    if (gaming_mode_enabled) {
        main_runqueue.frame_critical_tasks += 1;
    }
}

/// Mark a task as input handler
pub fn markTaskAsInputHandler(task: *Task) void {
    task.setInputTask(true);
    if (gaming_mode_enabled) {
        main_runqueue.input_tasks += 1;
    }
}

/// Mark a task as audio processor
pub fn markTaskAsAudioProcessor(task: *Task) void {
    task.setAudioTask(true);
    if (gaming_mode_enabled) {
        main_runqueue.audio_tasks += 1;
    }
}

/// Get scheduler performance metrics
pub fn getSchedulerMetrics() SchedulerMetrics {
    if (!scheduler_initialized) {
        return SchedulerMetrics{};
    }
    
    return SchedulerMetrics{
        .nr_running = main_runqueue.nr_running,
        .gaming_tasks = main_runqueue.gaming_tasks,
        .frame_critical_tasks = main_runqueue.frame_critical_tasks,
        .input_tasks = main_runqueue.input_tasks,
        .audio_tasks = main_runqueue.audio_tasks,
        .gaming_mode = gaming_mode_enabled,
        .frame_deadline_ns = main_runqueue.frame_deadline_ns,
        .min_vruntime = main_runqueue.min_vruntime,
        .avg_vruntime = main_runqueue.avg_vruntime,
        .bore_enabled = main_runqueue.bore_enabled,
        .burst_penalty = main_runqueue.burst_penalty,
    };
}

/// Create a new task
pub fn createTask(priority: i8) !*Task {
    // TODO: Implement proper task allocation
    // For now, return a dummy task
    _ = priority;
    return undefined;
}

// Helper functions
fn priorityToWeight(priority: i8) u32 {
    const index: usize = @intCast(priority + 20); // -20 to +19 -> 0 to 39
    if (index < PRIO_WEIGHTS.len) {
        return PRIO_WEIGHTS[index];
    }
    return 1024; // Default weight
}

fn calculateTimeSlice(task: *Task) u64 {
    // Base slice scaled by weight
    const base_slice = SCHED_SLICE_MIN * 6; // 4.5ms base
    const weighted_slice = (base_slice * 1024) / task.weight;
    
    return std.math.clamp(weighted_slice, SCHED_SLICE_MIN, SCHED_SLICE_MAX);
}

fn calcDeltaVruntime(exec_time: u64, weight: u32) u64 {
    // Convert real time to virtual time based on weight
    return (exec_time * 1024) / weight;
}

fn getCurrentTime() u64 {
    // TODO: Implement proper timer
    return 0;
}

fn getNextNode(node: *RBNode) ?*RBNode {
    // TODO: Implement red-black tree traversal
    _ = node;
    return null;
}

fn switchTo(task: *Task) void {
    // TODO: Implement context switching
    _ = task;
}