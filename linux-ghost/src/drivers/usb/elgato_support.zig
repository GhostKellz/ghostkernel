//! Elgato Device Support for Ghost Kernel
//! Stream Deck, Capture Cards, Cam Link, and other Elgato devices
//! Optimized for content creation and streaming workflows

const std = @import("std");
const usb_core = @import("usb_core.zig");
const driver_framework = @import("../driver_framework.zig");

/// Elgato vendor ID
pub const ELGATO_VENDOR_ID = 0x0fd9;

/// Elgato product IDs
pub const ElgatoProduct = enum(u16) {
    stream_deck_original = 0x0060,
    stream_deck_mini = 0x0063,
    stream_deck_xl = 0x006c,
    stream_deck_v2 = 0x006d,
    stream_deck_mk2 = 0x0080,
    stream_deck_pedal = 0x0086,
    stream_deck_plus = 0x0084,
    cam_link_4k = 0x0038,
    cam_link_pro = 0x003c,
    hd60_s = 0x004f,
    hd60_s_plus = 0x0062,
    hd60_x = 0x006e,
    _,
};

/// Stream Deck button configuration
pub const StreamDeckButton = struct {
    id: u8,
    pressed: bool = false,
    image_data: ?[]const u8 = null,
    brightness: u8 = 100,
    
    const Self = @This();
    
    pub fn setImage(self: *Self, image_data: []const u8) void {
        self.image_data = image_data;
    }
    
    pub fn setBrightness(self: *Self, brightness: u8) void {
        self.brightness = @min(brightness, 100);
    }
};

/// Stream Deck device information
pub const StreamDeckInfo = struct {
    product_id: u16,
    rows: u8,
    cols: u8,
    total_buttons: u8,
    icon_size: u16,        // Icon resolution (e.g., 72x72)
    has_touchscreen: bool = false,
    has_rotary_encoders: bool = false,
    encoder_count: u8 = 0,
    
    pub fn getButtonCount(self: @This()) u8 {
        return self.total_buttons;
    }
    
    pub fn getIconSize(self: @This()) u16 {
        return self.icon_size;
    }
};

/// Elgato Stream Deck driver
pub const ElgatoStreamDeck = struct {
    device: *usb_core.USBDevice,
    info: StreamDeckInfo,
    buttons: []StreamDeckButton,
    brightness: u8 = 100,
    
    // Input handling
    input_callback: ?*const fn (*ElgatoStreamDeck, u8, bool) void = null,
    user_data: ?*anyopaque = null,
    
    // Streaming optimizations
    low_latency_mode: bool = false,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *usb_core.USBDevice) !Self {
        const info = getStreamDeckInfo(device.device_descriptor.product_id) orelse return error.UnsupportedDevice;
        
        const buttons = try allocator.alloc(StreamDeckButton, info.total_buttons);
        for (buttons, 0..) |*button, i| {
            button.* = StreamDeckButton{ .id = @intCast(i) };
        }
        
        return Self{
            .device = device,
            .info = info,
            .buttons = buttons,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buttons);
    }
    
    pub fn initialize(self: *Self) !void {
        // Reset device
        try self.reset();
        
        // Set brightness
        try self.setBrightness(self.brightness);
        
        // Clear all buttons
        try self.clearAllButtons();
    }
    
    pub fn reset(self: *Self) !void {
        const reset_cmd = [_]u8{ 0x0B, 0x63 };
        var urb = usb_core.URB{
            .device = self.device,
            .endpoint = 0,
            .transfer_type = .control,
            .direction = .out,
            .buffer = @constCast(&reset_cmd),
        };
        
        try self.device.submitTransfer(&urb);
    }
    
    pub fn setBrightness(self: *Self, brightness: u8) !void {
        self.brightness = @min(brightness, 100);
        
        const brightness_cmd = [_]u8{ 0x05, 0x55, 0xaa, 0xd1, 0x01, self.brightness };
        var urb = usb_core.URB{
            .device = self.device,
            .endpoint = 0,
            .transfer_type = .control,
            .direction = .out,
            .buffer = @constCast(&brightness_cmd),
        };
        
        try self.device.submitTransfer(&urb);
    }
    
    pub fn setButtonImage(self: *Self, button_id: u8, image_data: []const u8) !void {
        if (button_id >= self.buttons.len) return error.InvalidButton;
        
        // Convert image to device format and send
        const converted_image = try self.convertImageForDevice(image_data);
        defer self.allocator.free(converted_image);
        
        try self.sendImageToDevice(button_id, converted_image);
        
        self.buttons[button_id].setImage(image_data);
    }
    
    pub fn clearButton(self: *Self, button_id: u8) !void {
        if (button_id >= self.buttons.len) return error.InvalidButton;
        
        // Create black image
        const image_size = @as(usize, self.info.icon_size) * self.info.icon_size * 3; // RGB
        const black_image = try self.allocator.alloc(u8, image_size);
        defer self.allocator.free(black_image);
        @memset(black_image, 0);
        
        try self.setButtonImage(button_id, black_image);
    }
    
    pub fn clearAllButtons(self: *Self) !void {
        for (0..self.buttons.len) |i| {
            try self.clearButton(@intCast(i));
        }
    }
    
    pub fn setInputCallback(self: *Self, callback: *const fn (*ElgatoStreamDeck, u8, bool) void, user_data: ?*anyopaque) void {
        self.input_callback = callback;
        self.user_data = user_data;
    }
    
    pub fn processInput(self: *Self, input_data: []const u8) void {
        // Parse input report for button presses
        if (input_data.len < 2) return;
        
        const report_id = input_data[0];
        if (report_id != 0x01) return; // Button report
        
        // Check each button state
        for (self.buttons, 0..) |*button, i| {
            const byte_idx = 1 + (i / 8);
            const bit_idx = @intCast(i % 8);
            
            if (byte_idx < input_data.len) {
                const pressed = (input_data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                
                if (pressed != button.pressed) {
                    button.pressed = pressed;
                    
                    // Call callback
                    if (self.input_callback) |callback| {
                        callback(self, @intCast(i), pressed);
                    }
                }
            }
        }
    }
    
    pub fn enableLowLatencyMode(self: *Self, enabled: bool) void {
        self.low_latency_mode = enabled;
        
        // Configure device for low latency if supported
        if (enabled) {
            self.device.low_latency_mode = true;
            self.device.polling_rate_hz = 1000; // 1000 Hz polling
        }
    }
    
    fn convertImageForDevice(self: *Self, image_data: []const u8) ![]u8 {
        // Convert image to device-specific format
        // This is a simplified implementation
        const converted = try self.allocator.dupe(u8, image_data);
        return converted;
    }
    
    fn sendImageToDevice(self: *Self, button_id: u8, image_data: []const u8) !void {
        // Send image data to device in chunks
        const chunk_size = 1024; // Typical USB packet size
        var offset: usize = 0;
        
        while (offset < image_data.len) {
            const chunk_len = @min(chunk_size, image_data.len - offset);
            const chunk = image_data[offset..offset + chunk_len];
            
            // Create command packet
            var packet = try self.allocator.alloc(u8, chunk_len + 16); // Header + data
            defer self.allocator.free(packet);
            
            // Fill header (simplified)
            packet[0] = 0x02; // Image command
            packet[1] = 0x01; // Page 1
            packet[2] = button_id;
            packet[3] = @intCast(chunk_len & 0xFF);
            packet[4] = @intCast((chunk_len >> 8) & 0xFF);
            
            // Copy image data
            @memcpy(packet[16..16 + chunk_len], chunk);
            
            // Send packet
            var urb = usb_core.URB{
                .device = self.device,
                .endpoint = 0,
                .transfer_type = .control,
                .direction = .out,
                .buffer = packet,
                .low_latency = self.low_latency_mode,
            };
            
            try self.device.submitTransfer(&urb);
            
            offset += chunk_len;
        }
    }
};

/// Elgato capture device
pub const ElgatoCapture = struct {
    device: *usb_core.USBDevice,
    product_id: u16,
    resolution_width: u32,
    resolution_height: u32,
    framerate: u32,
    
    // Capture settings
    capture_format: CaptureFormat = .yuv422,
    hardware_encoding: bool = true,
    low_latency_mode: bool = false,
    
    // Performance metrics
    frames_captured: std.atomic.Value(u64),
    frames_dropped: std.atomic.Value(u32),
    avg_latency_ms: std.atomic.Value(u32),
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    const CaptureFormat = enum {
        yuv422,
        rgb24,
        nv12,
        h264,
        h265,
    };
    
    pub fn init(allocator: std.mem.Allocator, device: *usb_core.USBDevice) Self {
        return Self{
            .device = device,
            .product_id = device.device_descriptor.product_id,
            .resolution_width = 1920,
            .resolution_height = 1080,
            .framerate = 60,
            .frames_captured = std.atomic.Value(u64).init(0),
            .frames_dropped = std.atomic.Value(u32).init(0),
            .avg_latency_ms = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn setResolution(self: *Self, width: u32, height: u32) !void {
        self.resolution_width = width;
        self.resolution_height = height;
        
        // Configure device resolution
        try self.configureCapture();
    }
    
    pub fn setFramerate(self: *Self, fps: u32) !void {
        self.framerate = fps;
        try self.configureCapture();
    }
    
    pub fn enableLowLatencyMode(self: *Self, enabled: bool) !void {
        self.low_latency_mode = enabled;
        
        if (enabled) {
            // Configure for minimal latency
            self.hardware_encoding = false; // Use passthrough
            self.capture_format = .yuv422;   // Uncompressed
        }
        
        try self.configureCapture();
    }
    
    pub fn startCapture(self: *Self) !void {
        // Start capture stream
        const start_cmd = [_]u8{ 0x01, 0x00, 0x01 }; // Start capture
        var urb = usb_core.URB{
            .device = self.device,
            .endpoint = 0,
            .transfer_type = .control,
            .direction = .out,
            .buffer = @constCast(&start_cmd),
        };
        
        try self.device.submitTransfer(&urb);
    }
    
    pub fn stopCapture(self: *Self) !void {
        // Stop capture stream
        const stop_cmd = [_]u8{ 0x01, 0x00, 0x00 }; // Stop capture
        var urb = usb_core.URB{
            .device = self.device,
            .endpoint = 0,
            .transfer_type = .control,
            .direction = .out,
            .buffer = @constCast(&stop_cmd),
        };
        
        try self.device.submitTransfer(&urb);
    }
    
    fn configureCapture(self: *Self) !void {
        // Configure device for current settings
        // This would involve setting up video format, resolution, etc.
        _ = self;
    }
    
    pub fn getMetrics(self: *Self) CaptureMetrics {
        return CaptureMetrics{
            .frames_captured = self.frames_captured.load(.acquire),
            .frames_dropped = self.frames_dropped.load(.acquire),
            .avg_latency_ms = self.avg_latency_ms.load(.acquire),
            .current_resolution = .{
                .width = self.resolution_width,
                .height = self.resolution_height,
            },
            .current_framerate = self.framerate,
            .low_latency_mode = self.low_latency_mode,
        };
    }
};

/// Capture device metrics
pub const CaptureMetrics = struct {
    frames_captured: u64,
    frames_dropped: u32,
    avg_latency_ms: u32,
    current_resolution: struct { width: u32, height: u32 },
    current_framerate: u32,
    low_latency_mode: bool,
};

/// Get Stream Deck device information
fn getStreamDeckInfo(product_id: u16) ?StreamDeckInfo {
    return switch (@as(ElgatoProduct, @enumFromInt(product_id))) {
        .stream_deck_original => StreamDeckInfo{
            .product_id = product_id,
            .rows = 3,
            .cols = 5,
            .total_buttons = 15,
            .icon_size = 72,
        },
        .stream_deck_mini => StreamDeckInfo{
            .product_id = product_id,
            .rows = 2,
            .cols = 3,
            .total_buttons = 6,
            .icon_size = 80,
        },
        .stream_deck_xl => StreamDeckInfo{
            .product_id = product_id,
            .rows = 4,
            .cols = 8,
            .total_buttons = 32,
            .icon_size = 96,
        },
        .stream_deck_plus => StreamDeckInfo{
            .product_id = product_id,
            .rows = 2,
            .cols = 4,
            .total_buttons = 8,
            .icon_size = 120,
            .has_touchscreen = true,
            .has_rotary_encoders = true,
            .encoder_count = 4,
        },
        else => null,
    };
}

/// Elgato USB driver
pub const ElgatoDriver = struct {
    const supported_devices = [_]usb_core.USBDriver.DeviceID{
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.stream_deck_original) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.stream_deck_mini) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.stream_deck_xl) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.stream_deck_v2) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.stream_deck_plus) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.cam_link_4k) },
        .{ .vendor_id = ELGATO_VENDOR_ID, .product_id = @intFromEnum(ElgatoProduct.hd60_s_plus) },
    };
    
    pub fn probe(device: *usb_core.USBDevice, interface: *usb_core.Interface) !void {
        // Initialize device based on product ID
        switch (@as(ElgatoProduct, @enumFromInt(device.device_descriptor.product_id))) {
            .stream_deck_original, .stream_deck_mini, .stream_deck_xl, .stream_deck_v2, .stream_deck_plus => {
                // Initialize Stream Deck
                _ = interface;
                device.enableGamingMode(); // Low latency for streaming
            },
            .cam_link_4k, .cam_link_pro, .hd60_s, .hd60_s_plus, .hd60_x => {
                // Initialize capture device
                _ = interface;
                device.enableGamingMode(); // Low latency for capture
            },
            else => return error.UnsupportedDevice,
        }
    }
    
    pub fn disconnect(device: *usb_core.USBDevice, interface: *usb_core.Interface) void {
        _ = device;
        _ = interface;
        // Cleanup device resources
    }
    
    pub fn enableGamingMode(device: *usb_core.USBDevice, interface: *usb_core.Interface) void {
        _ = interface;
        device.enableGamingMode();
    }
    
    pub fn disableGamingMode(device: *usb_core.USBDevice, interface: *usb_core.Interface) void {
        _ = interface;
        device.disableGamingMode();
    }
};

/// Create Elgato USB driver
pub fn createElgatoDriver(allocator: std.mem.Allocator) !usb_core.USBDriver {
    return usb_core.USBDriver{
        .name = "elgato",
        .probe = ElgatoDriver.probe,
        .disconnect = ElgatoDriver.disconnect,
        .enable_gaming_mode = ElgatoDriver.enableGamingMode,
        .disable_gaming_mode = ElgatoDriver.disableGamingMode,
        .supported_devices = &ElgatoDriver.supported_devices,
    };
}

// Tests
test "Stream Deck device info" {
    const info = getStreamDeckInfo(@intFromEnum(ElgatoProduct.stream_deck_original));
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.total_buttons == 15);
    try std.testing.expect(info.?.icon_size == 72);
}

test "Stream Deck button management" {
    const allocator = std.testing.allocator;
    
    // Mock USB device
    var mock_device = usb_core.USBDevice.init(allocator, undefined, 1, .high);
    mock_device.device_descriptor.vendor_id = ELGATO_VENDOR_ID;
    mock_device.device_descriptor.product_id = @intFromEnum(ElgatoProduct.stream_deck_mini);
    
    var stream_deck = try ElgatoStreamDeck.init(allocator, &mock_device);
    defer stream_deck.deinit();
    
    try std.testing.expect(stream_deck.buttons.len == 6); // Mini has 6 buttons
    try std.testing.expect(stream_deck.info.icon_size == 80);
    
    // Test button state
    try std.testing.expect(!stream_deck.buttons[0].pressed);
    stream_deck.buttons[0].pressed = true;
    try std.testing.expect(stream_deck.buttons[0].pressed);
}