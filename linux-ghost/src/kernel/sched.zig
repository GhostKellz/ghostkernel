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
    
    // Task timing
    exec_start: u64,        // When task started executing
    sum_exec_runtime: u64,  // Total execution time
    last_ran: u64,          // Last time task ran
    
    // Scheduling metadata
    weight: u32,            // Load weight based on priority
    inv_weight: u32,        // Inverse weight for calculations
    
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
            .exec_start = 0,
            .sum_exec_runtime = 0,
            .last_ran = 0,
            .weight = weight,
            .inv_weight = WMULT_CONST / weight,
            .rb_node = null,
        };
    }
    
    /// Calculate task's virtual deadline
    pub fn calculateDeadline(self: *Self, now_ns: u64) void {
        const slice_ns = self.slice;
        self.deadline = self.vruntime + slice_ns;
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
    
    /// Pick next task to run (EEVDF algorithm)
    pub fn pickNext(self: *Self) ?*Task {
        // Start with leftmost (earliest deadline)
        var best = self.leftmost;
        if (best == null) return null;
        
        var node = best;
        
        // Find the eligible task with earliest deadline
        while (node) |n| {
            const task = n.task;
            
            // Check if task is eligible (virtual runtime <= min_vruntime)
            if (task.isEligible(self)) {
                // Among eligible tasks, prefer the one with earliest deadline
                if (best == null or task.deadline < best.?.task.deadline) {
                    best = n;
                }
            }
            
            node = getNextNode(n);
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