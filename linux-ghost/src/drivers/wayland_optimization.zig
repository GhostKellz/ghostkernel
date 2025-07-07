//! Wayland Optimization Module for Ghost Kernel
//! Provides kernel-level optimizations for Wayland compositors and applications
//! Focused on gaming performance, low latency, and smooth frame delivery

const std = @import("std");
const driver_framework = @import("driver_framework.zig");
const memory = @import("../mm/memory.zig");
const sched = @import("../kernel/sched.zig");
const sync = @import("../kernel/sync.zig");

/// Wayland protocol optimization levels
pub const OptimizationLevel = enum(u8) {
    none = 0,           // No optimizations
    basic = 1,          // Basic optimizations
    gaming = 2,         // Gaming-focused optimizations
    professional = 3,   // Professional/creator workload optimizations
    maximum = 4,        // Maximum performance (may impact power)
};

/// Wayland surface types for optimization targeting
pub const SurfaceType = enum(u8) {
    desktop = 0,        // Desktop background/shell
    application = 1,    // Regular application window
    game = 2,           // Fullscreen game
    video = 3,          // Video player
    overlay = 4,        // Overlay/notification
    cursor = 5,         // Mouse cursor
    tooltip = 6,        // Tooltip/popup
};

/// Frame scheduling modes
pub const FrameSchedulingMode = enum(u8) {
    vsync = 0,          // Traditional VSync
    immediate = 1,      // Immediate presentation (tearing allowed)
    mailbox = 2,        // Mailbox (triple buffering)
    adaptive = 3,       // Adaptive sync (VRR)
    low_latency = 4,    // Optimized for minimal latency
};

/// Compositor hints for kernel optimization
pub const CompositorState = struct {
    active_surfaces: u32,       // Number of active surfaces
    fullscreen_surface: bool,   // Fullscreen application active
    gaming_session: bool,       // Gaming session detected
    video_playback: bool,       // Video playback active
    overlay_count: u8,          // Number of overlay surfaces
    expected_fps: u32,          // Expected frame rate
    vrr_enabled: bool,          // Variable refresh rate enabled
    hdr_enabled: bool,          // HDR mode active
    power_profile: enum { battery, balanced, performance },
};

/// Wayland buffer information
pub const WaylandSurface = struct {
    id: u32,                    // Surface ID
    surface_type: SurfaceType,  // Surface type for optimization
    width: u32,                 // Surface width
    height: u32,                // Surface height
    format: u32,                // DRM pixel format
    modifier: u64,              // Format modifier
    refresh_rate: u32,          // Target refresh rate
    scheduling_mode: FrameSchedulingMode,
    priority: u8,               // Scheduling priority (0-255)
    
    // Performance tracking
    frame_count: u64,           // Total frames presented
    missed_frames: u32,         // Missed frame deadlines
    avg_frame_time_ns: u64,     // Average frame time
    last_present_time: u64,     // Last presentation timestamp
    
    // Buffer state
    current_buffer: ?*WaylandBufferInfo = null,
    pending_buffer: ?*WaylandBufferInfo = null,
    
    // Optimization state
    gaming_optimized: bool = false,
    low_latency_mode: bool = false,
    direct_scanout: bool = false,
    
    const Self = @This();
    
    pub fn updateFrameStats(self: *Self, present_time: u64) void {
        if (self.last_present_time != 0) {
            const frame_time = present_time - self.last_present_time;
            
            // Update average frame time (exponential moving average)
            if (self.avg_frame_time_ns == 0) {
                self.avg_frame_time_ns = frame_time;
            } else {
                // 90% old value, 10% new value
                self.avg_frame_time_ns = (self.avg_frame_time_ns * 9 + frame_time) / 10;
            }
            
            // Check for missed frames (assuming 60 FPS target)
            const target_frame_time = 16_666_667; // 16.67ms in nanoseconds
            if (frame_time > target_frame_time * 2) {
                self.missed_frames += 1;
            }
        }
        
        self.last_present_time = present_time;
        self.frame_count += 1;
    }
    
    pub fn getFrameRate(self: *Self) f32 {
        if (self.avg_frame_time_ns == 0) return 0.0;
        return 1_000_000_000.0 / @as(f32, @floatFromInt(self.avg_frame_time_ns));
    }
    
    pub fn getMissedFrameRate(self: *Self) f32 {
        if (self.frame_count == 0) return 0.0;
        return @as(f32, @floatFromInt(self.missed_frames)) / @as(f32, @floatFromInt(self.frame_count));
    }
};

/// Wayland buffer information
pub const WaylandBufferInfo = struct {
    dmabuf_fd: i32,             // DMA-BUF file descriptor
    width: u32,                 // Buffer width
    height: u32,                // Buffer height
    stride: u32,                // Buffer stride
    format: u32,                // DRM pixel format
    modifier: u64,              // Format modifier
    offset: u64,                // Buffer offset
    size: u64,                  // Buffer size
    
    // Synchronization
    acquire_fence: i32 = -1,    // Acquire fence FD
    release_fence: i32 = -1,    // Release fence FD
    
    // Timing
    target_present_time: u64 = 0, // Target presentation time
    actual_present_time: u64 = 0, // Actual presentation time
    
    // GPU state
    gpu_usage: bool = false,    // Currently used by GPU
    scanout_capable: bool = false, // Can be scanned out directly
};

/// Wayland optimization manager
pub const WaylandOptimizer = struct {
    allocator: std.mem.Allocator,
    surfaces: std.HashMap(u32, *WaylandSurface),
    compositor_state: CompositorState,
    optimization_level: OptimizationLevel,
    
    // Performance tracking
    total_frames: u64,
    total_missed_frames: u32,
    optimization_stats: OptimizationStats,
    
    // Scheduling
    frame_scheduler: FrameScheduler,
    buffer_pool: BufferPool,
    
    // Device integration
    display_device: ?*driver_framework.Device = null,
    gpu_device: ?*driver_framework.Device = null,
    
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .surfaces = std.HashMap(u32, *WaylandSurface).init(allocator),
            .compositor_state = std.mem.zeroes(CompositorState),
            .optimization_level = .basic,
            .total_frames = 0,
            .total_missed_frames = 0,
            .optimization_stats = std.mem.zeroes(OptimizationStats),
            .frame_scheduler = FrameScheduler.init(allocator),
            .buffer_pool = BufferPool.init(allocator),
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up surfaces
        var surface_iter = self.surfaces.iterator();
        while (surface_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.surfaces.deinit();
        
        self.frame_scheduler.deinit();
        self.buffer_pool.deinit();
    }
    
    pub fn setOptimizationLevel(self: *Self, level: OptimizationLevel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.optimization_level = level;
        
        // Apply optimization level to all surfaces
        var surface_iter = self.surfaces.iterator();
        while (surface_iter.next()) |entry| {
            self.applySurfaceOptimizations(entry.value_ptr.*);
        }
        
        // Configure devices based on optimization level
        self.configureDeviceOptimizations();
    }
    
    pub fn registerSurface(self: *Self, surface: *WaylandSurface) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.surfaces.put(surface.id, surface);
        self.applySurfaceOptimizations(surface);
        self.updateCompositorState();
    }
    
    pub fn unregisterSurface(self: *Self, surface_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.surfaces.fetchRemove(surface_id)) |removed| {
            self.allocator.destroy(removed.value);
        }
        self.updateCompositorState();
    }
    
    pub fn submitBuffer(self: *Self, surface_id: u32, buffer: *WaylandBufferInfo, present_time: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const surface = self.surfaces.get(surface_id) orelse return error.InvalidSurface;
        
        // Set pending buffer
        surface.pending_buffer = buffer;
        buffer.target_present_time = present_time;
        
        // Schedule frame presentation
        try self.frame_scheduler.scheduleFrame(surface, buffer, present_time);
        
        // Apply gaming optimizations if needed
        if (surface.gaming_optimized) {
            try self.applyGamingOptimizations(surface, buffer);
        }
        
        // Handle direct scanout for fullscreen surfaces
        if (self.compositor_state.fullscreen_surface and surface.surface_type == .game) {
            try self.attemptDirectScanout(surface, buffer);
        }
    }
    
    pub fn presentFrame(self: *Self, surface_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const surface = self.surfaces.get(surface_id) orelse return error.InvalidSurface;
        
        if (surface.pending_buffer) |buffer| {
            // Commit pending buffer
            surface.current_buffer = buffer;
            surface.pending_buffer = null;
            
            // Update frame statistics
            const present_time = std.time.nanoTimestamp();
            buffer.actual_present_time = @intCast(present_time);
            surface.updateFrameStats(@intCast(present_time));
            
            // Update global statistics
            self.total_frames += 1;
            if (buffer.actual_present_time > buffer.target_present_time + 1_000_000) { // 1ms tolerance
                self.total_missed_frames += 1;
            }
            
            // Notify frame scheduler
            self.frame_scheduler.framePresented(surface);
            
            // Return buffer to pool if possible
            try self.buffer_pool.returnBuffer(buffer);
        }
    }
    
    pub fn setCompositorHints(self: *Self, hints: *driver_framework.CompositorHints) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.compositor_state.expected_fps = hints.expected_fps;
        self.compositor_state.gaming_session = hints.gaming_session;
        self.compositor_state.fullscreen_app = hints.fullscreen_app;
        self.compositor_state.overlay_count = hints.overlay_count;
        self.compositor_state.vrr_enabled = hints.vrr_enabled;
        self.compositor_state.hdr_enabled = hints.hdr_enabled;
        
        // Adjust optimization level based on hints
        if (hints.gaming_session and hints.low_latency_mode) {
            self.optimization_level = .gaming;
        } else if (hints.gaming_session) {
            self.optimization_level = .basic;
        }
        
        self.configureDeviceOptimizations();
    }
    
    fn applySurfaceOptimizations(self: *Self, surface: *WaylandSurface) void {
        switch (self.optimization_level) {
            .none => {
                surface.gaming_optimized = false;
                surface.low_latency_mode = false;
            },
            .basic => {
                surface.gaming_optimized = surface.surface_type == .game;
                surface.low_latency_mode = false;
            },
            .gaming => {
                surface.gaming_optimized = surface.surface_type == .game;
                surface.low_latency_mode = surface.surface_type == .game;
                if (surface.surface_type == .game) {
                    surface.priority = 255; // Highest priority
                    surface.scheduling_mode = .low_latency;
                }
            },
            .professional => {
                surface.gaming_optimized = surface.surface_type == .game or surface.surface_type == .video;
                surface.low_latency_mode = false;
            },
            .maximum => {
                surface.gaming_optimized = true;
                surface.low_latency_mode = true;
                surface.priority = 255;
                surface.scheduling_mode = .immediate;
            },
        }
    }
    
    fn configureDeviceOptimizations(self: *Self) void {
        // Configure GPU device optimizations
        if (self.gpu_device) |gpu| {
            switch (self.optimization_level) {
                .gaming, .maximum => {
                    gpu.setGamingMode(true) catch {};
                    gpu.setLowLatency(true) catch {};
                },
                .basic, .professional => {
                    gpu.setGamingMode(self.compositor_state.gaming_session) catch {};
                    gpu.setLowLatency(false) catch {};
                },
                .none => {
                    gpu.setGamingMode(false) catch {};
                    gpu.setLowLatency(false) catch {};
                },
            }
            
            // Set compositor hints
            var hints = driver_framework.CompositorHints{
                .expected_fps = self.compositor_state.expected_fps,
                .vsync_enabled = true, // Wayland is always VSync'd
                .low_latency_mode = self.optimization_level == .gaming or self.optimization_level == .maximum,
                .gaming_session = self.compositor_state.gaming_session,
                .overlay_count = self.compositor_state.overlay_count,
                .fullscreen_app = self.compositor_state.fullscreen_app,
                .vrr_enabled = self.compositor_state.vrr_enabled,
                .hdr_enabled = self.compositor_state.hdr_enabled,
            };
            gpu.setCompositorHints(&hints) catch {};
        }
        
        // Configure display device optimizations
        if (self.display_device) |display| {
            display.enableWaylandMode() catch {};
        }
    }
    
    fn applyGamingOptimizations(self: *Self, surface: *WaylandSurface, buffer: *WaylandBufferInfo) !void {
        // Boost scheduling priority for gaming surfaces
        if (surface.surface_type == .game) {
            // TODO: Boost process priority
            // TODO: Pin to performance CPU cores
            // TODO: Disable CPU frequency scaling
        }
        
        // Optimize buffer handling
        if (buffer.scanout_capable and self.compositor_state.fullscreen_app) {
            // Enable direct scanout for fullscreen games
            try self.attemptDirectScanout(surface, buffer);
        }
        
        // Minimize memory copies
        buffer.gpu_usage = true;
    }
    
    fn attemptDirectScanout(self: *Self, surface: *WaylandSurface, buffer: *WaylandBufferInfo) !void {
        // Check if direct scanout is possible
        if (!buffer.scanout_capable) return;
        if (!self.compositor_state.fullscreen_app) return;
        if (self.compositor_state.overlay_count > 0) return;
        
        // Configure display device for direct scanout
        if (self.display_device) |display| {
            var wayland_buffer = driver_framework.WaylandBuffer{
                .width = buffer.width,
                .height = buffer.height,
                .stride = buffer.stride,
                .format = buffer.format,
                .dmabuf_fd = buffer.dmabuf_fd,
                .offset = buffer.offset,
                .modifier = buffer.modifier,
                .timestamp = buffer.target_present_time,
                .fence_fd = buffer.acquire_fence,
            };
            
            try display.submitWaylandBuffer(&wayland_buffer);
            surface.direct_scanout = true;
        }
    }
    
    fn updateCompositorState(self: *Self) void {
        self.compositor_state.active_surfaces = @intCast(self.surfaces.count());
        
        // Check for fullscreen gaming surface
        self.compositor_state.fullscreen_surface = false;
        self.compositor_state.gaming_session = false;
        self.compositor_state.overlay_count = 0;
        
        var surface_iter = self.surfaces.iterator();
        while (surface_iter.next()) |entry| {
            const surface = entry.value_ptr.*;
            
            if (surface.surface_type == .game) {
                self.compositor_state.gaming_session = true;
                if (surface.width >= 1920 and surface.height >= 1080) {
                    self.compositor_state.fullscreen_surface = true;
                }
            } else if (surface.surface_type == .overlay) {
                self.compositor_state.overlay_count += 1;
            }
        }
    }
    
    pub fn getOptimizationStats(self: *Self) OptimizationStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var stats = OptimizationStats{
            .total_surfaces = @intCast(self.surfaces.count()),
            .gaming_surfaces = 0,
            .direct_scanout_surfaces = 0,
            .average_fps = 0.0,
            .missed_frame_rate = 0.0,
            .optimization_level = self.optimization_level,
        };
        
        var total_fps: f32 = 0.0;
        var gaming_surfaces: u32 = 0;
        var scanout_surfaces: u32 = 0;
        
        var surface_iter = self.surfaces.iterator();
        while (surface_iter.next()) |entry| {
            const surface = entry.value_ptr.*;
            
            total_fps += surface.getFrameRate();
            
            if (surface.surface_type == .game) {
                gaming_surfaces += 1;
            }
            
            if (surface.direct_scanout) {
                scanout_surfaces += 1;
            }
        }
        
        stats.gaming_surfaces = gaming_surfaces;
        stats.direct_scanout_surfaces = scanout_surfaces;
        
        if (self.surfaces.count() > 0) {
            stats.average_fps = total_fps / @as(f32, @floatFromInt(self.surfaces.count()));
        }
        
        if (self.total_frames > 0) {
            stats.missed_frame_rate = @as(f32, @floatFromInt(self.total_missed_frames)) / @as(f32, @floatFromInt(self.total_frames));
        }
        
        return stats;
    }
};

/// Frame scheduler for optimal presentation timing
pub const FrameScheduler = struct {
    allocator: std.mem.Allocator,
    scheduled_frames: std.ArrayList(ScheduledFrame),
    
    const ScheduledFrame = struct {
        surface: *WaylandSurface,
        buffer: *WaylandBufferInfo,
        target_time: u64,
        priority: u8,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .scheduled_frames = std.ArrayList(ScheduledFrame).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.scheduled_frames.deinit();
    }
    
    pub fn scheduleFrame(self: *Self, surface: *WaylandSurface, buffer: *WaylandBufferInfo, target_time: u64) !void {
        const frame = ScheduledFrame{
            .surface = surface,
            .buffer = buffer,
            .target_time = target_time,
            .priority = surface.priority,
        };
        
        try self.scheduled_frames.append(frame);
        
        // Sort by target time and priority
        std.sort.insertion(ScheduledFrame, self.scheduled_frames.items, {}, struct {
            fn lessThan(_: void, a: ScheduledFrame, b: ScheduledFrame) bool {
                if (a.target_time != b.target_time) {
                    return a.target_time < b.target_time;
                }
                return a.priority > b.priority; // Higher priority first
            }
        }.lessThan);
    }
    
    pub fn framePresented(self: *Self, surface: *WaylandSurface) void {
        // Remove presented frame from schedule
        for (self.scheduled_frames.items, 0..) |frame, i| {
            if (frame.surface == surface) {
                _ = self.scheduled_frames.swapRemove(i);
                break;
            }
        }
    }
};

/// Buffer pool for efficient buffer reuse
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    available_buffers: std.ArrayList(*WaylandBufferInfo),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .available_buffers = std.ArrayList(*WaylandBufferInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up buffers
        for (self.available_buffers.items) |buffer| {
            self.allocator.destroy(buffer);
        }
        self.available_buffers.deinit();
    }
    
    pub fn getBuffer(self: *Self, width: u32, height: u32, format: u32) !*WaylandBufferInfo {
        // Try to reuse existing buffer
        for (self.available_buffers.items, 0..) |buffer, i| {
            if (buffer.width == width and buffer.height == height and buffer.format == format) {
                return self.available_buffers.swapRemove(i);
            }
        }
        
        // Allocate new buffer
        const buffer = try self.allocator.create(WaylandBufferInfo);
        buffer.* = std.mem.zeroes(WaylandBufferInfo);
        buffer.width = width;
        buffer.height = height;
        buffer.format = format;
        
        return buffer;
    }
    
    pub fn returnBuffer(self: *Self, buffer: *WaylandBufferInfo) !void {
        // Reset buffer state
        buffer.gpu_usage = false;
        buffer.acquire_fence = -1;
        buffer.release_fence = -1;
        buffer.target_present_time = 0;
        buffer.actual_present_time = 0;
        
        // Add back to pool
        try self.available_buffers.append(buffer);
    }
};

/// Optimization statistics
pub const OptimizationStats = struct {
    total_surfaces: u32,
    gaming_surfaces: u32,
    direct_scanout_surfaces: u32,
    average_fps: f32,
    missed_frame_rate: f32,
    optimization_level: OptimizationLevel,
};

// Global Wayland optimizer
var global_wayland_optimizer: ?*WaylandOptimizer = null;

/// Initialize Wayland optimization subsystem
pub fn initWaylandOptimization(allocator: std.mem.Allocator) !void {
    const optimizer = try allocator.create(WaylandOptimizer);
    optimizer.* = WaylandOptimizer.init(allocator);
    global_wayland_optimizer = optimizer;
}

/// Get the global Wayland optimizer
pub fn getWaylandOptimizer() *WaylandOptimizer {
    return global_wayland_optimizer orelse @panic("Wayland optimizer not initialized");
}

// Tests
test "surface registration and optimization" {
    const allocator = std.testing.allocator;
    
    var optimizer = WaylandOptimizer.init(allocator);
    defer optimizer.deinit();
    
    var surface = WaylandSurface{
        .id = 1,
        .surface_type = .game,
        .width = 1920,
        .height = 1080,
        .format = 0,
        .modifier = 0,
        .refresh_rate = 60,
        .scheduling_mode = .vsync,
        .priority = 128,
        .frame_count = 0,
        .missed_frames = 0,
        .avg_frame_time_ns = 0,
        .last_present_time = 0,
    };
    
    try optimizer.registerSurface(&surface);
    try std.testing.expect(optimizer.surfaces.count() == 1);
    
    optimizer.setOptimizationLevel(.gaming);
    try std.testing.expect(surface.gaming_optimized);
    try std.testing.expect(surface.low_latency_mode);
    
    optimizer.unregisterSurface(1);
    try std.testing.expect(optimizer.surfaces.count() == 0);
}

test "frame statistics tracking" {
    var surface = WaylandSurface{
        .id = 1,
        .surface_type = .game,
        .width = 1920,
        .height = 1080,
        .format = 0,
        .modifier = 0,
        .refresh_rate = 60,
        .scheduling_mode = .vsync,
        .priority = 128,
        .frame_count = 0,
        .missed_frames = 0,
        .avg_frame_time_ns = 0,
        .last_present_time = 0,
    };
    
    // Simulate 60 FPS
    const frame_time_60fps = 16_666_667; // nanoseconds
    
    surface.updateFrameStats(frame_time_60fps);
    surface.updateFrameStats(frame_time_60fps * 2);
    surface.updateFrameStats(frame_time_60fps * 3);
    
    try std.testing.expect(surface.frame_count == 3);
    try std.testing.expect(surface.avg_frame_time_ns > 0);
    
    const fps = surface.getFrameRate();
    try std.testing.expect(fps > 50.0 and fps < 70.0); // Roughly 60 FPS
}