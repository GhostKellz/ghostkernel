//! Input Subsystem for Ghost Kernel
//! Handles all input devices (keyboards, mice, gamepads, touchpads, etc.)
//! Compatible with Linux input event interface

const std = @import("std");
const sync = @import("../kernel/sync.zig");
const fs = @import("../fs/vfs.zig");
const device = @import("../drivers/driver_framework.zig");

/// Input event types
pub const EventType = enum(u16) {
    syn = 0x00,      // Synchronization events
    key = 0x01,      // Key/button state changes
    rel = 0x02,      // Relative axis changes
    abs = 0x03,      // Absolute axis changes
    msc = 0x04,      // Miscellaneous events
    sw = 0x05,       // Switch events
    led = 0x11,      // LED states
    snd = 0x12,      // Sound events
    rep = 0x14,      // Autorepeat values
    ff = 0x15,       // Force feedback
    pwr = 0x16,      // Power events
    ff_status = 0x17, // Force feedback status
};

/// Synchronization events
pub const SynEvent = enum(u16) {
    report = 0,      // End of event packet
    config = 1,      // Configuration changed
    mt_report = 2,   // End of multitouch packet
    dropped = 3,     // Events were dropped
};

/// Relative axes
pub const RelAxis = enum(u16) {
    x = 0x00,
    y = 0x01,
    z = 0x02,
    rx = 0x03,
    ry = 0x04,
    rz = 0x05,
    hwheel = 0x06,
    dial = 0x07,
    wheel = 0x08,
    misc = 0x09,
    wheel_hi_res = 0x0A,
    hwheel_hi_res = 0x0B,
};

/// Absolute axes
pub const AbsAxis = enum(u16) {
    x = 0x00,
    y = 0x01,
    z = 0x02,
    rx = 0x03,
    ry = 0x04,
    rz = 0x05,
    throttle = 0x06,
    rudder = 0x07,
    wheel = 0x08,
    gas = 0x09,
    brake = 0x0A,
    hat0x = 0x10,
    hat0y = 0x11,
    hat1x = 0x12,
    hat1y = 0x13,
    hat2x = 0x14,
    hat2y = 0x15,
    hat3x = 0x16,
    hat3y = 0x17,
    pressure = 0x18,
    distance = 0x19,
    tilt_x = 0x1A,
    tilt_y = 0x1B,
    tool_width = 0x1C,
    volume = 0x20,
    misc = 0x28,
    mt_slot = 0x2F,
    mt_touch_major = 0x30,
    mt_touch_minor = 0x31,
    mt_width_major = 0x32,
    mt_width_minor = 0x33,
    mt_orientation = 0x34,
    mt_position_x = 0x35,
    mt_position_y = 0x36,
    mt_tool_type = 0x37,
    mt_blob_id = 0x38,
    mt_tracking_id = 0x39,
    mt_pressure = 0x3A,
    mt_distance = 0x3B,
    mt_tool_x = 0x3C,
    mt_tool_y = 0x3D,
};

/// LED types
pub const LedType = enum(u16) {
    num_lock = 0x00,
    caps_lock = 0x01,
    scroll_lock = 0x02,
    compose = 0x03,
    kana = 0x04,
    sleep = 0x05,
    suspend = 0x06,
    mute = 0x07,
    misc = 0x08,
    mail = 0x09,
    charging = 0x0A,
};

/// Common key codes
pub const KEY_RESERVED = 0;
pub const KEY_ESC = 1;
pub const KEY_1 = 2;
pub const KEY_2 = 3;
pub const KEY_3 = 4;
pub const KEY_4 = 5;
pub const KEY_5 = 6;
pub const KEY_6 = 7;
pub const KEY_7 = 8;
pub const KEY_8 = 9;
pub const KEY_9 = 10;
pub const KEY_0 = 11;
pub const KEY_MINUS = 12;
pub const KEY_EQUAL = 13;
pub const KEY_BACKSPACE = 14;
pub const KEY_TAB = 15;
pub const KEY_Q = 16;
pub const KEY_W = 17;
pub const KEY_E = 18;
pub const KEY_R = 19;
pub const KEY_T = 20;
pub const KEY_Y = 21;
pub const KEY_U = 22;
pub const KEY_I = 23;
pub const KEY_O = 24;
pub const KEY_P = 25;
pub const KEY_LEFTBRACE = 26;
pub const KEY_RIGHTBRACE = 27;
pub const KEY_ENTER = 28;
pub const KEY_LEFTCTRL = 29;
pub const KEY_A = 30;
pub const KEY_S = 31;
pub const KEY_D = 32;
pub const KEY_F = 33;
pub const KEY_G = 34;
pub const KEY_H = 35;
pub const KEY_J = 36;
pub const KEY_K = 37;
pub const KEY_L = 38;
pub const KEY_SEMICOLON = 39;
pub const KEY_APOSTROPHE = 40;
pub const KEY_GRAVE = 41;
pub const KEY_LEFTSHIFT = 42;
pub const KEY_BACKSLASH = 43;
pub const KEY_Z = 44;
pub const KEY_X = 45;
pub const KEY_C = 46;
pub const KEY_V = 47;
pub const KEY_B = 48;
pub const KEY_N = 49;
pub const KEY_M = 50;
pub const KEY_COMMA = 51;
pub const KEY_DOT = 52;
pub const KEY_SLASH = 53;
pub const KEY_RIGHTSHIFT = 54;
pub const KEY_KPASTERISK = 55;
pub const KEY_LEFTALT = 56;
pub const KEY_SPACE = 57;
pub const KEY_CAPSLOCK = 58;
pub const KEY_F1 = 59;
pub const KEY_F2 = 60;
pub const KEY_F3 = 61;
pub const KEY_F4 = 62;
pub const KEY_F5 = 63;
pub const KEY_F6 = 64;
pub const KEY_F7 = 65;
pub const KEY_F8 = 66;
pub const KEY_F9 = 67;
pub const KEY_F10 = 68;
pub const KEY_NUMLOCK = 69;
pub const KEY_SCROLLLOCK = 70;
pub const KEY_F11 = 87;
pub const KEY_F12 = 88;
pub const KEY_SYSRQ = 99;
pub const KEY_RIGHTCTRL = 97;
pub const KEY_RIGHTALT = 100;
pub const KEY_HOME = 102;
pub const KEY_UP = 103;
pub const KEY_PAGEUP = 104;
pub const KEY_LEFT = 105;
pub const KEY_RIGHT = 106;
pub const KEY_END = 107;
pub const KEY_DOWN = 108;
pub const KEY_PAGEDOWN = 109;
pub const KEY_INSERT = 110;
pub const KEY_DELETE = 111;
pub const KEY_PAUSE = 119;
pub const KEY_LEFTMETA = 125;
pub const KEY_RIGHTMETA = 126;

/// Mouse button codes
pub const BTN_MISC = 0x100;
pub const BTN_0 = 0x100;
pub const BTN_1 = 0x101;
pub const BTN_2 = 0x102;
pub const BTN_3 = 0x103;
pub const BTN_4 = 0x104;
pub const BTN_5 = 0x105;
pub const BTN_6 = 0x106;
pub const BTN_7 = 0x107;
pub const BTN_8 = 0x108;
pub const BTN_9 = 0x109;

pub const BTN_MOUSE = 0x110;
pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;
pub const BTN_SIDE = 0x113;
pub const BTN_EXTRA = 0x114;
pub const BTN_FORWARD = 0x115;
pub const BTN_BACK = 0x116;
pub const BTN_TASK = 0x117;

/// Input event structure (compatible with Linux)
pub const InputEvent = extern struct {
    time: TimeVal,
    type: u16,
    code: u16,
    value: i32,
};

pub const TimeVal = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

/// Input device types
pub const InputDeviceType = enum {
    keyboard,
    mouse,
    touchpad,
    joystick,
    gamepad,
    tablet,
    touchscreen,
    other,
};

/// Input device properties
pub const InputDeviceProperties = struct {
    // Gaming optimizations
    gaming_mode: bool = false,
    high_precision: bool = false,
    polling_rate_hz: u32 = 125,
    actual_polling_rate_hz: u32 = 0,
    
    // Device capabilities
    supports_force_feedback: bool = false,
    supports_leds: bool = false,
    supports_multitouch: bool = false,
    
    // Power management
    can_wakeup: bool = false,
    power_save_enabled: bool = false,
};

/// Input device structure
pub const InputDevice = struct {
    name: []const u8,
    device_type: InputDeviceType,
    
    // Device identification
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    version: u16 = 0,
    
    // Event capabilities (bitmasks)
    evbit: [BITS_TO_LONGS(EventType)] = [_]ulong{0} ** BITS_TO_LONGS(EventType),
    keybit: [BITS_TO_LONGS(KEY_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(KEY_CNT),
    relbit: [BITS_TO_LONGS(REL_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(REL_CNT),
    absbit: [BITS_TO_LONGS(ABS_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(ABS_CNT),
    mscbit: [BITS_TO_LONGS(MSC_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(MSC_CNT),
    ledbit: [BITS_TO_LONGS(LED_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(LED_CNT),
    sndbit: [BITS_TO_LONGS(SND_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(SND_CNT),
    ffbit: [BITS_TO_LONGS(FF_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(FF_CNT),
    swbit: [BITS_TO_LONGS(SW_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(SW_CNT),
    
    // Absolute axis information
    absinfo: [ABS_CNT]?AbsInfo = [_]?AbsInfo{null} ** ABS_CNT,
    
    // Key states
    key_states: [BITS_TO_LONGS(KEY_CNT)] = [_]ulong{0} ** BITS_TO_LONGS(KEY_CNT),
    
    // Event handlers
    event_handler: ?*EventHandler = null,
    
    // Device properties
    properties: InputDeviceProperties = .{},
    
    // Event queue
    event_queue: EventQueue,
    
    // Statistics
    events_generated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    events_dropped: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    // Device file
    device_file: ?*device.DeviceFile = null,
    device_number: u32 = 0,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = sync.Mutex.init(),
    
    const Self = @This();
    
    // Capability setting functions
    pub fn setEventBit(self: *Self, event_type: EventType) void {
        setBit(&self.evbit, @intFromEnum(event_type));
    }
    
    pub fn setKeyBit(self: *Self, keycode: u16) void {
        if (keycode < KEY_CNT) {
            setBit(&self.keybit, keycode);
        }
    }
    
    pub fn setRelBit(self: *Self, axis: RelAxis) void {
        setBit(&self.relbit, @intFromEnum(axis));
    }
    
    pub fn setAbsBit(self: *Self, axis: AbsAxis) void {
        setBit(&self.absbit, @intFromEnum(axis));
    }
    
    pub fn setLedBit(self: *Self, led: LedType) void {
        setBit(&self.ledbit, @intFromEnum(led));
    }
    
    pub fn setAbsInfo(self: *Self, axis: AbsAxis, info: AbsInfo) void {
        self.absinfo[@intFromEnum(axis)] = info;
        self.setAbsBit(axis);
    }
    
    // Event reporting functions
    pub fn reportKey(self: *Self, keycode: u16, pressed: bool) !void {
        if (keycode >= KEY_CNT) return error.InvalidKeycode;
        
        // Update key state
        if (pressed) {
            setBit(&self.key_states, keycode);
        } else {
            clearBit(&self.key_states, keycode);
        }
        
        try self.reportEvent(.key, keycode, if (pressed) 1 else 0);
    }
    
    pub fn reportRel(self: *Self, axis: RelAxis, value: i32) !void {
        try self.reportEvent(.rel, @intFromEnum(axis), value);
    }
    
    pub fn reportAbs(self: *Self, axis: AbsAxis, value: i32) !void {
        try self.reportEvent(.abs, @intFromEnum(axis), value);
    }
    
    pub fn reportEvent(self: *Self, event_type: EventType, code: u16, value: i32) !void {
        const now = std.time.nanoTimestamp();
        const event = InputEvent{
            .time = TimeVal{
                .tv_sec = @divTrunc(now, std.time.ns_per_s),
                .tv_usec = @divTrunc(@rem(now, std.time.ns_per_s), std.time.ns_per_us),
            },
            .type = @intFromEnum(event_type),
            .code = code,
            .value = value,
        };
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Add to queue
        if (!self.event_queue.push(event)) {
            _ = self.events_dropped.fetchAdd(1, .release);
            return error.QueueFull;
        }
        
        _ = self.events_generated.fetchAdd(1, .release);
        
        // Notify event handler if present
        if (self.event_handler) |handler| {
            handler.handleEvent(self, event);
        }
        
        // Wake up any readers
        self.event_queue.wakeReaders();
    }
    
    pub fn syncEvents(self: *Self) !void {
        try self.reportEvent(.syn, @intFromEnum(SynEvent.report), 0);
    }
    
    pub fn getKeyState(self: *Self, keycode: u16) bool {
        if (keycode >= KEY_CNT) return false;
        return testBit(&self.key_states, keycode);
    }
};

/// Absolute axis information
pub const AbsInfo = struct {
    value: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

/// Event handler interface
pub const EventHandler = struct {
    handleEvent: *const fn (*EventHandler, *InputDevice, InputEvent) void,
    private_data: ?*anyopaque = null,
};

/// Event queue for buffering input events
pub const EventQueue = struct {
    buffer: [256]InputEvent = undefined,
    head: usize = 0,
    tail: usize = 0,
    waiters: sync.WaitQueue = sync.WaitQueue.init(),
    
    const Self = @This();
    
    pub fn push(self: *Self, event: InputEvent) bool {
        const next_head = (self.head + 1) % self.buffer.len;
        if (next_head == self.tail) {
            return false; // Queue full
        }
        
        self.buffer[self.head] = event;
        self.head = next_head;
        return true;
    }
    
    pub fn pop(self: *Self) ?InputEvent {
        if (self.head == self.tail) {
            return null; // Queue empty
        }
        
        const event = self.buffer[self.tail];
        self.tail = (self.tail + 1) % self.buffer.len;
        return event;
    }
    
    pub fn isEmpty(self: *Self) bool {
        return self.head == self.tail;
    }
    
    pub fn wakeReaders(self: *Self) void {
        self.waiters.wakeAll();
    }
};

// Constants
const BITS_PER_LONG = @bitSizeOf(ulong);
const ulong = u64;

fn BITS_TO_LONGS(comptime bits: type) usize {
    return (bits + BITS_PER_LONG - 1) / BITS_PER_LONG;
}

const KEY_CNT = 768;
const REL_CNT = 16;
const ABS_CNT = 64;
const MSC_CNT = 8;
const LED_CNT = 16;
const SND_CNT = 8;
const FF_CNT = 128;
const SW_CNT = 16;

// Bit manipulation helpers
fn setBit(bitmap: []ulong, bit: usize) void {
    const idx = bit / BITS_PER_LONG;
    const mask = @as(ulong, 1) << @intCast(bit % BITS_PER_LONG);
    bitmap[idx] |= mask;
}

fn clearBit(bitmap: []ulong, bit: usize) void {
    const idx = bit / BITS_PER_LONG;
    const mask = @as(ulong, 1) << @intCast(bit % BITS_PER_LONG);
    bitmap[idx] &= ~mask;
}

fn testBit(bitmap: []const ulong, bit: usize) bool {
    const idx = bit / BITS_PER_LONG;
    const mask = @as(ulong, 1) << @intCast(bit % BITS_PER_LONG);
    return (bitmap[idx] & mask) != 0;
}

// Global input subsystem
var input_subsystem: ?InputSubsystem = null;

pub const InputSubsystem = struct {
    devices: std.ArrayList(*InputDevice),
    next_device_number: u32 = 0,
    mutex: sync.Mutex,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .devices = std.ArrayList(*InputDevice).init(allocator),
            .mutex = sync.Mutex.init(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.devices.deinit();
    }
};

/// Initialize the input subsystem
pub fn initInputSubsystem(allocator: std.mem.Allocator) !void {
    input_subsystem = InputSubsystem.init(allocator);
}

/// Register an input device
pub fn registerDevice(dev: *InputDevice) !void {
    const subsystem = &(input_subsystem orelse return error.SubsystemNotInitialized);
    
    subsystem.mutex.lock();
    defer subsystem.mutex.unlock();
    
    dev.device_number = subsystem.next_device_number;
    subsystem.next_device_number += 1;
    
    try subsystem.devices.append(dev);
    
    // TODO: Create device file in /dev/input/
}

/// Unregister an input device
pub fn unregisterDevice(dev: *InputDevice) void {
    const subsystem = &(input_subsystem orelse return);
    
    subsystem.mutex.lock();
    defer subsystem.mutex.unlock();
    
    for (subsystem.devices.items, 0..) |d, i| {
        if (d == dev) {
            _ = subsystem.devices.swapRemove(i);
            break;
        }
    }
    
    // TODO: Remove device file
}