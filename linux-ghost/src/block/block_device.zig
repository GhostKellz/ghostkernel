//! Block Device Interface for Ghost Kernel
//! Generic block device layer for storage devices
//! Supports NVMe, SATA, SCSI, and USB mass storage devices

const std = @import("std");
const sync = @import("../kernel/sync.zig");
const memory = @import("../mm/memory.zig");
const device = @import("../drivers/driver_framework.zig");

/// Block device request types
pub const RequestType = enum(u8) {
    read = 0,
    write = 1,
    flush = 2,
    discard = 3,
    write_same = 4,
    write_zeros = 5,
    secure_erase = 6,
};

/// Block device request flags
pub const RequestFlags = packed struct {
    sync: bool = false,
    meta: bool = false,
    preflush: bool = false,
    fua: bool = false,
    nounmap: bool = false,
    idle: bool = false,
    integrity: bool = false,
    _reserved: u25 = 0,
};

/// Block device request structure
pub const BlockRequest = struct {
    type: RequestType,
    flags: RequestFlags,
    sector: u64,
    nr_sectors: u32,
    buffer: []u8,
    private_data: ?*anyopaque = null,
    completion: ?*const fn(*BlockRequest, error_code: u32) void = null,
    
    // Request tracking
    submitted_time: u64 = 0,
    completion_time: u64 = 0,
    
    // For queue management
    next: ?*BlockRequest = null,
    queue_tag: u32 = 0,
};

/// Block device queue structure
pub const BlockQueue = struct {
    requests: std.ArrayList(*BlockRequest),
    active_requests: std.ArrayList(*BlockRequest),
    queue_depth: u32,
    nr_requests: u32,
    
    // Queue statistics
    read_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    mutex: sync.Mutex,
    not_empty: sync.Condition,
    not_full: sync.Condition,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, queue_depth: u32) !Self {
        return Self{
            .requests = std.ArrayList(*BlockRequest).init(allocator),
            .active_requests = std.ArrayList(*BlockRequest).init(allocator),
            .queue_depth = queue_depth,
            .nr_requests = 0,
            .mutex = sync.Mutex.init(),
            .not_empty = sync.Condition.init(),
            .not_full = sync.Condition.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.requests.deinit();
        self.active_requests.deinit();
    }
    
    pub fn submit(self: *Self, request: *BlockRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Wait for queue space
        while (self.nr_requests >= self.queue_depth) {
            self.not_full.wait(&self.mutex);
        }
        
        request.submitted_time = std.time.nanoTimestamp();
        request.queue_tag = self.nr_requests;
        
        try self.requests.append(request);
        self.nr_requests += 1;
        
        // Update statistics
        switch (request.type) {
            .read => {
                _ = self.read_requests.fetchAdd(1, .monotonic);
                _ = self.read_bytes.fetchAdd(request.nr_sectors * 512, .monotonic);
            },
            .write => {
                _ = self.write_requests.fetchAdd(1, .monotonic);
                _ = self.write_bytes.fetchAdd(request.nr_sectors * 512, .monotonic);
            },
            else => {},
        }
        
        self.not_empty.signal();
    }
    
    pub fn pop(self: *Self) ?*BlockRequest {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.requests.items.len == 0) {
            return null;
        }
        
        const request = self.requests.orderedRemove(0);
        self.nr_requests -= 1;
        
        try self.active_requests.append(request);
        self.not_full.signal();
        
        return request;
    }
    
    pub fn complete(self: *Self, request: *BlockRequest, error_code: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        request.completion_time = std.time.nanoTimestamp();
        
        // Remove from active requests
        for (self.active_requests.items, 0..) |req, i| {
            if (req == request) {
                _ = self.active_requests.orderedRemove(i);
                break;
            }
        }
        
        // Call completion callback
        if (request.completion) |completion_fn| {
            completion_fn(request, error_code);
        }
    }
    
    pub fn flush(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Wait for all active requests to complete
        while (self.active_requests.items.len > 0) {
            // In a real implementation, this would use a condition variable
            // For now, just yield
            std.time.sleep(1000000); // 1ms
        }
    }
};

/// Block device operations
pub const BlockDeviceOps = struct {
    submit_bio: *const fn(*BlockDevice, *BlockRequest) error{OutOfMemory, DeviceError, InvalidRequest}!void,
    flush: *const fn(*BlockDevice) error{DeviceError}!void,
    poll: ?*const fn(*BlockDevice) void = null,
    open: ?*const fn(*BlockDevice) error{DeviceError}!void = null,
    close: ?*const fn(*BlockDevice) void = null,
    get_geometry: ?*const fn(*BlockDevice, *DiskGeometry) error{DeviceError}!void = null,
    ioctl: ?*const fn(*BlockDevice, u32, usize) error{DeviceError, InvalidRequest}!usize = null,
};

/// Disk geometry information
pub const DiskGeometry = struct {
    cylinders: u32,
    heads: u32,
    sectors: u32,
    start: u64,
};

/// Block device capabilities
pub const BlockDeviceCapabilities = packed struct {
    removable: bool = false,
    read_only: bool = false,
    writeback: bool = false,
    fua: bool = false,
    flush: bool = false,
    discard: bool = false,
    write_same: bool = false,
    write_zeros: bool = false,
    secure_erase: bool = false,
    rotational: bool = false,
    _reserved: u22 = 0,
};

/// Block device performance characteristics
pub const BlockDevicePerformance = struct {
    // Latency characteristics (in nanoseconds)
    read_latency_avg: u64 = 0,
    write_latency_avg: u64 = 0,
    read_latency_max: u64 = 0,
    write_latency_max: u64 = 0,
    
    // Throughput characteristics (in bytes/sec)
    read_throughput: u64 = 0,
    write_throughput: u64 = 0,
    
    // Queue depth characteristics
    optimal_queue_depth: u32 = 32,
    max_queue_depth: u32 = 256,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    predictive_caching: bool = false,
    zero_copy_enabled: bool = false,
};

/// Block device structure
pub const BlockDevice = struct {
    name: []const u8,
    major: u32,
    minor: u32,
    
    // Device properties
    sector_size: u32 = 512,
    nr_sectors: u64,
    capabilities: BlockDeviceCapabilities,
    performance: BlockDevicePerformance,
    
    // Request queue
    queue: BlockQueue,
    
    // Operations
    ops: BlockDeviceOps,
    
    // Private driver data
    private_data: ?*anyopaque = null,
    
    // Device statistics
    stats: BlockDeviceStats,
    
    // Gaming optimizations
    gaming_config: GamingConfig,
    
    // Reference counting
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    // Synchronization
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, major: u32, minor: u32, nr_sectors: u64, ops: BlockDeviceOps) !*Self {
        var device = try allocator.create(Self);
        device.* = Self{
            .name = try allocator.dupe(u8, name),
            .major = major,
            .minor = minor,
            .nr_sectors = nr_sectors,
            .capabilities = BlockDeviceCapabilities{},
            .performance = BlockDevicePerformance{},
            .queue = try BlockQueue.init(allocator, 256),
            .ops = ops,
            .stats = BlockDeviceStats{},
            .gaming_config = GamingConfig{},
            .mutex = sync.Mutex.init(),
        };
        
        return device;
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.queue.deinit();
        allocator.destroy(self);
    }
    
    pub fn submitBio(self: *Self, request: *BlockRequest) !void {
        // Validate request
        if (request.sector + request.nr_sectors > self.nr_sectors) {
            return error.InvalidRequest;
        }
        
        // Gaming mode optimizations
        if (self.gaming_config.enabled) {
            self.applyGamingOptimizations(request);
        }
        
        // Submit to queue
        try self.queue.submit(request);
        
        // Submit to device
        try self.ops.submit_bio(self, request);
        
        // Update statistics
        self.stats.total_requests.fetchAdd(1, .monotonic);
        self.stats.total_sectors.fetchAdd(request.nr_sectors, .monotonic);
    }
    
    pub fn flush(self: *Self) !void {
        if (self.ops.flush) |flush_fn| {
            try flush_fn(self);
        }
        self.queue.flush();
    }
    
    pub fn getCapacity(self: *Self) u64 {
        return self.nr_sectors * self.sector_size;
    }
    
    pub fn getGeometry(self: *Self) !DiskGeometry {
        if (self.ops.get_geometry) |get_geometry_fn| {
            var geometry: DiskGeometry = undefined;
            try get_geometry_fn(self, &geometry);
            return geometry;
        }
        
        // Default geometry calculation
        const total_sectors = self.nr_sectors;
        const heads = 255;
        const sectors_per_track = 63;
        const cylinders = @intCast(u32, total_sectors / (heads * sectors_per_track));
        
        return DiskGeometry{
            .cylinders = cylinders,
            .heads = heads,
            .sectors = sectors_per_track,
            .start = 0,
        };
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_config.enabled = true;
        self.gaming_config.high_priority = true;
        self.gaming_config.predictive_caching = true;
        self.gaming_config.zero_copy = true;
        
        // Adjust queue depth for gaming
        self.performance.optimal_queue_depth = 64;
        self.performance.gaming_mode = true;
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_config.enabled = false;
        self.gaming_config.high_priority = false;
        self.gaming_config.predictive_caching = false;
        self.gaming_config.zero_copy = false;
        
        // Reset to default queue depth
        self.performance.optimal_queue_depth = 32;
        self.performance.gaming_mode = false;
    }
    
    fn applyGamingOptimizations(self: *Self, request: *BlockRequest) void {
        // High priority for gaming requests
        if (self.gaming_config.high_priority) {
            request.flags.sync = true;
        }
        
        // Predictive caching
        if (self.gaming_config.predictive_caching) {
            // TODO: Implement predictive caching logic
        }
        
        // Zero-copy optimizations
        if (self.gaming_config.zero_copy) {
            // TODO: Implement zero-copy buffer handling
        }
    }
    
    pub fn getStats(self: *Self) BlockDeviceStats {
        return self.stats;
    }
    
    pub fn resetStats(self: *Self) void {
        self.stats = BlockDeviceStats{};
    }
};

/// Block device statistics
pub const BlockDeviceStats = struct {
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_sectors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_sectors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_sectors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    io_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    time_in_queue: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    pub fn getReadThroughput(self: *const BlockDeviceStats) u64 {
        const read_sectors = self.read_sectors.load(.monotonic);
        const read_time = self.read_time.load(.monotonic);
        if (read_time == 0) return 0;
        return (read_sectors * 512 * 1000000000) / read_time;
    }
    
    pub fn getWriteThroughput(self: *const BlockDeviceStats) u64 {
        const write_sectors = self.write_sectors.load(.monotonic);
        const write_time = self.write_time.load(.monotonic);
        if (write_time == 0) return 0;
        return (write_sectors * 512 * 1000000000) / write_time;
    }
    
    pub fn getAverageLatency(self: *const BlockDeviceStats) u64 {
        const total_requests = self.total_requests.load(.monotonic);
        const io_time = self.io_time.load(.monotonic);
        if (total_requests == 0) return 0;
        return io_time / total_requests;
    }
};

/// Gaming configuration for block devices
pub const GamingConfig = struct {
    enabled: bool = false,
    high_priority: bool = false,
    predictive_caching: bool = false,
    zero_copy: bool = false,
    prefetch_aggressive: bool = false,
    write_through: bool = false,
    
    // Gaming-specific thresholds
    max_latency_ns: u64 = 1000000, // 1ms
    preferred_queue_depth: u32 = 64,
    burst_size: u32 = 1024 * 1024, // 1MB
};

/// Block device registry
pub const BlockDeviceRegistry = struct {
    devices: std.ArrayList(*BlockDevice),
    mutex: sync.Mutex,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .devices = std.ArrayList(*BlockDevice).init(allocator),
            .mutex = sync.Mutex.init(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.devices.deinit();
    }
    
    pub fn register(self: *Self, device: *BlockDevice) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.devices.append(device);
    }
    
    pub fn unregister(self: *Self, device: *BlockDevice) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.devices.items, 0..) |dev, i| {
            if (dev == device) {
                _ = self.devices.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn findDevice(self: *Self, major: u32, minor: u32) ?*BlockDevice {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.devices.items) |device| {
            if (device.major == major and device.minor == minor) {
                return device;
            }
        }
        
        return null;
    }
    
    pub fn listDevices(self: *Self) []const *BlockDevice {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.devices.items;
    }
};

/// Global block device registry
var block_registry: ?BlockDeviceRegistry = null;

/// Initialize the block device subsystem
pub fn init(allocator: std.mem.Allocator) !void {
    block_registry = BlockDeviceRegistry.init(allocator);
}

/// Get the global block device registry
pub fn getRegistry() *BlockDeviceRegistry {
    return &(block_registry orelse @panic("Block device subsystem not initialized"));
}

/// Register a block device
pub fn registerDevice(device: *BlockDevice) !void {
    try getRegistry().register(device);
}

/// Unregister a block device
pub fn unregisterDevice(device: *BlockDevice) void {
    getRegistry().unregister(device);
}

/// Find a block device by major/minor number
pub fn findDevice(major: u32, minor: u32) ?*BlockDevice {
    return getRegistry().findDevice(major, minor);
}

/// Helper function to create a block request
pub fn createRequest(allocator: std.mem.Allocator, request_type: RequestType, sector: u64, nr_sectors: u32, buffer: []u8) !*BlockRequest {
    var request = try allocator.create(BlockRequest);
    request.* = BlockRequest{
        .type = request_type,
        .flags = RequestFlags{},
        .sector = sector,
        .nr_sectors = nr_sectors,
        .buffer = buffer,
    };
    return request;
}

/// Helper function to destroy a block request
pub fn destroyRequest(allocator: std.mem.Allocator, request: *BlockRequest) void {
    allocator.destroy(request);
}

/// Block device major numbers
pub const MAJOR_SCSI_DISK = 8;
pub const MAJOR_SCSI_CDROM = 11;
pub const MAJOR_USB_STORAGE = 180;
pub const MAJOR_NVME = 259;

/// Common sector size
pub const SECTOR_SIZE = 512;

/// Maximum transfer size
pub const MAX_TRANSFER_SIZE = 32 * 1024 * 1024; // 32MB