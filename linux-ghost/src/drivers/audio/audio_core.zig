//! Audio Subsystem for Ghost Kernel
//! Pure Zig implementation with PipeWire compatibility and gaming optimizations
//! Focus on low-latency audio, professional audio workflows, and gaming

const std = @import("std");
const memory = @import("../../mm/memory.zig");
const sync = @import("../../kernel/sync.zig");
const driver_framework = @import("../driver_framework.zig");

/// Audio sample formats
pub const SampleFormat = enum(u8) {
    u8 = 0,         // 8-bit unsigned
    s16_le = 1,     // 16-bit signed little endian
    s16_be = 2,     // 16-bit signed big endian
    s24_le = 3,     // 24-bit signed little endian
    s24_be = 4,     // 24-bit signed big endian
    s32_le = 5,     // 32-bit signed little endian
    s32_be = 6,     // 32-bit signed big endian
    f32_le = 7,     // 32-bit float little endian
    f32_be = 8,     // 32-bit float big endian
    f64_le = 9,     // 64-bit float little endian
    f64_be = 10,    // 64-bit float big endian
    
    pub fn getBytesPerSample(self: SampleFormat) u8 {
        return switch (self) {
            .u8 => 1,
            .s16_le, .s16_be => 2,
            .s24_le, .s24_be => 3,
            .s32_le, .s32_be, .f32_le, .f32_be => 4,
            .f64_le, .f64_be => 8,
        };
    }
    
    pub fn isFloat(self: SampleFormat) bool {
        return switch (self) {
            .f32_le, .f32_be, .f64_le, .f64_be => true,
            else => false,
        };
    }
    
    pub fn isLittleEndian(self: SampleFormat) bool {
        return switch (self) {
            .u8 => true, // No endianness for 8-bit
            .s16_le, .s24_le, .s32_le, .f32_le, .f64_le => true,
            .s16_be, .s24_be, .s32_be, .f32_be, .f64_be => false,
        };
    }
};

/// Audio device types
pub const AudioDeviceType = enum(u8) {
    playback = 0,       // Output device (speakers, headphones)
    capture = 1,        // Input device (microphone)
    duplex = 2,         // Both input and output
    loopback = 3,       // Loopback device
    monitor = 4,        // Monitor of output device
};

/// Audio device classes for optimization
pub const AudioDeviceClass = enum(u8) {
    generic = 0,        // Generic audio device
    gaming_headset = 1, // Gaming headset with low latency
    studio_monitor = 2, // Professional studio monitor
    microphone = 3,     // Professional microphone
    usb_audio = 4,      // USB audio interface
    hdmi_audio = 5,     // HDMI audio output
    bluetooth = 6,      // Bluetooth audio device
    virtual = 7,        // Virtual audio device
};

/// Audio stream states
pub const StreamState = enum(u8) {
    inactive = 0,
    setup = 1,
    prepared = 2,
    running = 3,
    draining = 4,
    paused = 5,
    suspended = 6,
    disconnected = 7,
};

/// Audio latency profiles
pub const LatencyProfile = enum(u8) {
    power_save = 0,     // High latency, low power (100-500ms)
    balanced = 1,       // Balanced latency (20-50ms)
    low_latency = 2,    // Low latency (5-20ms)
    ultra_low = 3,      // Ultra low latency (<5ms)
    gaming = 4,         // Gaming optimized (<2ms)
    professional = 5,   // Professional audio (<1ms)
};

/// Audio buffer configuration
pub const BufferConfig = struct {
    sample_rate: u32,           // Sample rate in Hz
    channels: u16,              // Number of channels
    format: SampleFormat,       // Sample format
    buffer_size: u32,           // Buffer size in frames
    period_size: u32,           // Period size in frames
    periods: u8,                // Number of periods
    latency_profile: LatencyProfile,
    
    const Self = @This();
    
    pub fn getBytesPerFrame(self: Self) u32 {
        return @as(u32, self.format.getBytesPerSample()) * self.channels;
    }
    
    pub fn getBufferSizeBytes(self: Self) u32 {
        return self.buffer_size * self.getBytesPerFrame();
    }
    
    pub fn getPeriodSizeBytes(self: Self) u32 {
        return self.period_size * self.getBytesPerFrame();
    }
    
    pub fn getLatencyMs(self: Self) f32 {
        return (@as(f32, @floatFromInt(self.buffer_size)) / @as(f32, @floatFromInt(self.sample_rate))) * 1000.0;
    }
    
    pub fn isLowLatency(self: Self) bool {
        return switch (self.latency_profile) {
            .low_latency, .ultra_low, .gaming, .professional => true,
            else => false,
        };
    }
};

/// Audio buffer for streaming
pub const AudioBuffer = struct {
    data: []u8,
    frames: u32,
    channels: u16,
    format: SampleFormat,
    sample_rate: u32,
    
    // Timing information
    timestamp: u64,             // Presentation timestamp
    position: u64,              // Stream position in frames
    
    // Buffer state
    used: u32 = 0,             // Used bytes
    ready: bool = false,        // Ready for processing
    
    // Gaming optimizations
    low_latency: bool = false,  // Low latency buffer
    gaming_optimized: bool = false,
    priority: u8 = 128,         // Buffer priority (0-255)
    
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn alloc(allocator: std.mem.Allocator, config: BufferConfig) !*Self {
        const buffer_size = config.getBufferSizeBytes();
        const data = try allocator.alloc(u8, buffer_size);
        
        const buffer = try allocator.create(Self);
        buffer.* = Self{
            .data = data,
            .frames = config.buffer_size,
            .channels = config.channels,
            .format = config.format,
            .sample_rate = config.sample_rate,
            .timestamp = @intCast(std.time.nanoTimestamp()),
            .position = 0,
            .low_latency = config.isLowLatency(),
            .ref_count = std.atomic.Value(u32).init(1),
            .allocator = allocator,
        };
        
        return buffer;
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
    
    pub fn clear(self: *Self) void {
        @memset(self.data, 0);
        self.used = 0;
        self.ready = false;
    }
    
    pub fn write(self: *Self, data: []const u8) !usize {
        const available = self.data.len - self.used;
        const to_write = @min(data.len, available);
        
        if (to_write == 0) return 0;
        
        @memcpy(self.data[self.used..self.used + to_write], data[0..to_write]);
        self.used += @intCast(to_write);
        
        return to_write;
    }
    
    pub fn read(self: *Self, data: []u8) usize {
        const to_read = @min(data.len, self.used);
        
        if (to_read == 0) return 0;
        
        @memcpy(data[0..to_read], self.data[0..to_read]);
        
        // Shift remaining data
        if (self.used > to_read) {
            const remaining = self.used - @as(u32, @intCast(to_read));
            std.mem.copyForwards(u8, self.data[0..remaining], self.data[to_read..self.used]);
            self.used = remaining;
        } else {
            self.used = 0;
        }
        
        return to_read;
    }
    
    pub fn getSamplesAvailable(self: *Self) u32 {
        const bytes_per_frame = @as(u32, self.format.getBytesPerSample()) * self.channels;
        return self.used / bytes_per_frame;
    }
    
    pub fn isFull(self: *Self) bool {
        return self.used >= self.data.len;
    }
    
    pub fn isEmpty(self: *Self) bool {
        return self.used == 0;
    }
};

/// Audio stream
pub const AudioStream = struct {
    id: u32,
    device: *AudioDevice,
    config: BufferConfig,
    state: StreamState,
    device_type: AudioDeviceType,
    
    // Buffers
    playback_buffer: ?*AudioBuffer = null,
    capture_buffer: ?*AudioBuffer = null,
    
    // PipeWire compatibility
    pipewire_stream: ?*PipeWireStream = null,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_mode: bool = false,
    exclusive_mode: bool = false,
    
    // Performance metrics
    underruns: std.atomic.Value(u32),
    overruns: std.atomic.Value(u32),
    frames_processed: std.atomic.Value(u64),
    avg_latency_ns: std.atomic.Value(u64),
    
    // Callback for audio processing
    process_callback: ?*const fn (*AudioStream, *AudioBuffer) void = null,
    user_data: ?*anyopaque = null,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *AudioDevice, config: BufferConfig, device_type: AudioDeviceType) !Self {
        return Self{
            .id = @intCast(std.time.microTimestamp()),
            .device = device,
            .config = config,
            .state = .inactive,
            .device_type = device_type,
            .underruns = std.atomic.Value(u32).init(0),
            .overruns = std.atomic.Value(u32).init(0),
            .frames_processed = std.atomic.Value(u64).init(0),
            .avg_latency_ns = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.playback_buffer) |buf| buf.put();
        if (self.capture_buffer) |buf| buf.put();
        if (self.pipewire_stream) |pw_stream| {
            pw_stream.deinit();
            self.allocator.destroy(pw_stream);
        }
    }
    
    pub fn prepare(self: *Self) !void {
        // Allocate buffers based on device type
        switch (self.device_type) {
            .playback, .duplex => {
                self.playback_buffer = try AudioBuffer.alloc(self.allocator, self.config);
                self.playback_buffer.?.gaming_optimized = self.gaming_mode;
            },
            .capture, .duplex => {
                self.capture_buffer = try AudioBuffer.alloc(self.allocator, self.config);
                self.capture_buffer.?.gaming_optimized = self.gaming_mode;
            },
            else => {},
        }
        
        // Create PipeWire stream if needed
        if (self.device.pipewire_enabled) {
            self.pipewire_stream = try self.allocator.create(PipeWireStream);
            self.pipewire_stream.?.* = try PipeWireStream.init(self.allocator, self);
        }
        
        self.state = .prepared;
    }
    
    pub fn start(self: *Self) !void {
        if (self.state != .prepared) return error.InvalidState;
        
        // Start PipeWire stream if enabled
        if (self.pipewire_stream) |pw_stream| {
            try pw_stream.start();
        }
        
        self.state = .running;
        
        // Notify device
        try self.device.startStream(self);
    }
    
    pub fn stop(self: *Self) !void {
        if (self.state != .running) return error.InvalidState;
        
        // Stop PipeWire stream
        if (self.pipewire_stream) |pw_stream| {
            pw_stream.stop();
        }
        
        self.state = .inactive;
        
        // Notify device
        self.device.stopStream(self);
    }
    
    pub fn pause(self: *Self) void {
        if (self.state == .running) {
            self.state = .paused;
            
            // Pause PipeWire stream
            if (self.pipewire_stream) |pw_stream| {
                pw_stream.pause();
            }
        }
    }
    
    pub fn resume(self: *Self) !void {
        if (self.state == .paused) {
            self.state = .running;
            
            // Resume PipeWire stream
            if (self.pipewire_stream) |pw_stream| {
                try pw_stream.resume();
            }
        }
    }
    
    pub fn write(self: *Self, data: []const u8) !usize {
        if (self.state != .running) return error.InvalidState;
        if (self.playback_buffer == null) return error.NoBuffer;
        
        const written = try self.playback_buffer.?.write(data);
        
        // Update metrics
        const frames_written = written / self.config.getBytesPerFrame();
        _ = self.frames_processed.fetchAdd(frames_written, .release);
        
        return written;
    }
    
    pub fn read(self: *Self, data: []u8) !usize {
        if (self.state != .running) return error.InvalidState;
        if (self.capture_buffer == null) return error.NoBuffer;
        
        const read_bytes = self.capture_buffer.?.read(data);
        
        // Update metrics
        const frames_read = read_bytes / self.config.getBytesPerFrame();
        _ = self.frames_processed.fetchAdd(frames_read, .release);
        
        return read_bytes;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        self.low_latency_mode = enabled;
        
        if (self.playback_buffer) |buf| {
            buf.gaming_optimized = enabled;
            buf.priority = if (enabled) 255 else 128;
        }
        
        if (self.capture_buffer) |buf| {
            buf.gaming_optimized = enabled;
            buf.priority = if (enabled) 255 else 128;
        }
        
        // Update PipeWire stream properties
        if (self.pipewire_stream) |pw_stream| {
            pw_stream.setGamingMode(enabled);
        }
    }
    
    pub fn processAudio(self: *Self) void {
        if (self.state != .running) return;
        
        // Call user callback if set
        if (self.process_callback) |callback| {
            if (self.playback_buffer) |buf| {
                callback(self, buf);
            }
        }
        
        // Process PipeWire audio
        if (self.pipewire_stream) |pw_stream| {
            pw_stream.processAudio();
        }
    }
    
    pub fn getPerformanceMetrics(self: *Self) AudioStreamMetrics {
        return AudioStreamMetrics{
            .underruns = self.underruns.load(.acquire),
            .overruns = self.overruns.load(.acquire),
            .frames_processed = self.frames_processed.load(.acquire),
            .avg_latency_ns = self.avg_latency_ns.load(.acquire),
            .current_latency_ms = self.config.getLatencyMs(),
            .gaming_mode = self.gaming_mode,
            .low_latency_mode = self.low_latency_mode,
        };
    }
};

/// Audio device
pub const AudioDevice = struct {
    name: []const u8,
    device_class: AudioDeviceClass,
    device_type: AudioDeviceType,
    
    // Hardware capabilities
    supported_formats: []const SampleFormat,
    supported_rates: []const u32,
    max_channels: u16,
    min_channels: u16,
    
    // Current configuration
    current_config: ?BufferConfig = null,
    
    // Streams
    streams: std.ArrayList(*AudioStream),
    
    // PipeWire integration
    pipewire_enabled: bool = true,
    pipewire_device: ?*PipeWireDevice = null,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_capable: bool = false,
    exclusive_mode_capable: bool = false,
    
    // Device operations
    ops: *const AudioDeviceOps,
    
    // Driver integration
    driver_device: ?*driver_framework.Device = null,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, device_class: AudioDeviceClass, device_type: AudioDeviceType, ops: *const AudioDeviceOps) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .device_class = device_class,
            .device_type = device_type,
            .supported_formats = &[_]SampleFormat{ .s16_le, .s24_le, .s32_le, .f32_le },
            .supported_rates = &[_]u32{ 44100, 48000, 96000, 192000 },
            .max_channels = 8,
            .min_channels = 1,
            .streams = std.ArrayList(*AudioStream).init(allocator),
            .low_latency_capable = device_class == .gaming_headset or device_class == .studio_monitor,
            .exclusive_mode_capable = device_class == .studio_monitor or device_class == .gaming_headset,
            .ops = ops,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Close all streams
        for (self.streams.items) |stream| {
            stream.stop() catch {};
            stream.deinit();
            self.allocator.destroy(stream);
        }
        self.streams.deinit();
        
        // Clean up PipeWire device
        if (self.pipewire_device) |pw_device| {
            pw_device.deinit();
            self.allocator.destroy(pw_device);
        }
        
        self.allocator.free(self.name);
    }
    
    pub fn createStream(self: *Self, config: BufferConfig, device_type: AudioDeviceType) !*AudioStream {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Validate configuration
        if (!self.isConfigSupported(config)) {
            return error.UnsupportedConfiguration;
        }
        
        // Create stream
        const stream = try self.allocator.create(AudioStream);
        stream.* = try AudioStream.init(self.allocator, self, config, device_type);
        
        try self.streams.append(stream);
        
        // Apply gaming mode if enabled
        if (self.gaming_mode) {
            stream.setGamingMode(true);
        }
        
        return stream;
    }
    
    pub fn removeStream(self: *Self, stream: *AudioStream) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.streams.items, 0..) |s, i| {
            if (s == stream) {
                _ = self.streams.swapRemove(i);
                stream.deinit();
                self.allocator.destroy(stream);
                break;
            }
        }
    }
    
    pub fn startStream(self: *Self, stream: *AudioStream) !void {
        if (self.ops.start_stream) |start_fn| {
            try start_fn(self, stream);
        }
    }
    
    pub fn stopStream(self: *Self, stream: *AudioStream) void {
        if (self.ops.stop_stream) |stop_fn| {
            stop_fn(self, stream);
        }
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode = enabled;
        
        // Apply to all streams
        for (self.streams.items) |stream| {
            stream.setGamingMode(enabled);
        }
        
        // Notify driver device
        if (self.driver_device) |device| {
            device.setGamingMode(enabled) catch {};
        }
        
        // Configure PipeWire device
        if (self.pipewire_device) |pw_device| {
            pw_device.setGamingMode(enabled);
        }
    }
    
    fn isConfigSupported(self: *Self, config: BufferConfig) bool {
        // Check sample format
        const format_supported = for (self.supported_formats) |fmt| {
            if (fmt == config.format) break true;
        } else false;
        
        if (!format_supported) return false;
        
        // Check sample rate
        const rate_supported = for (self.supported_rates) |rate| {
            if (rate == config.sample_rate) break true;
        } else false;
        
        if (!rate_supported) return false;
        
        // Check channels
        if (config.channels < self.min_channels or config.channels > self.max_channels) {
            return false;
        }
        
        return true;
    }
    
    pub fn getPerformanceReport(self: *Self) AudioDeviceReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var report = AudioDeviceReport{
            .name = self.name,
            .device_class = self.device_class,
            .total_streams = @intCast(self.streams.items.len),
            .active_streams = 0,
            .total_underruns = 0,
            .total_overruns = 0,
            .avg_latency_ms = 0.0,
            .gaming_mode = self.gaming_mode,
        };
        
        var total_latency: f32 = 0.0;
        var active_count: u32 = 0;
        
        for (self.streams.items) |stream| {
            if (stream.state == .running) {
                report.active_streams += 1;
                active_count += 1;
                total_latency += stream.config.getLatencyMs();
            }
            
            const metrics = stream.getPerformanceMetrics();
            report.total_underruns += metrics.underruns;
            report.total_overruns += metrics.overruns;
        }
        
        if (active_count > 0) {
            report.avg_latency_ms = total_latency / @as(f32, @floatFromInt(active_count));
        }
        
        return report;
    }
};

/// Audio device operations
pub const AudioDeviceOps = struct {
    start_stream: ?*const fn (*AudioDevice, *AudioStream) !void = null,
    stop_stream: ?*const fn (*AudioDevice, *AudioStream) void = null,
    configure: ?*const fn (*AudioDevice, BufferConfig) !void = null,
    get_position: ?*const fn (*AudioDevice, *AudioStream) u64 = null,
    set_volume: ?*const fn (*AudioDevice, f32) !void = null,
    get_volume: ?*const fn (*AudioDevice) f32 = null,
};

/// PipeWire integration structures
pub const PipeWireStream = struct {
    stream: *AudioStream,
    state: StreamState,
    
    // PipeWire properties
    node_id: u32 = 0,
    media_class: []const u8,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    rt_priority: i32 = 0,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, stream: *AudioStream) !Self {
        const media_class = switch (stream.device_type) {
            .playback => "Audio/Sink",
            .capture => "Audio/Source",
            .duplex => "Audio/Duplex",
            else => "Audio/Sink",
        };
        
        return Self{
            .stream = stream,
            .state = .inactive,
            .media_class = media_class,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
        // TODO: Cleanup PipeWire resources
    }
    
    pub fn start(self: *Self) !void {
        self.state = .running;
        // TODO: Start PipeWire stream
    }
    
    pub fn stop(self: *Self) void {
        self.state = .inactive;
        // TODO: Stop PipeWire stream
    }
    
    pub fn pause(self: *Self) void {
        self.state = .paused;
        // TODO: Pause PipeWire stream
    }
    
    pub fn resume(self: *Self) !void {
        self.state = .running;
        // TODO: Resume PipeWire stream
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        self.rt_priority = if (enabled) 80 else 0; // High RT priority for gaming
        
        // TODO: Update PipeWire stream properties
    }
    
    pub fn processAudio(self: *Self) void {
        if (self.state != .running) return;
        
        // TODO: Process audio through PipeWire
        // This would involve:
        // 1. Reading from PipeWire buffers
        // 2. Processing audio data
        // 3. Writing to PipeWire buffers
        // 4. Handling timing and synchronization
    }
};

pub const PipeWireDevice = struct {
    device: *AudioDevice,
    
    // PipeWire device properties
    device_id: u32 = 0,
    factory_name: []const u8,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *AudioDevice) !Self {
        const factory_name = switch (device.device_class) {
            .gaming_headset => "api.alsa.pcm.device",
            .studio_monitor => "api.alsa.pcm.device",
            .usb_audio => "api.alsa.pcm.device",
            .bluetooth => "api.bluez5.pcm.device",
            else => "api.alsa.pcm.device",
        };
        
        return Self{
            .device = device,
            .factory_name = factory_name,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
        // TODO: Cleanup PipeWire device
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        // TODO: Update PipeWire device properties for gaming mode
    }
};

/// Audio subsystem manager
pub const AudioSubsystem = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(*AudioDevice),
    
    // PipeWire integration
    pipewire_enabled: bool = true,
    pipewire_core: ?*PipeWireCore = null,
    
    // Global audio state
    gaming_mode_enabled: bool = false,
    master_volume: f32 = 1.0,
    
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .devices = std.ArrayList(*AudioDevice).init(allocator),
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up devices
        for (self.devices.items) |device| {
            device.deinit();
            self.allocator.destroy(device);
        }
        self.devices.deinit();
        
        // Clean up PipeWire core
        if (self.pipewire_core) |core| {
            core.deinit();
            self.allocator.destroy(core);
        }
    }
    
    pub fn initPipeWire(self: *Self) !void {
        if (self.pipewire_enabled) {
            self.pipewire_core = try self.allocator.create(PipeWireCore);
            self.pipewire_core.?.* = try PipeWireCore.init(self.allocator);
        }
    }
    
    pub fn registerDevice(self: *Self, device: *AudioDevice) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.devices.append(device);
        
        // Create PipeWire device if enabled
        if (self.pipewire_enabled) {
            device.pipewire_device = try self.allocator.create(PipeWireDevice);
            device.pipewire_device.?.* = try PipeWireDevice.init(self.allocator, device);
        }
        
        // Apply gaming mode if enabled
        if (self.gaming_mode_enabled) {
            device.setGamingMode(true);
        }
    }
    
    pub fn unregisterDevice(self: *Self, device: *AudioDevice) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.devices.swapRemove(i);
                device.deinit();
                self.allocator.destroy(device);
                break;
            }
        }
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = true;
        
        // Apply to all devices
        for (self.devices.items) |device| {
            device.setGamingMode(true);
        }
        
        // Configure PipeWire for gaming
        if (self.pipewire_core) |core| {
            core.setGamingMode(true);
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = false;
        
        // Apply to all devices
        for (self.devices.items) |device| {
            device.setGamingMode(false);
        }
        
        // Configure PipeWire
        if (self.pipewire_core) |core| {
            core.setGamingMode(false);
        }
    }
    
    pub fn findDevice(self: *Self, name: []const u8) ?*AudioDevice {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.devices.items) |device| {
            if (std.mem.eql(u8, device.name, name)) {
                return device;
            }
        }
        return null;
    }
    
    pub fn getDefaultDevice(self: *Self, device_type: AudioDeviceType) ?*AudioDevice {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Prioritize gaming devices when gaming mode is enabled
        if (self.gaming_mode_enabled) {
            for (self.devices.items) |device| {
                if ((device.device_type == device_type or device.device_type == .duplex) and
                    device.device_class == .gaming_headset)
                {
                    return device;
                }
            }
        }
        
        // Find first matching device
        for (self.devices.items) |device| {
            if (device.device_type == device_type or device.device_type == .duplex) {
                return device;
            }
        }
        
        return null;
    }
    
    pub fn getSystemReport(self: *Self) AudioSystemReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var report = AudioSystemReport{
            .total_devices = @intCast(self.devices.items.len),
            .gaming_devices = 0,
            .active_streams = 0,
            .total_underruns = 0,
            .total_overruns = 0,
            .gaming_mode_enabled = self.gaming_mode_enabled,
            .pipewire_enabled = self.pipewire_enabled,
            .master_volume = self.master_volume,
        };
        
        for (self.devices.items) |device| {
            if (device.device_class == .gaming_headset) {
                report.gaming_devices += 1;
            }
            
            const device_report = device.getPerformanceReport();
            report.active_streams += device_report.active_streams;
            report.total_underruns += device_report.total_underruns;
            report.total_overruns += device_report.total_overruns;
        }
        
        return report;
    }
};

/// PipeWire core integration
pub const PipeWireCore = struct {
    // Core PipeWire state
    gaming_mode: bool = false,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
        // TODO: Cleanup PipeWire core resources
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        
        // TODO: Configure PipeWire core for gaming mode
        // This would involve:
        // - Setting quantum size for low latency
        // - Configuring RT scheduling
        // - Adjusting buffer sizes
        // - Setting up priority scheduling
    }
};

/// Performance metrics structures
pub const AudioStreamMetrics = struct {
    underruns: u32,
    overruns: u32,
    frames_processed: u64,
    avg_latency_ns: u64,
    current_latency_ms: f32,
    gaming_mode: bool,
    low_latency_mode: bool,
};

pub const AudioDeviceReport = struct {
    name: []const u8,
    device_class: AudioDeviceClass,
    total_streams: u32,
    active_streams: u32,
    total_underruns: u32,
    total_overruns: u32,
    avg_latency_ms: f32,
    gaming_mode: bool,
};

pub const AudioSystemReport = struct {
    total_devices: u32,
    gaming_devices: u32,
    active_streams: u32,
    total_underruns: u32,
    total_overruns: u32,
    gaming_mode_enabled: bool,
    pipewire_enabled: bool,
    master_volume: f32,
};

// Global audio subsystem
var global_audio_subsystem: ?*AudioSubsystem = null;

/// Initialize the audio subsystem
pub fn initAudioSubsystem(allocator: std.mem.Allocator) !void {
    const audio = try allocator.create(AudioSubsystem);
    audio.* = AudioSubsystem.init(allocator);
    global_audio_subsystem = audio;
    
    // Initialize PipeWire
    try audio.initPipeWire();
}

/// Get the global audio subsystem
pub fn getAudioSubsystem() *AudioSubsystem {
    return global_audio_subsystem orelse @panic("Audio subsystem not initialized");
}

// Tests
test "audio buffer operations" {
    const allocator = std.testing.allocator;
    
    const config = BufferConfig{
        .sample_rate = 48000,
        .channels = 2,
        .format = .s16_le,
        .buffer_size = 1024,
        .period_size = 256,
        .periods = 4,
        .latency_profile = .low_latency,
    };
    
    const buffer = try AudioBuffer.alloc(allocator, config);
    defer buffer.put();
    
    try std.testing.expect(buffer.frames == 1024);
    try std.testing.expect(buffer.channels == 2);
    try std.testing.expect(buffer.format == .s16_le);
    try std.testing.expect(buffer.isEmpty());
    
    const test_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const written = try buffer.write(&test_data);
    try std.testing.expect(written == 8);
    try std.testing.expect(!buffer.isEmpty());
    
    var read_data: [8]u8 = undefined;
    const read_bytes = buffer.read(&read_data);
    try std.testing.expect(read_bytes == 8);
    try std.testing.expect(std.mem.eql(u8, &test_data, &read_data));
    try std.testing.expect(buffer.isEmpty());
}

test "sample format properties" {
    try std.testing.expect(SampleFormat.s16_le.getBytesPerSample() == 2);
    try std.testing.expect(SampleFormat.s24_le.getBytesPerSample() == 3);
    try std.testing.expect(SampleFormat.f32_le.getBytesPerSample() == 4);
    
    try std.testing.expect(SampleFormat.f32_le.isFloat());
    try std.testing.expect(!SampleFormat.s16_le.isFloat());
    
    try std.testing.expect(SampleFormat.s16_le.isLittleEndian());
    try std.testing.expect(!SampleFormat.s16_be.isLittleEndian());
}

test "buffer configuration calculations" {
    const config = BufferConfig{
        .sample_rate = 48000,
        .channels = 2,
        .format = .s16_le,
        .buffer_size = 1024,
        .period_size = 256,
        .periods = 4,
        .latency_profile = .gaming,
    };
    
    try std.testing.expect(config.getBytesPerFrame() == 4); // 2 bytes/sample * 2 channels
    try std.testing.expect(config.getBufferSizeBytes() == 4096); // 1024 frames * 4 bytes/frame
    try std.testing.expect(config.getPeriodSizeBytes() == 1024); // 256 frames * 4 bytes/frame
    
    const latency_ms = config.getLatencyMs();
    try std.testing.expect(latency_ms > 21.0 and latency_ms < 22.0); // ~21.33ms
    try std.testing.expect(config.isLowLatency());
}

test "audio device management" {
    const allocator = std.testing.allocator;
    
    var audio = AudioSubsystem.init(allocator);
    defer audio.deinit();
    
    const ops = AudioDeviceOps{};
    const device = try allocator.create(AudioDevice);
    device.* = try AudioDevice.init(allocator, "Test Device", .gaming_headset, .duplex, &ops);
    
    try audio.registerDevice(device);
    try std.testing.expect(audio.devices.items.len == 1);
    
    const found = audio.findDevice("Test Device");
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == device);
    
    audio.enableGamingMode();
    try std.testing.expect(audio.gaming_mode_enabled);
    try std.testing.expect(device.gaming_mode);
}