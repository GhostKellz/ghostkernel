//! Synchronization Primitives
//! Spinlocks, mutexes, semaphores, and RCU for the Zig kernel

const std = @import("std");
const atomic = std.atomic;
const process = @import("process.zig");
const sched = @import("sched.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");

/// Spinlock implementation
pub const SpinLock = struct {
    locked: atomic.Value(bool),
    owner: ?*process.Process,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .locked = atomic.Value(bool).init(false),
            .owner = null,
        };
    }
    
    pub fn lock(self: *Self) void {
        // Disable interrupts to prevent deadlock
        const irq_state = interrupts.areEnabled();
        interrupts.disable();
        
        // Spin until we acquire the lock
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            while (self.locked.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
        
        self.owner = process.getCurrentProcess();
        
        // Restore interrupt state
        if (irq_state) {
            interrupts.enable();
        }
    }
    
    pub fn unlock(self: *Self) void {
        self.owner = null;
        self.locked.store(false, .release);
    }
    
    pub fn tryLock(self: *Self) bool {
        if (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
            self.owner = process.getCurrentProcess();
            return true;
        }
        return false;
    }
    
    pub fn isLocked(self: *Self) bool {
        return self.locked.load(.monotonic);
    }
};

/// Read-Write Spinlock
pub const RwSpinLock = struct {
    lock: atomic.Value(i32),
    
    const Self = @This();
    const WRITER: i32 = -1;
    
    pub fn init() Self {
        return Self{
            .lock = atomic.Value(i32).init(0),
        };
    }
    
    pub fn readLock(self: *Self) void {
        while (true) {
            const current = self.lock.load(.monotonic);
            if (current >= 0) {
                if (self.lock.cmpxchgWeak(current, current + 1, .acquire, .monotonic) == null) {
                    break;
                }
            }
            std.atomic.spinLoopHint();
        }
    }
    
    pub fn readUnlock(self: *Self) void {
        _ = self.lock.fetchSub(1, .release);
    }
    
    pub fn writeLock(self: *Self) void {
        while (self.lock.cmpxchgWeak(0, WRITER, .acquire, .monotonic) != null) {
            while (self.lock.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }
    
    pub fn writeUnlock(self: *Self) void {
        self.lock.store(0, .release);
    }
};

/// Mutex (sleeping lock)
pub const Mutex = struct {
    locked: atomic.Value(bool),
    owner: ?*process.Process,
    waiters: WaitQueue,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .locked = atomic.Value(bool).init(false),
            .owner = null,
            .waiters = WaitQueue.init(),
        };
    }
    
    pub fn lock(self: *Self) void {
        const current = process.getCurrentProcess() orelse return;
        
        // Fast path - try to acquire
        if (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) == null) {
            self.owner = current;
            return;
        }
        
        // Slow path - add to wait queue and sleep
        self.waiters.add(current);
        
        while (self.locked.load(.monotonic)) {
            current.state = .sleeping;
            sched.schedule();
            
            // Try again after wakeup
            if (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) == null) {
                self.owner = current;
                self.waiters.remove(current);
                return;
            }
        }
    }
    
    pub fn unlock(self: *Self) void {
        self.owner = null;
        self.locked.store(false, .release);
        
        // Wake up one waiter
        if (self.waiters.removeFirst()) |waiter| {
            waiter.state = .runnable;
        }
    }
    
    pub fn tryLock(self: *Self) bool {
        if (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
            self.owner = process.getCurrentProcess();
            return true;
        }
        return false;
    }
};

/// Semaphore
pub const Semaphore = struct {
    count: atomic.Value(i32),
    waiters: WaitQueue,
    
    const Self = @This();
    
    pub fn init(initial: i32) Self {
        return Self{
            .count = atomic.Value(i32).init(initial),
            .waiters = WaitQueue.init(),
        };
    }
    
    pub fn wait(self: *Self) void {
        const current = process.getCurrentProcess() orelse return;
        
        // Try to decrement
        while (true) {
            const c = self.count.load(.monotonic);
            if (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) {
                    return;
                }
            } else {
                // Sleep until count > 0
                self.waiters.add(current);
                current.state = .sleeping;
                sched.schedule();
                self.waiters.remove(current);
            }
        }
    }
    
    pub fn signal(self: *Self) void {
        _ = self.count.fetchAdd(1, .release);
        
        // Wake up one waiter
        if (self.waiters.removeFirst()) |waiter| {
            waiter.state = .runnable;
        }
    }
    
    pub fn tryWait(self: *Self) bool {
        while (true) {
            const c = self.count.load(.monotonic);
            if (c <= 0) return false;
            
            if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) {
                return true;
            }
        }
    }
};

/// Read-Copy-Update (RCU) implementation
pub const RCU = struct {
    grace_period: atomic.Value(u64),
    reader_count: atomic.Value(u32),
    callbacks: CallbackList,
    
    const Self = @This();
    
    const RCUCallback = struct {
        func: *const fn (*anyopaque) void,
        data: *anyopaque,
        grace_period: u64,
        next: ?*RCUCallback,
    };
    
    const CallbackList = struct {
        head: ?*RCUCallback,
        lock: SpinLock,
        
        fn init() CallbackList {
            return .{ .head = null, .lock = SpinLock.init() };
        }
    };
    
    pub fn init() Self {
        return Self{
            .grace_period = atomic.Value(u64).init(0),
            .reader_count = atomic.Value(u32).init(0),
            .callbacks = CallbackList.init(),
        };
    }
    
    /// Begin RCU read-side critical section
    pub fn readLock(self: *Self) void {
        _ = self.reader_count.fetchAdd(1, .acquire);
        std.atomic.fence(.acquire);
    }
    
    /// End RCU read-side critical section
    pub fn readUnlock(self: *Self) void {
        std.atomic.fence(.release);
        _ = self.reader_count.fetchSub(1, .release);
    }
    
    /// Synchronize RCU - wait for all readers to finish
    pub fn synchronize(self: *Self) void {
        const old_gp = self.grace_period.fetchAdd(1, .monotonic);
        
        // Wait for all readers to exit
        while (self.reader_count.load(.acquire) > 0) {
            sched.schedule();
        }
        
        // Process callbacks from previous grace periods
        self.processCallbacks(old_gp);
    }
    
    /// Call function after RCU grace period
    pub fn callAfterGP(self: *Self, func: *const fn (*anyopaque) void, data: *anyopaque) !void {
        const callback = try allocator.create(RCUCallback);
        callback.* = RCUCallback{
            .func = func,
            .data = data,
            .grace_period = self.grace_period.load(.monotonic),
            .next = null,
        };
        
        self.callbacks.lock.lock();
        defer self.callbacks.lock.unlock();
        
        callback.next = self.callbacks.head;
        self.callbacks.head = callback;
    }
    
    fn processCallbacks(self: *Self, completed_gp: u64) void {
        self.callbacks.lock.lock();
        defer self.callbacks.lock.unlock();
        
        var prev: ?*RCUCallback = null;
        var current = self.callbacks.head;
        
        while (current) |cb| {
            if (cb.grace_period <= completed_gp) {
                // Remove from list
                if (prev) |p| {
                    p.next = cb.next;
                } else {
                    self.callbacks.head = cb.next;
                }
                
                // Call callback
                cb.func(cb.data);
                
                const next = cb.next;
                allocator.destroy(cb);
                current = next;
            } else {
                prev = current;
                current = cb.next;
            }
        }
    }
};

/// Wait queue for sleeping processes
pub const WaitQueue = struct {
    head: ?*WaitNode,
    tail: ?*WaitNode,
    lock: SpinLock,
    
    const Self = @This();
    
    const WaitNode = struct {
        process: *process.Process,
        next: ?*WaitNode,
        prev: ?*WaitNode,
    };
    
    pub fn init() Self {
        return Self{
            .head = null,
            .tail = null,
            .lock = SpinLock.init(),
        };
    }
    
    pub fn add(self: *Self, proc: *process.Process) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        const node = allocator.create(WaitNode) catch return;
        node.* = WaitNode{
            .process = proc,
            .next = null,
            .prev = self.tail,
        };
        
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
    }
    
    pub fn remove(self: *Self, proc: *process.Process) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var current = self.head;
        while (current) |node| {
            if (node.process == proc) {
                // Remove from list
                if (node.prev) |prev| {
                    prev.next = node.next;
                } else {
                    self.head = node.next;
                }
                
                if (node.next) |next| {
                    next.prev = node.prev;
                } else {
                    self.tail = node.prev;
                }
                
                allocator.destroy(node);
                return;
            }
            current = node.next;
        }
    }
    
    pub fn removeFirst(self: *Self) ?*process.Process {
        self.lock.lock();
        defer self.lock.unlock();
        
        const node = self.head orelse return null;
        self.head = node.next;
        
        if (node.next) |next| {
            next.prev = null;
        } else {
            self.tail = null;
        }
        
        const proc = node.process;
        allocator.destroy(node);
        return proc;
    }
    
    pub fn wakeAll(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var current = self.head;
        while (current) |node| {
            node.process.state = .runnable;
            const next = node.next;
            allocator.destroy(node);
            current = next;
        }
        
        self.head = null;
        self.tail = null;
    }
};

/// Memory barrier functions
pub inline fn memoryBarrier() void {
    std.atomic.fence(.seq_cst);
}

pub inline fn readBarrier() void {
    std.atomic.fence(.acquire);
}

pub inline fn writeBarrier() void {
    std.atomic.fence(.release);
}

/// Atomic operations helpers
pub inline fn atomicInc(value: *atomic.Value(u32)) u32 {
    return value.fetchAdd(1, .monotonic);
}

pub inline fn atomicDec(value: *atomic.Value(u32)) u32 {
    return value.fetchSub(1, .monotonic);
}

pub inline fn atomicSet(value: *atomic.Value(u32), new_value: u32) void {
    value.store(new_value, .monotonic);
}

pub inline fn atomicGet(value: *atomic.Value(u32)) u32 {
    return value.load(.monotonic);
}

// Global allocator placeholder
var allocator = std.heap.page_allocator;

// Tests
test "spinlock basic operations" {
    var lock = SpinLock.init();
    
    try std.testing.expect(!lock.isLocked());
    
    lock.lock();
    try std.testing.expect(lock.isLocked());
    
    lock.unlock();
    try std.testing.expect(!lock.isLocked());
}

test "semaphore operations" {
    var sem = Semaphore.init(2);
    
    try std.testing.expect(sem.tryWait());
    try std.testing.expect(sem.tryWait());
    try std.testing.expect(!sem.tryWait());
    
    sem.signal();
    try std.testing.expect(sem.tryWait());
}