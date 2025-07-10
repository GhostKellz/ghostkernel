//! USB HID (Human Interface Device) Driver for Ghost Kernel
//! Supports keyboards, mice, gamepads, and other input devices
//! Optimized for low-latency gaming peripherals

const std = @import("std");
const usb = @import("usb_core.zig");
const input = @import("../../input/input_subsystem.zig");
const memory = @import("../../mm/memory.zig");
const sync = @import("../../kernel/sync.zig");

/// HID class-specific descriptors
pub const HIDDescriptorType = enum(u8) {
    hid = 0x21,
    report = 0x22,
    physical = 0x23,
};

/// HID subclass codes
pub const HIDSubclass = enum(u8) {
    none = 0,
    boot_interface = 1,
};

/// HID protocol codes
pub const HIDProtocol = enum(u8) {
    none = 0,
    keyboard = 1,
    mouse = 2,
};

/// HID request codes
pub const HIDRequest = enum(u8) {
    get_report = 0x01,
    get_idle = 0x02,
    get_protocol = 0x03,
    set_report = 0x09,
    set_idle = 0x0A,
    set_protocol = 0x0B,
};

/// HID report types
pub const ReportType = enum(u8) {
    input = 1,
    output = 2,
    feature = 3,
};

/// HID class descriptor
pub const HIDClassDescriptor = packed struct {
    length: u8,
    descriptor_type: u8,
    hid_version: u16,
    country_code: u8,
    num_descriptors: u8,
    report_type: u8,
    report_length: u16,
};

/// HID device structure
pub const HIDDevice = struct {
    usb_device: *usb.USBDevice,
    interface: *usb.Interface,
    
    // HID properties
    subclass: HIDSubclass,
    protocol: HIDProtocol,
    report_descriptor: []u8,
    
    // Endpoints
    interrupt_in: ?*usb.Endpoint = null,
    interrupt_out: ?*usb.Endpoint = null,
    
    // Input device registration
    input_device: ?*input.InputDevice = null,
    
    // Gaming optimization
    polling_rate_hz: u32 = 125,
    use_high_speed_polling: bool = false,
    
    // Report processing
    last_report: []u8,
    report_buffer: []u8,
    report_size: usize,
    
    // URB for continuous polling
    polling_urb: ?*usb.URB = null,
    
    // Performance tracking
    reports_received: std.atomic.Value(u64),
    reports_processed: std.atomic.Value(u64),
    last_report_time: u64 = 0,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *usb.USBDevice, interface: *usb.Interface) !Self {
        const subclass = @as(HIDSubclass, @enumFromInt(interface.descriptor.interface_subclass));
        const protocol = @as(HIDProtocol, @enumFromInt(interface.descriptor.interface_protocol));
        
        // Find interrupt endpoints
        var interrupt_in: ?*usb.Endpoint = null;
        var interrupt_out: ?*usb.Endpoint = null;
        
        for (interface.endpoints.items) |*endpoint| {
            if (endpoint.descriptor.getTransferType() == .interrupt) {
                if (endpoint.descriptor.getDirection() == .in) {
                    interrupt_in = endpoint;
                } else {
                    interrupt_out = endpoint;
                }
            }
        }
        
        // Allocate report buffers
        const report_size = if (interrupt_in) |ep| ep.descriptor.getMaxPacketSize() else 8;
        const last_report = try allocator.alloc(u8, report_size);
        const report_buffer = try allocator.alloc(u8, report_size);
        
        @memset(last_report, 0);
        @memset(report_buffer, 0);
        
        return Self{
            .usb_device = device,
            .interface = interface,
            .subclass = subclass,
            .protocol = protocol,
            .report_descriptor = &[_]u8{},
            .interrupt_in = interrupt_in,
            .interrupt_out = interrupt_out,
            .report_size = report_size,
            .last_report = last_report,
            .report_buffer = report_buffer,
            .reports_received = std.atomic.Value(u64).init(0),
            .reports_processed = std.atomic.Value(u64).init(0),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stopPolling();
        
        if (self.input_device) |dev| {
            input.unregisterDevice(dev);
            self.allocator.destroy(dev);
        }
        
        self.allocator.free(self.last_report);
        self.allocator.free(self.report_buffer);
        self.allocator.free(self.report_descriptor);
    }
    
    pub fn start(self: *Self) !void {
        // Get HID report descriptor
        try self.getReportDescriptor();
        
        // Parse descriptor and create input device
        try self.parseReportDescriptor();
        
        // Set boot protocol for keyboards/mice if needed
        if (self.subclass == .boot_interface) {
            try self.setProtocol(0); // Boot protocol
        }
        
        // Set idle rate (0 = infinite, report only on change)
        try self.setIdleRate(0);
        
        // Configure polling rate based on device type
        self.configurePollingRate();
        
        // Start interrupt polling
        try self.startPolling();
    }
    
    pub fn stop(self: *Self) void {
        self.stopPolling();
    }
    
    fn getReportDescriptor(self: *Self) !void {
        // First, get the HID descriptor to know report descriptor size
        var hid_desc_buf: [9]u8 = undefined;
        
        var setup = usb.SetupPacket{
            .request_type = 0x81, // Device to host, standard, interface
            .request = @intFromEnum(usb.RequestType.get_descriptor),
            .value = (@as(u16, @intFromEnum(HIDDescriptorType.hid)) << 8) | 0,
            .index = self.interface.descriptor.interface_number,
            .length = @sizeOf(HIDClassDescriptor),
        };
        
        try self.usb_device.controlTransfer(&setup, &hid_desc_buf);
        
        const hid_desc = @as(*const HIDClassDescriptor, @ptrCast(@alignCast(&hid_desc_buf))).*;
        
        // Now get the report descriptor
        self.report_descriptor = try self.allocator.alloc(u8, hid_desc.report_length);
        
        setup = usb.SetupPacket{
            .request_type = 0x81,
            .request = @intFromEnum(usb.RequestType.get_descriptor),
            .value = (@as(u16, @intFromEnum(HIDDescriptorType.report)) << 8) | 0,
            .index = self.interface.descriptor.interface_number,
            .length = hid_desc.report_length,
        };
        
        try self.usb_device.controlTransfer(&setup, self.report_descriptor);
    }
    
    fn setProtocol(self: *Self, protocol: u8) !void {
        var setup = usb.SetupPacket{
            .request_type = 0x21, // Host to device, class, interface
            .request = @intFromEnum(HIDRequest.set_protocol),
            .value = protocol,
            .index = self.interface.descriptor.interface_number,
            .length = 0,
        };
        
        try self.usb_device.controlTransfer(&setup, &[_]u8{});
    }
    
    fn setIdleRate(self: *Self, idle_rate: u8) !void {
        var setup = usb.SetupPacket{
            .request_type = 0x21,
            .request = @intFromEnum(HIDRequest.set_idle),
            .value = @as(u16, idle_rate) << 8,
            .index = self.interface.descriptor.interface_number,
            .length = 0,
        };
        
        try self.usb_device.controlTransfer(&setup, &[_]u8{});
    }
    
    fn configurePollingRate(self: *Self) void {
        // Determine optimal polling rate based on device type
        if (self.usb_device.is_gaming_device) {
            self.polling_rate_hz = 1000; // 1000 Hz for gaming devices
            self.use_high_speed_polling = true;
        } else {
            switch (self.protocol) {
                .keyboard => self.polling_rate_hz = 250,
                .mouse => self.polling_rate_hz = 500,
                .none => self.polling_rate_hz = 125,
            }
        }
        
        // Enable gaming mode on the USB device if appropriate
        if (self.use_high_speed_polling) {
            self.usb_device.enableGamingMode();
        }
    }
    
    fn parseReportDescriptor(self: *Self) !void {
        // For boot protocol devices, we can skip parsing and use standard formats
        if (self.subclass == .boot_interface) {
            switch (self.protocol) {
                .keyboard => try self.createKeyboardDevice(),
                .mouse => try self.createMouseDevice(),
                .none => {},
            }
            return;
        }
        
        // TODO: Implement full HID report descriptor parsing
        // For now, detect common device types based on usage pages
        try self.createGenericDevice();
    }
    
    fn createKeyboardDevice(self: *Self) !void {
        const kbd = try self.allocator.create(input.InputDevice);
        kbd.* = input.InputDevice{
            .name = "USB HID Keyboard",
            .device_type = .keyboard,
            .vendor_id = self.usb_device.device_descriptor.vendor_id,
            .product_id = self.usb_device.device_descriptor.product_id,
            .version = self.usb_device.device_descriptor.device_version,
            .allocator = self.allocator,
        };
        
        // Set keyboard capabilities
        kbd.setEventBit(.key);
        kbd.setEventBit(.msc);
        kbd.setEventBit(.led);
        kbd.setEventBit(.rep);
        
        // Set standard keyboard keys
        for (0..256) |i| {
            kbd.setKeyBit(@intCast(i));
        }
        
        // Set LED capabilities
        kbd.setLedBit(.num_lock);
        kbd.setLedBit(.caps_lock);
        kbd.setLedBit(.scroll_lock);
        
        try input.registerDevice(kbd);
        self.input_device = kbd;
    }
    
    fn createMouseDevice(self: *Self) !void {
        const mouse = try self.allocator.create(input.InputDevice);
        mouse.* = input.InputDevice{
            .name = "USB HID Mouse",
            .device_type = .mouse,
            .vendor_id = self.usb_device.device_descriptor.vendor_id,
            .product_id = self.usb_device.device_descriptor.product_id,
            .version = self.usb_device.device_descriptor.device_version,
            .allocator = self.allocator,
        };
        
        // Set mouse capabilities
        mouse.setEventBit(.key);
        mouse.setEventBit(.rel);
        mouse.setEventBit(.msc);
        
        // Set mouse buttons
        mouse.setKeyBit(input.BTN_LEFT);
        mouse.setKeyBit(input.BTN_RIGHT);
        mouse.setKeyBit(input.BTN_MIDDLE);
        mouse.setKeyBit(input.BTN_SIDE);
        mouse.setKeyBit(input.BTN_EXTRA);
        
        // Set relative axes
        mouse.setRelBit(.x);
        mouse.setRelBit(.y);
        mouse.setRelBit(.wheel);
        mouse.setRelBit(.hwheel);
        
        // Set mouse properties for gaming optimization
        if (self.usb_device.is_gaming_device) {
            mouse.properties.high_precision = true;
            mouse.properties.gaming_mode = true;
            mouse.properties.polling_rate_hz = self.polling_rate_hz;
        }
        
        try input.registerDevice(mouse);
        self.input_device = mouse;
    }
    
    fn createGenericDevice(self: *Self) !void {
        const dev = try self.allocator.create(input.InputDevice);
        dev.* = input.InputDevice{
            .name = "USB HID Device",
            .device_type = .other,
            .vendor_id = self.usb_device.device_descriptor.vendor_id,
            .product_id = self.usb_device.device_descriptor.product_id,
            .version = self.usb_device.device_descriptor.device_version,
            .allocator = self.allocator,
        };
        
        // TODO: Parse report descriptor to set proper capabilities
        
        try input.registerDevice(dev);
        self.input_device = dev;
    }
    
    fn startPolling(self: *Self) !void {
        if (self.interrupt_in == null) return;
        
        // Create URB for polling
        const urb = try self.allocator.create(usb.URB);
        urb.* = usb.URB{
            .device = self.usb_device,
            .endpoint = self.interrupt_in.?.descriptor.endpoint_address,
            .transfer_type = .interrupt,
            .direction = .in,
            .buffer = self.report_buffer,
            .completion_fn = hidReportComplete,
            .context = self,
            .low_latency = self.use_high_speed_polling,
            .high_priority = self.usb_device.is_gaming_device,
            .gaming_device = self.usb_device.is_gaming_device,
        };
        
        self.polling_urb = urb;
        
        // Submit initial URB
        try self.usb_device.submitTransfer(urb);
    }
    
    fn stopPolling(self: *Self) void {
        if (self.polling_urb) |urb| {
            // TODO: Cancel URB
            self.allocator.destroy(urb);
            self.polling_urb = null;
        }
    }
    
    fn hidReportComplete(urb: *usb.URB) void {
        const self = @as(*HIDDevice, @ptrCast(@alignCast(urb.context.?)));
        
        _ = self.reports_received.fetchAdd(1, .release);
        
        if (urb.status == .completed) {
            self.processReport(urb.buffer[0..urb.actual_length]) catch {};
            
            // Resubmit URB for continuous polling
            urb.actual_length = 0;
            urb.status = .pending;
            self.usb_device.submitTransfer(urb) catch {
                // Handle error - maybe device was disconnected
                self.stopPolling();
            };
        } else {
            // Handle error
            switch (urb.status) {
                .stalled => {
                    // Clear halt and retry
                    // TODO: Implement endpoint halt clearing
                },
                .no_response, .timeout => {
                    // Device might be disconnected
                    self.stopPolling();
                },
                else => {},
            }
        }
    }
    
    fn processReport(self: *Self, report: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if report has changed
        if (std.mem.eql(u8, report, self.last_report[0..report.len])) {
            return; // No change
        }
        
        // Update timing
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const delta_time = if (self.last_report_time > 0) now - self.last_report_time else 0;
        self.last_report_time = now;
        
        // Process based on device type
        if (self.subclass == .boot_interface) {
            switch (self.protocol) {
                .keyboard => try self.processKeyboardReport(report),
                .mouse => try self.processMouseReport(report, delta_time),
                .none => {},
            }
        } else {
            // Process generic HID report
            try self.processGenericReport(report);
        }
        
        // Update last report
        @memcpy(self.last_report[0..report.len], report);
        
        _ = self.reports_processed.fetchAdd(1, .release);
    }
    
    fn processKeyboardReport(self: *Self, report: []const u8) !void {
        if (report.len < 8) return; // Invalid keyboard report
        
        const dev = self.input_device orelse return;
        
        // Byte 0: Modifier keys
        const modifiers = report[0];
        const modifier_keys = [_]u16{
            input.KEY_LEFTCTRL,
            input.KEY_LEFTSHIFT,
            input.KEY_LEFTALT,
            input.KEY_LEFTMETA,
            input.KEY_RIGHTCTRL,
            input.KEY_RIGHTSHIFT,
            input.KEY_RIGHTALT,
            input.KEY_RIGHTMETA,
        };
        
        // Check modifier changes
        const last_modifiers = self.last_report[0];
        for (modifier_keys, 0..) |key, i| {
            const bit = @as(u8, 1) << @intCast(i);
            const pressed = (modifiers & bit) != 0;
            const was_pressed = (last_modifiers & bit) != 0;
            
            if (pressed != was_pressed) {
                try dev.reportKey(key, pressed);
            }
        }
        
        // Bytes 2-7: Key codes (up to 6 keys)
        const keycodes = report[2..8];
        const last_keycodes = self.last_report[2..8];
        
        // Check for released keys
        for (last_keycodes) |last_key| {
            if (last_key == 0) continue;
            
            var found = false;
            for (keycodes) |key| {
                if (key == last_key) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                // Key was released
                const linux_key = hidToLinuxKeycode(last_key);
                if (linux_key != 0) {
                    try dev.reportKey(linux_key, false);
                }
            }
        }
        
        // Check for pressed keys
        for (keycodes) |key| {
            if (key == 0) continue;
            
            var found = false;
            for (last_keycodes) |last_key| {
                if (key == last_key) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                // Key was pressed
                const linux_key = hidToLinuxKeycode(key);
                if (linux_key != 0) {
                    try dev.reportKey(linux_key, true);
                }
            }
        }
        
        // Sync events
        try dev.syncEvents();
    }
    
    fn processMouseReport(self: *Self, report: []const u8, delta_time: u64) !void {
        if (report.len < 3) return; // Invalid mouse report
        
        const dev = self.input_device orelse return;
        
        // Byte 0: Button state
        const buttons = report[0];
        const button_map = [_]struct { bit: u8, key: u16 }{
            .{ .bit = 0x01, .key = input.BTN_LEFT },
            .{ .bit = 0x02, .key = input.BTN_RIGHT },
            .{ .bit = 0x04, .key = input.BTN_MIDDLE },
            .{ .bit = 0x08, .key = input.BTN_SIDE },
            .{ .bit = 0x10, .key = input.BTN_EXTRA },
        };
        
        // Report button changes
        const last_buttons = self.last_report[0];
        for (button_map) |btn| {
            const pressed = (buttons & btn.bit) != 0;
            const was_pressed = (last_buttons & btn.bit) != 0;
            
            if (pressed != was_pressed) {
                try dev.reportKey(btn.key, pressed);
            }
        }
        
        // Bytes 1-2: X/Y movement (signed)
        const x_movement = @as(i8, @bitCast(report[1]));
        const y_movement = @as(i8, @bitCast(report[2]));
        
        if (x_movement != 0) {
            try dev.reportRel(.x, x_movement);
        }
        if (y_movement != 0) {
            try dev.reportRel(.y, -y_movement); // Invert Y axis
        }
        
        // Byte 3: Wheel (if present)
        if (report.len >= 4) {
            const wheel = @as(i8, @bitCast(report[3]));
            if (wheel != 0) {
                try dev.reportRel(.wheel, -wheel); // Invert wheel
            }
        }
        
        // Report timing information for gaming optimization
        if (self.usb_device.is_gaming_device and delta_time > 0) {
            const actual_rate = 1_000_000_000 / delta_time;
            dev.properties.actual_polling_rate_hz = @intCast(actual_rate);
        }
        
        // Sync events
        try dev.syncEvents();
    }
    
    fn processGenericReport(self: *Self, report: []const u8) !void {
        // TODO: Implement generic HID report processing based on report descriptor
        _ = self;
        _ = report;
    }
    
    pub fn setLeds(self: *Self, leds: u8) !void {
        if (self.protocol != .keyboard) return;
        
        var report: [1]u8 = .{leds};
        
        var setup = usb.SetupPacket{
            .request_type = 0x21, // Host to device, class, interface
            .request = @intFromEnum(HIDRequest.set_report),
            .value = (@as(u16, @intFromEnum(ReportType.output)) << 8) | 0,
            .index = self.interface.descriptor.interface_number,
            .length = 1,
        };
        
        try self.usb_device.controlTransfer(&setup, &report);
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.use_high_speed_polling = true;
        self.polling_rate_hz = 1000;
        
        if (self.input_device) |dev| {
            dev.properties.gaming_mode = true;
            dev.properties.polling_rate_hz = 1000;
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.use_high_speed_polling = false;
        self.configurePollingRate();
        
        if (self.input_device) |dev| {
            dev.properties.gaming_mode = false;
            dev.properties.polling_rate_hz = self.polling_rate_hz;
        }
    }
    
    pub fn getPerformanceMetrics(self: *Self) HIDPerformanceMetrics {
        return HIDPerformanceMetrics{
            .reports_received = self.reports_received.load(.acquire),
            .reports_processed = self.reports_processed.load(.acquire),
            .polling_rate_hz = self.polling_rate_hz,
            .use_high_speed_polling = self.use_high_speed_polling,
            .is_gaming_device = self.usb_device.is_gaming_device,
        };
    }
};

/// HID performance metrics
pub const HIDPerformanceMetrics = struct {
    reports_received: u64,
    reports_processed: u64,
    polling_rate_hz: u32,
    use_high_speed_polling: bool,
    is_gaming_device: bool,
};

/// HID to Linux keycode mapping
fn hidToLinuxKeycode(hid_code: u8) u16 {
    return switch (hid_code) {
        0x04 => input.KEY_A,
        0x05 => input.KEY_B,
        0x06 => input.KEY_C,
        0x07 => input.KEY_D,
        0x08 => input.KEY_E,
        0x09 => input.KEY_F,
        0x0A => input.KEY_G,
        0x0B => input.KEY_H,
        0x0C => input.KEY_I,
        0x0D => input.KEY_J,
        0x0E => input.KEY_K,
        0x0F => input.KEY_L,
        0x10 => input.KEY_M,
        0x11 => input.KEY_N,
        0x12 => input.KEY_O,
        0x13 => input.KEY_P,
        0x14 => input.KEY_Q,
        0x15 => input.KEY_R,
        0x16 => input.KEY_S,
        0x17 => input.KEY_T,
        0x18 => input.KEY_U,
        0x19 => input.KEY_V,
        0x1A => input.KEY_W,
        0x1B => input.KEY_X,
        0x1C => input.KEY_Y,
        0x1D => input.KEY_Z,
        0x1E => input.KEY_1,
        0x1F => input.KEY_2,
        0x20 => input.KEY_3,
        0x21 => input.KEY_4,
        0x22 => input.KEY_5,
        0x23 => input.KEY_6,
        0x24 => input.KEY_7,
        0x25 => input.KEY_8,
        0x26 => input.KEY_9,
        0x27 => input.KEY_0,
        0x28 => input.KEY_ENTER,
        0x29 => input.KEY_ESC,
        0x2A => input.KEY_BACKSPACE,
        0x2B => input.KEY_TAB,
        0x2C => input.KEY_SPACE,
        0x2D => input.KEY_MINUS,
        0x2E => input.KEY_EQUAL,
        0x2F => input.KEY_LEFTBRACE,
        0x30 => input.KEY_RIGHTBRACE,
        0x31 => input.KEY_BACKSLASH,
        0x33 => input.KEY_SEMICOLON,
        0x34 => input.KEY_APOSTROPHE,
        0x35 => input.KEY_GRAVE,
        0x36 => input.KEY_COMMA,
        0x37 => input.KEY_DOT,
        0x38 => input.KEY_SLASH,
        0x39 => input.KEY_CAPSLOCK,
        0x3A => input.KEY_F1,
        0x3B => input.KEY_F2,
        0x3C => input.KEY_F3,
        0x3D => input.KEY_F4,
        0x3E => input.KEY_F5,
        0x3F => input.KEY_F6,
        0x40 => input.KEY_F7,
        0x41 => input.KEY_F8,
        0x42 => input.KEY_F9,
        0x43 => input.KEY_F10,
        0x44 => input.KEY_F11,
        0x45 => input.KEY_F12,
        0x46 => input.KEY_SYSRQ,
        0x47 => input.KEY_SCROLLLOCK,
        0x48 => input.KEY_PAUSE,
        0x49 => input.KEY_INSERT,
        0x4A => input.KEY_HOME,
        0x4B => input.KEY_PAGEUP,
        0x4C => input.KEY_DELETE,
        0x4D => input.KEY_END,
        0x4E => input.KEY_PAGEDOWN,
        0x4F => input.KEY_RIGHT,
        0x50 => input.KEY_LEFT,
        0x51 => input.KEY_DOWN,
        0x52 => input.KEY_UP,
        0x53 => input.KEY_NUMLOCK,
        else => 0,
    };
}

/// USB HID driver
pub const usb_hid_driver = usb.USBDriver{
    .name = "usbhid",
    .probe = hidProbe,
    .disconnect = hidDisconnect,
    .enable_gaming_mode = hidEnableGamingMode,
    .disable_gaming_mode = hidDisableGamingMode,
    .supported_devices = &[_]usb.USBDriver.DeviceID{
        // Support all HID class devices
        .{ .vendor_id = 0, .product_id = 0, .class = .hid },
    },
};

fn hidProbe(device: *usb.USBDevice, interface: *usb.Interface) !void {
    // Only handle HID class interfaces
    if (interface.descriptor.interface_class != @intFromEnum(usb.USBClass.hid)) {
        return error.NotHIDDevice;
    }
    
    // Create HID device
    const allocator = device.allocator;
    const hid = try allocator.create(HIDDevice);
    hid.* = try HIDDevice.init(allocator, device, interface);
    
    // Store in interface private data
    interface.driver = &usb_hid_driver;
    
    // Start the HID device
    try hid.start();
}

fn hidDisconnect(device: *usb.USBDevice, interface: *usb.Interface) void {
    _ = device;
    _ = interface;
    // TODO: Clean up HID device
}

fn hidEnableGamingMode(device: *usb.USBDevice, interface: *usb.Interface) void {
    _ = device;
    _ = interface;
    // TODO: Enable gaming mode on HID device
}

fn hidDisableGamingMode(device: *usb.USBDevice, interface: *usb.Interface) void {
    _ = device;
    _ = interface;
    // TODO: Disable gaming mode on HID device
}