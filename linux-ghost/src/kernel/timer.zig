//! Timer and Clock Subsystem
//! High-resolution timers, timekeeping, and clock sources

const std = @import("std");
const console = @import("../arch/x86_64/console.zig");
const interrupts = @import("../arch/x86_64/interrupts.zig");
const sync = @import("sync.zig");

/// Time units
pub const NSEC_PER_SEC: u64 = 1_000_000_000;
pub const NSEC_PER_MSEC: u64 = 1_000_000;
pub const NSEC_PER_USEC: u64 = 1_000;

/// Clock sources
pub const ClockSource = enum {
    tsc,        // Time Stamp Counter
    hpet,       // High Precision Event Timer
    pit,        // Programmable Interval Timer (legacy)
    rtc,        // Real Time Clock
};

/// Time representation
pub const Timespec = struct {
    sec: i64,
    nsec: i64,
    
    const Self = @This();
    
    pub fn fromNsec(nsec: u64) Self {
        return Self{
            .sec = @intCast(nsec / NSEC_PER_SEC),
            .nsec = @intCast(nsec % NSEC_PER_SEC),
        };
    }
    
    pub fn toNsec(self: Self) u64 {
        return @intCast(self.sec * NSEC_PER_SEC + self.nsec);
    }
    
    pub fn add(self: Self, other: Self) Self {
        var result = Self{
            .sec = self.sec + other.sec,
            .nsec = self.nsec + other.nsec,
        };
        
        if (result.nsec >= NSEC_PER_SEC) {
            result.sec += 1;
            result.nsec -= NSEC_PER_SEC;
        }
        
        return result;
    }
    
    pub fn sub(self: Self, other: Self) Self {
        var result = Self{
            .sec = self.sec - other.sec,
            .nsec = self.nsec - other.nsec,
        };
        
        if (result.nsec < 0) {
            result.sec -= 1;
            result.nsec += NSEC_PER_SEC;
        }
        
        return result;
    }
};

/// Timer types
pub const TimerType = enum {
    oneshot,    // Fire once
    periodic,   // Fire repeatedly
};

/// Timer callback function
pub const TimerCallback = *const fn (*Timer) void;

/// Timer structure
pub const Timer = struct {
    expires: u64,               // Expiration time in nanoseconds
    period: u64,                // Period for periodic timers
    timer_type: TimerType,
    callback: TimerCallback,
    data: ?*anyopaque,
    
    // Timer wheel node
    next: ?*Timer,
    prev: ?*Timer,
    bucket: u32,
    
    const Self = @This();
    
    pub fn init(callback: TimerCallback) Self {
        return Self{
            .expires = 0,
            .period = 0,
            .timer_type = .oneshot,
            .callback = callback,
            .data = null,
            .next = null,
            .prev = null,
            .bucket = 0,
        };
    }
    
    pub fn setOneshot(self: *Self, delay_ns: u64) void {
        self.timer_type = .oneshot;
        self.expires = getCurrentTimeNsec() + delay_ns;
        self.period = 0;
    }
    
    pub fn setPeriodic(self: *Self, period_ns: u64) void {
        self.timer_type = .periodic;
        self.expires = getCurrentTimeNsec() + period_ns;
        self.period = period_ns;
    }
};

/// Timer wheel for efficient timer management
const TimerWheel = struct {
    buckets: [WHEEL_SIZE]?*Timer,
    current_bucket: u32,
    lock: sync.SpinLock,
    
    const WHEEL_SIZE = 256;
    const BUCKET_TIME_NS = 10 * NSEC_PER_MSEC; // 10ms per bucket
    
    const Self = @This();
    
    fn init() Self {
        return Self{
            .buckets = [_]?*Timer{null} ** WHEEL_SIZE,
            .current_bucket = 0,
            .lock = sync.SpinLock.init(),
        };
    }
    
    fn addTimer(self: *Self, timer: *Timer) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        const now = getCurrentTimeNsec();
        const delta = if (timer.expires > now) timer.expires - now else 0;
        const bucket_offset = delta / BUCKET_TIME_NS;
        
        timer.bucket = @intCast((self.current_bucket + bucket_offset) % WHEEL_SIZE);
        
        // Add to bucket list
        timer.next = self.buckets[timer.bucket];
        timer.prev = null;
        
        if (self.buckets[timer.bucket]) |head| {
            head.prev = timer;
        }
        self.buckets[timer.bucket] = timer;
    }
    
    fn removeTimer(self: *Self, timer: *Timer) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        if (timer.prev) |prev| {
            prev.next = timer.next;
        } else {
            self.buckets[timer.bucket] = timer.next;
        }
        
        if (timer.next) |next| {
            next.prev = timer.prev;
        }
        
        timer.next = null;
        timer.prev = null;
    }
    
    fn tick(self: *Self) void {
        self.lock.lock();
        
        const current_time = getCurrentTimeNsec();
        var expired_list: ?*Timer = null;
        
        // Process current bucket
        var timer = self.buckets[self.current_bucket];
        self.buckets[self.current_bucket] = null;
        
        while (timer) |t| {
            const next = t.next;
            
            if (t.expires <= current_time) {
                // Add to expired list
                t.next = expired_list;
                expired_list = t;
            } else {
                // Re-add timer to appropriate bucket
                self.lock.unlock();
                self.addTimer(t);
                self.lock.lock();
            }
            
            timer = next;
        }
        
        // Advance to next bucket
        self.current_bucket = (self.current_bucket + 1) % WHEEL_SIZE;
        
        self.lock.unlock();
        
        // Process expired timers (outside lock)
        while (expired_list) |t| {
            expired_list = t.next;
            
            // Call timer callback
            t.callback(t);
            
            // Re-arm periodic timers
            if (t.timer_type == .periodic) {
                t.expires = current_time + t.period;
                self.addTimer(t);
            }
        }
    }
};

/// High-resolution timer
const HRTimer = struct {
    base: Timer,
    cpu: u32,
    
    const Self = @This();
    
    pub fn init(callback: TimerCallback) Self {
        return Self{
            .base = Timer.init(callback),
            .cpu = 0,
        };
    }
};

/// Clock event device (per-CPU timer)
const ClockEventDevice = struct {
    name: []const u8,
    features: Features,
    max_delta_ns: u64,
    min_delta_ns: u64,
    rating: u32,
    
    // Operations
    setPeriodic: *const fn (*ClockEventDevice) void,
    setOneshot: *const fn (*ClockEventDevice, u64) void,
    shutdown: *const fn (*ClockEventDevice) void,
    
    const Features = packed struct {
        periodic: bool = false,
        oneshot: bool = false,
        c3stop: bool = false,      // Stops in C3 state
        dummy: bool = false,
        _reserved: u60 = 0,
    };
};

// Global timer state
var system_time: Timespec = Timespec{ .sec = 0, .nsec = 0 };
var boot_time: u64 = 0;
var timer_wheel: TimerWheel = TimerWheel.init();
var tsc_frequency: u64 = 0;
var time_lock: sync.RwSpinLock = sync.RwSpinLock.init();

/// Initialize timer subsystem
pub fn init() !void {
    console.writeString("Initializing timer subsystem...\n");
    
    // Calibrate TSC
    tsc_frequency = try calibrateTSC();
    console.printf("  TSC frequency: {} MHz\n", .{tsc_frequency / 1_000_000});
    
    // Initialize timer interrupt (IRQ 0)
    interrupts.setHandler(32, timerInterruptHandler); // IRQ 0 = INT 32
    
    // Set up PIT for 1000Hz (1ms) timer
    setupPIT(1000);
    
    // Record boot time
    boot_time = rdtsc();
    
    console.writeString("Timer subsystem initialized\n");
}

/// Get current time in nanoseconds since boot
pub fn getCurrentTimeNsec() u64 {
    const tsc = rdtsc();
    const delta = tsc - boot_time;
    return (delta * NSEC_PER_SEC) / tsc_frequency;
}

/// Get current wall clock time
pub fn getCurrentTime() Timespec {
    time_lock.readLock();
    defer time_lock.readUnlock();
    
    const boot_ns = getCurrentTimeNsec();
    const boot_time_spec = Timespec.fromNsec(boot_ns);
    
    return system_time.add(boot_time_spec);
}

/// Set system time
pub fn setSystemTime(time: Timespec) void {
    time_lock.writeLock();
    defer time_lock.writeUnlock();
    
    const boot_ns = getCurrentTimeNsec();
    const boot_time_spec = Timespec.fromNsec(boot_ns);
    
    system_time = time.sub(boot_time_spec);
}

/// Sleep for specified duration
pub fn sleepNsec(nsec: u64) void {
    const start = getCurrentTimeNsec();
    const end = start + nsec;
    
    while (getCurrentTimeNsec() < end) {
        // TODO: Use proper sleep mechanism
        asm volatile ("pause");
    }
}

/// Add a timer
pub fn addTimer(timer: *Timer) void {
    timer_wheel.addTimer(timer);
}

/// Remove a timer
pub fn removeTimer(timer: *Timer) void {
    timer_wheel.removeTimer(timer);
}

/// Timer interrupt handler
fn timerInterruptHandler(frame: *interrupts.InterruptFrame) callconv(.C) void {
    _ = frame;
    
    // Update system time
    time_lock.writeLock();
    system_time.nsec += NSEC_PER_MSEC; // 1ms tick
    if (system_time.nsec >= NSEC_PER_SEC) {
        system_time.sec += 1;
        system_time.nsec -= NSEC_PER_SEC;
    }
    time_lock.writeUnlock();
    
    // Process timer wheel
    timer_wheel.tick();
    
    // Acknowledge interrupt
    outb(0x20, 0x20); // EOI to PIC
}

/// Read Time Stamp Counter
fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Calibrate TSC frequency
fn calibrateTSC() !u64 {
    // Use PIT to calibrate TSC
    const pit_freq = 1193182; // PIT frequency in Hz
    const calibration_ticks = 100; // ~100ms calibration
    
    // Set up PIT for one-shot mode
    outb(0x43, 0x30); // Channel 0, one-shot mode
    outb(0x40, @truncate(calibration_ticks));
    outb(0x40, @truncate(calibration_ticks >> 8));
    
    // Measure TSC over calibration period
    const start_tsc = rdtsc();
    
    // Wait for PIT to count down
    while ((inb(0x61) & 0x20) == 0) {
        asm volatile ("pause");
    }
    
    const end_tsc = rdtsc();
    
    // Calculate frequency
    const tsc_delta = end_tsc - start_tsc;
    const time_ns = (calibration_ticks * NSEC_PER_SEC) / pit_freq;
    
    return (tsc_delta * NSEC_PER_SEC) / time_ns;
}

/// Set up Programmable Interval Timer
fn setupPIT(freq_hz: u32) void {
    const divisor = 1193182 / freq_hz;
    
    outb(0x43, 0x36); // Channel 0, square wave mode
    outb(0x40, @truncate(divisor));
    outb(0x40, @truncate(divisor >> 8));
}

/// I/O port operations
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Delay functions
pub fn udelay(microseconds: u64) void {
    sleepNsec(microseconds * NSEC_PER_USEC);
}

pub fn mdelay(milliseconds: u64) void {
    sleepNsec(milliseconds * NSEC_PER_MSEC);
}

/// Get system uptime
pub fn getUptime() Timespec {
    return Timespec.fromNsec(getCurrentTimeNsec());
}

/// Timer statistics
pub fn getTimerStats() TimerStats {
    return TimerStats{
        .tsc_frequency = tsc_frequency,
        .uptime_ns = getCurrentTimeNsec(),
        .system_time = getCurrentTime(),
    };
}

pub const TimerStats = struct {
    tsc_frequency: u64,
    uptime_ns: u64,
    system_time: Timespec,
};