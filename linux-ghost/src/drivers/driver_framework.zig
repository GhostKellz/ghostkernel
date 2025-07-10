//! Device Driver Framework for Ghost Kernel
//! Pure Zig implementation providing type-safe device driver infrastructure
//! Optimized for gaming performance and low-latency operations

const std = @import("std");
const memory = @import("../mm/memory.zig");
const paging = @import("../mm/paging.zig");
const sync = @import("../kernel/sync.zig");

/// Device types
pub const DeviceType = enum(u8) {
    character = 0,      // Character devices (serial, input)
    block = 1,          // Block devices (storage)
    network = 2,        // Network devices  
    gpu = 3,            // Graphics devices
    audio = 4,          // Audio devices
    input = 5,          // Input devices (keyboard, mouse, gamepad)
    display = 6,        // Display controllers
    usb = 7,            // USB devices
    pci = 8,            // PCI devices
    platform = 9,       // Platform devices
};

/// Device power states
pub const PowerState = enum(u8) {
    on = 0,             // Fully powered
    standby = 1,        // Quick wake
    suspended = 2,      // Memory retained
    hibernate = 3,      // Power off, state saved
    off = 4,            // Completely powered off
};

/// DMA direction
pub const DMADirection = enum(u8) {
    bidirectional = 0,  // Can transfer in both directions
    to_device = 1,      // CPU to device
    from_device = 2,    // Device to CPU
    none = 3,           // No DMA transfers
};

/// Device capabilities
pub const DeviceCapabilities = packed struct(u32) {
    dma_coherent: bool = false,       // Supports coherent DMA
    dma_32bit: bool = false,          // 32-bit DMA addressing
    dma_64bit: bool = false,          // 64-bit DMA addressing
    hotplug: bool = false,            // Supports hotplug
    runtime_pm: bool = false,         // Runtime power management
    wakeup: bool = false,             // Can wake system
    msi: bool = false,                // MSI interrupts
    msix: bool = false,               // MSI-X interrupts
    gaming_optimized: bool = false,   // Gaming performance features
    wayland_optimized: bool = false,  // Wayland optimization support
    low_latency: bool = false,        // Low-latency operations
    _reserved: u21 = 0,
};

/// Interrupt handling flags
pub const InterruptFlags = packed struct(u32) {
    shared: bool = false,             // Shared interrupt line
    oneshot: bool = false,            // One-shot interrupt
    trigger_rising: bool = false,     // Rising edge trigger
    trigger_falling: bool = false,    // Falling edge trigger
    trigger_high: bool = false,       // High level trigger
    trigger_low: bool = false,        // Low level trigger
    wakeup: bool = false,             // Can wake system
    gaming_priority: bool = false,    // High priority for gaming
    _reserved: u24 = 0,
};

/// Device driver operations
pub const DeviceOps = struct {
    probe: ?*const fn (device: *Device) DriverError!void = null,
    remove: ?*const fn (device: *Device) void = null,
    device_suspend: ?*const fn (device: *Device, state: PowerState) DriverError!void = null,
    device_resume: ?*const fn (device: *Device) DriverError!void = null,
    shutdown: ?*const fn (device: *Device) void = null,
    
    // I/O operations
    open: ?*const fn (device: *Device, flags: u32) DriverError!*DeviceFile = null,
    close: ?*const fn (file: *DeviceFile) DriverError!void = null,
    read: ?*const fn (file: *DeviceFile, buffer: []u8, offset: u64) DriverError!usize = null,
    write: ?*const fn (file: *DeviceFile, buffer: []const u8, offset: u64) DriverError!usize = null,
    ioctl: ?*const fn (file: *DeviceFile, cmd: u32, arg: usize) DriverError!usize = null,
    mmap: ?*const fn (file: *DeviceFile, length: usize, prot: u32, flags: u32, offset: u64) DriverError!?*anyopaque = null,
    poll: ?*const fn (file: *DeviceFile, mask: u32) DriverError!u32 = null,
    
    // Gaming-specific operations
    set_gaming_mode: ?*const fn (device: *Device, enabled: bool) DriverError!void = null,
    set_low_latency: ?*const fn (device: *Device, enabled: bool) DriverError!void = null,
    get_performance_metrics: ?*const fn (device: *Device, metrics: *PerformanceMetrics) DriverError!void = null,
    
    // Wayland optimization operations
    enable_wayland_mode: ?*const fn (device: *Device) DriverError!void = null,
    submit_wayland_buffer: ?*const fn (device: *Device, buffer: *WaylandBuffer) DriverError!void = null,
    set_compositor_hints: ?*const fn (device: *Device, hints: *CompositorHints) DriverError!void = null,
};

/// Driver errors
pub const DriverError = error{
    DeviceNotFound,
    DeviceBusy,
    DeviceNotReady,
    InvalidOperation,
    InvalidParameter,
    InsufficientMemory,
    InsufficientResources,
    OperationNotSupported,
    PermissionDenied,
    TimeoutError,
    HardwareError,
    InterruptError,
    DMAError,
    PowerError,
    ProtocolError,
    BufferTooSmall,
    DeviceRemoved,
    GamingModeNotSupported,
    WaylandNotSupported,
};

/// Performance metrics for gaming optimization
pub const PerformanceMetrics = struct {
    avg_latency_ns: u64,        // Average operation latency
    max_latency_ns: u64,        // Maximum latency
    throughput_mbps: u32,       // Throughput in MB/s
    interrupt_count: u64,       // Total interrupts
    error_count: u32,           // Error count
    gaming_mode_active: bool,   // Gaming mode status
    wayland_mode_active: bool,  // Wayland mode status
    frame_drops: u32,           // Dropped frames (for display devices)
    bandwidth_utilization: u8,  // Bandwidth utilization percentage
};

/// Wayland buffer for optimized composition
pub const WaylandBuffer = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u32,                // DRM format
    dmabuf_fd: i32,            // DMA-BUF file descriptor
    offset: u64,               // Buffer offset
    modifier: u64,             // Format modifier
    timestamp: u64,            // Presentation timestamp
    fence_fd: i32,             // Synchronization fence
};

/// Compositor hints for optimization
pub const CompositorHints = struct {
    expected_fps: u32,          // Expected frame rate
    vsync_enabled: bool,        // VSync preference
    low_latency_mode: bool,     // Low latency preference
    gaming_session: bool,       // Gaming session active
    overlay_count: u8,          // Number of overlays
    fullscreen_app: bool,       // Fullscreen application
    vrr_enabled: bool,          // Variable refresh rate
    hdr_enabled: bool,          // HDR mode
};

/// DMA mapping
pub const DMAMapping = struct {
    virtual_addr: usize,        // Virtual address
    physical_addr: usize,       // Physical address  
    size: usize,                // Mapping size
    direction: DMADirection,    // Transfer direction
    coherent: bool,             // Coherent mapping
    
    const Self = @This();
    
    pub fn sync(self: *Self, direction: DMADirection) DriverError!void {
        if (!self.coherent) {
            // Sync cache for non-coherent mappings
            switch (direction) {
                .to_device => try self.flushCache(),
                .from_device => try self.invalidateCache(),
                .bidirectional => {
                    try self.flushCache();
                    try self.invalidateCache();
                },
                .none => {},
            }
        }
    }
    
    fn flushCache(self: *Self) DriverError!void {
        // Platform-specific cache flush implementation
        // For x86_64, this might use clflush or wbinvd
        _ = self;
        // TODO: Implement cache operations
    }
    
    fn invalidateCache(self: *Self) DriverError!void {
        // Platform-specific cache invalidation
        _ = self;
        // TODO: Implement cache operations
    }
};

/// Device file handle
pub const DeviceFile = struct {
    device: *Device,
    flags: u32,
    private_data: ?*anyopaque = null,
    ref_count: std.atomic.Value(u32),
    
    const Self = @This();
    
    pub fn init(device: *Device, flags: u32) Self {
        return Self{
            .device = device,
            .flags = flags,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            if (self.device.ops.close) |close_fn| {
                close_fn(self) catch {};
            }
        }
    }
};

/// Device structure
pub const Device = struct {
    name: []const u8,
    device_type: DeviceType,
    device_id: u32,
    vendor_id: u32 = 0,
    parent: ?*Device = null,
    children: std.ArrayList(*Device),
    driver: ?*Driver = null,
    ops: *const DeviceOps,
    capabilities: DeviceCapabilities,
    power_state: PowerState,
    private_data: ?*anyopaque = null,
    ref_count: std.atomic.Value(u32),
    
    // Gaming optimization state
    gaming_mode_enabled: bool = false,
    low_latency_enabled: bool = false,
    wayland_mode_enabled: bool = false,
    
    // Performance tracking
    performance_metrics: PerformanceMetrics,
    last_metrics_update: u64,
    
    // Resource management
    io_ports: ?[]IOPort = null,
    memory_regions: ?[]MemoryRegion = null,
    irq_numbers: ?[]u32 = null,
    dma_mappings: std.ArrayList(DMAMapping),
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, device_type: DeviceType, ops: *const DeviceOps) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .device_type = device_type,
            .device_id = 0,
            .children = std.ArrayList(*Device).init(allocator),
            .ops = ops,
            .capabilities = DeviceCapabilities{},
            .power_state = .on,
            .ref_count = std.atomic.Value(u32).init(1),
            .performance_metrics = std.mem.zeroes(PerformanceMetrics),
            .last_metrics_update = 0,
            .dma_mappings = std.ArrayList(DMAMapping).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.children.deinit();
        self.dma_mappings.deinit();
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            self.deinit();
        }
    }
    
    pub fn addChild(self: *Self, child: *Device) !void {
        child.parent = self;
        try self.children.append(child.get());
    }
    
    pub fn removeChild(self: *Self, child: *Device) void {
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.swapRemove(i);
                c.parent = null;
                c.put();
                break;
            }
        }
    }
    
    pub fn open(self: *Self, flags: u32) DriverError!*DeviceFile {
        if (self.ops.open) |open_fn| {
            return open_fn(self, flags);
        }
        
        // Default implementation
        const file = try self.allocator.create(DeviceFile);
        file.* = DeviceFile.init(self, flags);
        return file;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) DriverError!void {
        if (self.ops.set_gaming_mode) |gaming_fn| {
            try gaming_fn(self, enabled);
        }
        self.gaming_mode_enabled = enabled;
        
        // Update performance metrics
        self.updatePerformanceMetrics();
    }
    
    pub fn setLowLatency(self: *Self, enabled: bool) DriverError!void {
        if (self.ops.set_low_latency) |latency_fn| {
            try latency_fn(self, enabled);
        }
        self.low_latency_enabled = enabled;
    }
    
    pub fn enableWaylandMode(self: *Self) DriverError!void {
        if (self.ops.enable_wayland_mode) |wayland_fn| {
            try wayland_fn(self);
        }
        self.wayland_mode_enabled = true;
    }
    
    pub fn submitWaylandBuffer(self: *Self, buffer: *WaylandBuffer) DriverError!void {
        if (self.ops.submit_wayland_buffer) |buffer_fn| {
            return buffer_fn(self, buffer);
        }
        return DriverError.OperationNotSupported;
    }
    
    pub fn setCompositorHints(self: *Self, hints: *CompositorHints) DriverError!void {
        if (self.ops.set_compositor_hints) |hints_fn| {
            return hints_fn(self, hints);
        }
        return DriverError.OperationNotSupported;
    }
    
    pub fn allocDMA(self: *Self, size: usize, direction: DMADirection, coherent: bool) DriverError!DMAMapping {
        // Allocate DMA-capable memory
        const phys_addr = memory.allocDMAMemory(size, coherent) orelse return DriverError.InsufficientMemory;
        
        // Map to virtual address space
        const virt_addr = try paging.mapPhysical(phys_addr, size, paging.PAGE_PRESENT | paging.PAGE_WRITABLE);
        
        const mapping = DMAMapping{
            .virtual_addr = virt_addr,
            .physical_addr = phys_addr,
            .size = size,
            .direction = direction,
            .coherent = coherent,
        };
        
        try self.dma_mappings.append(mapping);
        return mapping;
    }
    
    pub fn freeDMA(self: *Self, mapping: DMAMapping) void {
        // Unmap virtual address
        paging.unmapPages(mapping.virtual_addr, mapping.size);
        
        // Free physical memory
        memory.freeDMAMemory(mapping.physical_addr, mapping.size);
        
        // Remove from mappings list
        for (self.dma_mappings.items, 0..) |m, i| {
            if (m.physical_addr == mapping.physical_addr) {
                _ = self.dma_mappings.swapRemove(i);
                break;
            }
        }
    }
    
    pub fn updatePerformanceMetrics(self: *Self) void {
        const now = std.time.nanoTimestamp();
        self.last_metrics_update = @intCast(now);
        
        if (self.ops.get_performance_metrics) |metrics_fn| {
            metrics_fn(self, &self.performance_metrics) catch {};
        }
        
        // Update gaming/wayland mode status
        self.performance_metrics.gaming_mode_active = self.gaming_mode_enabled;
        self.performance_metrics.wayland_mode_active = self.wayland_mode_enabled;
    }
    
    pub fn setPowerState(self: *Self, state: PowerState) DriverError!void {
        switch (state) {
            .suspended => {
                if (self.ops.device_suspend) |suspend_fn| {
                    try suspend_fn(self, state);
                }
            },
            .on => {
                if (self.ops.device_resume) |resume_fn| {
                    try resume_fn(self);
                }
            },
            else => {},
        }
        self.power_state = state;
    }
};

/// Device driver
pub const Driver = struct {
    name: []const u8,
    device_type: DeviceType,
    probe: *const fn (device: *Device) DriverError!void,
    remove: *const fn (device: *Device) void,
    devices: std.ArrayList(*Device),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, device_type: DeviceType) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .device_type = device_type,
            .probe = undefined,
            .remove = undefined,
            .devices = std.ArrayList(*Device).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        
        // Remove all devices
        for (self.devices.items) |device| {
            self.remove(device);
        }
        self.devices.deinit();
    }
    
    pub fn bindDevice(self: *Self, device: *Device) DriverError!void {
        try self.probe(device);
        device.driver = self;
        try self.devices.append(device.get());
    }
    
    pub fn unbindDevice(self: *Self, device: *Device) void {
        for (self.devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.devices.swapRemove(i);
                self.remove(device);
                device.driver = null;
                device.put();
                break;
            }
        }
    }
};

/// I/O port region
pub const IOPort = struct {
    start: u16,
    end: u16,
    name: []const u8,
    
    pub fn size(self: IOPort) u16 {
        return self.end - self.start + 1;
    }
    
    pub fn readByte(self: IOPort, offset: u16) u8 {
        if (offset >= self.size()) @panic("I/O port offset out of bounds");
        return asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "N{dx}" (self.start + offset),
        );
    }
    
    pub fn writeByte(self: IOPort, offset: u16, value: u8) void {
        if (offset >= self.size()) @panic("I/O port offset out of bounds");
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (self.start + offset),
        );
    }
    
    pub fn readWord(self: IOPort, offset: u16) u16 {
        if (offset + 1 >= self.size()) @panic("I/O port offset out of bounds");
        return asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> u16),
            : [port] "N{dx}" (self.start + offset),
        );
    }
    
    pub fn writeWord(self: IOPort, offset: u16, value: u16) void {
        if (offset + 1 >= self.size()) @panic("I/O port offset out of bounds");
        asm volatile ("outw %[value], %[port]"
            :
            : [value] "{ax}" (value),
              [port] "N{dx}" (self.start + offset),
        );
    }
    
    pub fn readDword(self: IOPort, offset: u16) u32 {
        if (offset + 3 >= self.size()) @panic("I/O port offset out of bounds");
        return asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> u32),
            : [port] "N{dx}" (self.start + offset),
        );
    }
    
    pub fn writeDword(self: IOPort, offset: u16, value: u32) void {
        if (offset + 3 >= self.size()) @panic("I/O port offset out of bounds");
        asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "N{dx}" (self.start + offset),
        );
    }
};

/// Memory region
pub const MemoryRegion = struct {
    physical_start: usize,
    virtual_start: usize,
    size: usize,
    cacheable: bool = true,
    
    pub fn readByte(self: MemoryRegion, offset: usize) u8 {
        if (offset >= self.size) @panic("Memory region offset out of bounds");
        return @as(*volatile u8, @ptrFromInt(self.virtual_start + offset)).*;
    }
    
    pub fn writeByte(self: MemoryRegion, offset: usize, value: u8) void {
        if (offset >= self.size) @panic("Memory region offset out of bounds");
        @as(*volatile u8, @ptrFromInt(self.virtual_start + offset)).* = value;
    }
    
    pub fn readWord(self: MemoryRegion, offset: usize) u16 {
        if (offset + 1 >= self.size) @panic("Memory region offset out of bounds");
        return @as(*volatile u16, @ptrFromInt(self.virtual_start + offset)).*;
    }
    
    pub fn writeWord(self: MemoryRegion, offset: usize, value: u16) void {
        if (offset + 1 >= self.size) @panic("Memory region offset out of bounds");
        @as(*volatile u16, @ptrFromInt(self.virtual_start + offset)).* = value;
    }
    
    pub fn readDword(self: MemoryRegion, offset: usize) u32 {
        if (offset + 3 >= self.size) @panic("Memory region offset out of bounds");
        return @as(*volatile u32, @ptrFromInt(self.virtual_start + offset)).*;
    }
    
    pub fn writeDword(self: MemoryRegion, offset: usize, value: u32) void {
        if (offset + 3 >= self.size) @panic("Memory region offset out of bounds");
        @as(*volatile u32, @ptrFromInt(self.virtual_start + offset)).* = value;
    }
    
    pub fn readQword(self: MemoryRegion, offset: usize) u64 {
        if (offset + 7 >= self.size) @panic("Memory region offset out of bounds");
        return @as(*volatile u64, @ptrFromInt(self.virtual_start + offset)).*;
    }
    
    pub fn writeQword(self: MemoryRegion, offset: usize, value: u64) void {
        if (offset + 7 >= self.size) @panic("Memory region offset out of bounds");
        @as(*volatile u64, @ptrFromInt(self.virtual_start + offset)).* = value;
    }
};

/// Device manager
pub const DeviceManager = struct {
    devices: std.ArrayList(*Device),
    drivers: std.ArrayList(*Driver),
    gaming_devices: std.ArrayList(*Device),
    wayland_devices: std.ArrayList(*Device),
    allocator: std.mem.Allocator,
    device_lock: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .devices = std.ArrayList(*Device).init(allocator),
            .drivers = std.ArrayList(*Driver).init(allocator),
            .gaming_devices = std.ArrayList(*Device).init(allocator),
            .wayland_devices = std.ArrayList(*Device).init(allocator),
            .allocator = allocator,
            .device_lock = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        // Clean up devices
        for (self.devices.items) |device| {
            device.put();
        }
        self.devices.deinit();
        
        // Clean up drivers
        for (self.drivers.items) |driver| {
            driver.deinit();
            self.allocator.destroy(driver);
        }
        self.drivers.deinit();
        
        self.gaming_devices.deinit();
        self.wayland_devices.deinit();
    }
    
    pub fn registerDevice(self: *Self, device: *Device) !void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        try self.devices.append(device.get());
        
        // Auto-bind to compatible driver
        for (self.drivers.items) |driver| {
            if (driver.device_type == device.device_type) {
                driver.bindDevice(device) catch continue;
                break;
            }
        }
    }
    
    pub fn unregisterDevice(self: *Self, device: *Device) void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        // Remove from gaming devices if present
        for (self.gaming_devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.gaming_devices.swapRemove(i);
                break;
            }
        }
        
        // Remove from wayland devices if present
        for (self.wayland_devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.wayland_devices.swapRemove(i);
                break;
            }
        }
        
        // Unbind from driver
        if (device.driver) |driver| {
            driver.unbindDevice(device);
        }
        
        // Remove from device list
        for (self.devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.devices.swapRemove(i);
                d.put();
                break;
            }
        }
    }
    
    pub fn registerDriver(self: *Self, driver: *Driver) !void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        try self.drivers.append(driver);
        
        // Bind to compatible devices
        for (self.devices.items) |device| {
            if (device.device_type == driver.device_type and device.driver == null) {
                driver.bindDevice(device) catch continue;
            }
        }
    }
    
    pub fn enableGamingMode(self: *Self) !void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        // Enable gaming mode on all supported devices
        for (self.devices.items) |device| {
            if (device.capabilities.gaming_optimized) {
                device.setGamingMode(true) catch continue;
                try self.gaming_devices.append(device);
            }
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        // Disable gaming mode on all devices
        for (self.gaming_devices.items) |device| {
            device.setGamingMode(false) catch {};
        }
        self.gaming_devices.clearRetainingCapacity();
    }
    
    pub fn enableWaylandOptimizations(self: *Self) !void {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        // Enable Wayland optimizations on supported devices
        for (self.devices.items) |device| {
            if (device.capabilities.wayland_optimized) {
                device.enableWaylandMode() catch continue;
                try self.wayland_devices.append(device);
            }
        }
    }
    
    pub fn findDeviceByType(self: *Self, device_type: DeviceType) ?*Device {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        for (self.devices.items) |device| {
            if (device.device_type == device_type) {
                return device.get();
            }
        }
        return null;
    }
    
    pub fn getPerformanceReport(self: *Self) PerformanceReport {
        self.device_lock.lock();
        defer self.device_lock.unlock();
        
        var report = PerformanceReport{
            .total_devices = @intCast(self.devices.items.len),
            .gaming_devices = @intCast(self.gaming_devices.items.len),
            .wayland_devices = @intCast(self.wayland_devices.items.len),
            .avg_latency_ns = 0,
            .total_throughput_mbps = 0,
            .total_errors = 0,
        };
        
        var total_latency: u64 = 0;
        for (self.devices.items) |device| {
            device.updatePerformanceMetrics();
            total_latency += device.performance_metrics.avg_latency_ns;
            report.total_throughput_mbps += device.performance_metrics.throughput_mbps;
            report.total_errors += device.performance_metrics.error_count;
        }
        
        if (self.devices.items.len > 0) {
            report.avg_latency_ns = total_latency / self.devices.items.len;
        }
        
        return report;
    }
};

/// Performance report
pub const PerformanceReport = struct {
    total_devices: u32,
    gaming_devices: u32,
    wayland_devices: u32,
    avg_latency_ns: u64,
    total_throughput_mbps: u32,
    total_errors: u32,
};

// Global device manager
var global_device_manager: ?*DeviceManager = null;

/// Initialize the device driver framework
pub fn initDriverFramework(allocator: std.mem.Allocator) !void {
    const dm = try allocator.create(DeviceManager);
    dm.* = DeviceManager.init(allocator);
    global_device_manager = dm;
}

/// Get the global device manager
pub fn getDeviceManager() *DeviceManager {
    return global_device_manager orelse @panic("Driver framework not initialized");
}

// Tests
test "device creation and reference counting" {
    const allocator = std.testing.allocator;
    const ops = DeviceOps{};
    
    var device = try Device.init(allocator, "test_device", .character, &ops);
    defer device.deinit();
    
    try std.testing.expect(device.ref_count.load(.acquire) == 1);
    
    const device2 = device.get();
    try std.testing.expect(device.ref_count.load(.acquire) == 2);
    try std.testing.expect(device2 == &device);
    
    device2.put();
    try std.testing.expect(device.ref_count.load(.acquire) == 1);
}

test "gaming mode functionality" {
    const allocator = std.testing.allocator;
    const ops = DeviceOps{};
    
    var device = try Device.init(allocator, "gaming_device", .gpu, &ops);
    defer device.deinit();
    
    device.capabilities.gaming_optimized = true;
    
    try device.setGamingMode(true);
    try std.testing.expect(device.gaming_mode_enabled);
    
    try device.setGamingMode(false);
    try std.testing.expect(!device.gaming_mode_enabled);
}

test "device manager registration" {
    const allocator = std.testing.allocator;
    
    var dm = DeviceManager.init(allocator);
    defer dm.deinit();
    
    const ops = DeviceOps{};
    var device = try Device.init(allocator, "test_device", .input, &ops);
    
    try dm.registerDevice(&device);
    try std.testing.expect(dm.devices.items.len == 1);
    
    dm.unregisterDevice(&device);
    try std.testing.expect(dm.devices.items.len == 0);
}

test "wayland optimization" {
    const allocator = std.testing.allocator;
    const ops = DeviceOps{};
    
    var device = try Device.init(allocator, "wayland_device", .display, &ops);
    defer device.deinit();
    
    device.capabilities.wayland_optimized = true;
    
    try device.enableWaylandMode();
    try std.testing.expect(device.wayland_mode_enabled);
}