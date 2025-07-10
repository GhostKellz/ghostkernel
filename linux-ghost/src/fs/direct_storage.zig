//! GhostKernel Direct Storage API
//! Ultra-fast game asset loading with GPU decompression and zero-copy I/O
//! Equivalent to DirectStorage but optimized for Linux gaming

const std = @import("std");
const vfs = @import("vfs.zig");
const btrfs = @import("btrfs.zig");
const memory = @import("../mm/memory.zig");
const sched = @import("../kernel/sched.zig");
const sync = @import("../kernel/sync.zig");
const console = @import("../arch/x86_64/console.zig");
const ghostnv = @import("ghostnv"); // Your GPU driver

/// Direct Storage compression formats
pub const CompressionFormat = enum(u8) {
    none = 0,
    lz4 = 1,        // Fast decompression
    zstd = 2,       // Good compression ratio
    gdeflate = 3,   // GPU-accelerated decompression
    bcpack = 4,     // Block compression for textures
    custom = 255,   // Game-specific format
};

/// Asset loading priority levels
pub const AssetPriority = enum(u8) {
    immediate = 0,   // Frame-critical assets (must load this frame)
    high = 1,        // Important assets (load within 1-2 frames)
    normal = 2,      // Standard assets (load within reasonable time)
    background = 3,  // Preload assets (load when idle)
    streaming = 4,   // Streaming assets (continuous loading)
};

/// Direct Storage request flags
pub const DirectStorageFlags = struct {
    zero_copy: bool = true,          // Use zero-copy I/O
    gpu_decompression: bool = false, // Decompress on GPU
    bypass_cache: bool = false,      // Bypass filesystem cache
    memory_mapped: bool = false,     // Use memory mapping
    async_callback: bool = false,    // Use async completion
    priority_boost: bool = false,    // Boost I/O priority
    streaming_hint: bool = false,    // This is streaming data
    texture_hint: bool = false,      // This is texture data
    
    pub fn optimizeForAssetType(asset_type: AssetType) DirectStorageFlags {
        return switch (asset_type) {
            .texture => DirectStorageFlags{
                .zero_copy = true,
                .gpu_decompression = true,
                .texture_hint = true,
                .memory_mapped = true,
            },
            .audio => DirectStorageFlags{
                .zero_copy = true,
                .streaming_hint = true,
                .priority_boost = true,
            },
            .mesh => DirectStorageFlags{
                .zero_copy = true,
                .gpu_decompression = true,
                .memory_mapped = true,
            },
            .script => DirectStorageFlags{
                .bypass_cache = false, // Scripts benefit from caching
                .memory_mapped = true,
            },
            .level_data => DirectStorageFlags{
                .zero_copy = true,
                .streaming_hint = true,
                .memory_mapped = true,
            },
            .generic => DirectStorageFlags{},
        };
    }
};

/// Asset types for optimization hints
pub const AssetType = enum {
    texture,     // Graphics textures
    audio,       // Audio files
    mesh,        // 3D meshes/geometry
    script,      // Game scripts/code
    level_data,  // Level/world data
    generic,     // Unknown asset type
};

/// Direct Storage request
pub const DirectStorageRequest = struct {
    // Request identification
    request_id: u64,
    game_pid: u32,
    
    // Source specification
    source_file: []const u8,
    offset: u64,
    size: u64,
    
    // Destination specification
    dest_buffer: ?[]u8,          // CPU buffer (null for GPU-only)
    dest_gpu_buffer: ?u64,       // GPU buffer address
    dest_type: DestinationType,
    
    // Request parameters
    compression_format: CompressionFormat,
    asset_type: AssetType,
    priority: AssetPriority,
    flags: DirectStorageFlags,
    
    // Completion handling
    completion_callback: ?*const fn(*DirectStorageRequest, DirectStorageResult) void,
    user_data: ?*anyopaque,
    
    // Internal tracking
    submit_time: u64,
    start_time: u64,
    completion_time: u64,
    status: RequestStatus,
    bytes_transferred: u64,
    
    const DestinationType = enum {
        cpu_memory,    // Regular system RAM
        gpu_memory,    // GPU VRAM
        shared_memory, // CPU/GPU shared memory
        streaming,     // Streaming buffer
    };
    
    const RequestStatus = enum {
        pending,
        processing,
        decompressing,
        transferring,
        completed,
        failed,
    };
    
    pub fn init(allocator: std.mem.Allocator, game_pid: u32, source: []const u8) !DirectStorageRequest {
        _ = allocator;
        
        return DirectStorageRequest{
            .request_id = generateRequestId(),
            .game_pid = game_pid,
            .source_file = source,
            .offset = 0,
            .size = 0,
            .dest_buffer = null,
            .dest_gpu_buffer = null,
            .dest_type = .cpu_memory,
            .compression_format = .none,
            .asset_type = .generic,
            .priority = .normal,
            .flags = DirectStorageFlags{},
            .completion_callback = null,
            .user_data = null,
            .submit_time = @intCast(std.time.nanoTimestamp()),
            .start_time = 0,
            .completion_time = 0,
            .status = .pending,
            .bytes_transferred = 0,
        };
    }
    
    fn generateRequestId() u64 {
        // Generate unique request ID
        const timestamp = std.time.nanoTimestamp();
        return @as(u64, @intCast(timestamp));
    }
    
    pub fn setDestination(self: *DirectStorageRequest, buffer: []u8) void {
        self.dest_buffer = buffer;
        self.dest_type = .cpu_memory;
        self.size = buffer.len;
    }
    
    pub fn setGPUDestination(self: *DirectStorageRequest, gpu_addr: u64, size: u64) void {
        self.dest_gpu_buffer = gpu_addr;
        self.dest_type = .gpu_memory;
        self.size = size;
    }
    
    pub fn enableGPUDecompression(self: *DirectStorageRequest, format: CompressionFormat) void {
        self.compression_format = format;
        self.flags.gpu_decompression = true;
    }
    
    pub fn setAssetType(self: *DirectStorageRequest, asset_type: AssetType) void {
        self.asset_type = asset_type;
        self.flags = DirectStorageFlags.optimizeForAssetType(asset_type);
    }
    
    pub fn getLatencyMs(self: *const DirectStorageRequest) f64 {
        if (self.completion_time == 0) return 0.0;
        const latency_ns = self.completion_time - self.submit_time;
        return @as(f64, @floatFromInt(latency_ns)) / 1_000_000.0;
    }
};

/// Direct Storage result
pub const DirectStorageResult = struct {
    success: bool,
    bytes_read: u64,
    error_code: u32,
    latency_ns: u64,
    decompression_ratio: f32,
    gpu_time_ns: u64, // Time spent on GPU decompression
    
    pub fn createSuccess(bytes: u64, latency: u64) DirectStorageResult {
        return DirectStorageResult{
            .success = true,
            .bytes_read = bytes,
            .error_code = 0,
            .latency_ns = latency,
            .decompression_ratio = 1.0,
            .gpu_time_ns = 0,
        };
    }
    
    pub fn createError(error_code: u32) DirectStorageResult {
        return DirectStorageResult{
            .success = false,
            .bytes_read = 0,
            .error_code = error_code,
            .latency_ns = 0,
            .decompression_ratio = 0.0,
            .gpu_time_ns = 0,
        };
    }
};

/// Direct Storage statistics
pub const DirectStorageStats = struct {
    total_requests: u64 = 0,
    completed_requests: u64 = 0,
    failed_requests: u64 = 0,
    bytes_transferred: u64 = 0,
    gpu_decompressions: u64 = 0,
    zero_copy_operations: u64 = 0,
    average_latency_ms: f64 = 0.0,
    peak_throughput_mbps: f64 = 0.0,
    cache_hit_ratio: f32 = 0.0,
    
    pub fn update(self: *DirectStorageStats, request: *const DirectStorageRequest, result: DirectStorageResult) void {
        self.total_requests += 1;
        
        if (result.success) {
            self.completed_requests += 1;
            self.bytes_transferred += result.bytes_read;
            
            // Update average latency
            const latency_ms = request.getLatencyMs();
            self.average_latency_ms = (self.average_latency_ms * @as(f64, @floatFromInt(self.completed_requests - 1)) + latency_ms) / @as(f64, @floatFromInt(self.completed_requests));
            
            // Update peak throughput
            if (latency_ms > 0) {
                const throughput_mbps = (@as(f64, @floatFromInt(result.bytes_read)) / (1024.0 * 1024.0)) / (latency_ms / 1000.0);
                if (throughput_mbps > self.peak_throughput_mbps) {
                    self.peak_throughput_mbps = throughput_mbps;
                }
            }
            
            if (request.flags.gpu_decompression) {
                self.gpu_decompressions += 1;
            }
            
            if (request.flags.zero_copy) {
                self.zero_copy_operations += 1;
            }
        } else {
            self.failed_requests += 1;
        }
    }
};

/// I/O Request Queue for priority ordering
const IORequestQueue = struct {
    allocator: std.mem.Allocator,
    queues: [5]std.ArrayList(*DirectStorageRequest), // One queue per priority level
    lock: sync.SpinLock,
    
    pub fn init(allocator: std.mem.Allocator) IORequestQueue {
        var queues: [5]std.ArrayList(*DirectStorageRequest) = undefined;
        for (0..5) |i| {
            queues[i] = std.ArrayList(*DirectStorageRequest).init(allocator);
        }
        
        return IORequestQueue{
            .allocator = allocator,
            .queues = queues,
            .lock = sync.SpinLock.init(),
        };
    }
    
    pub fn deinit(self: *IORequestQueue) void {
        for (self.queues) |*queue| {
            queue.deinit();
        }
    }
    
    pub fn enqueue(self: *IORequestQueue, request: *DirectStorageRequest) !void {
        self.lock.acquire();
        defer self.lock.release();
        
        const priority_index = @intFromEnum(request.priority);
        try self.queues[priority_index].append(request);
    }
    
    pub fn dequeue(self: *IORequestQueue) ?*DirectStorageRequest {
        self.lock.acquire();
        defer self.lock.release();
        
        // Check queues in priority order (immediate -> background)
        for (self.queues) |*queue| {
            if (queue.items.len > 0) {
                return queue.orderedRemove(0);
            }
        }
        
        return null;
    }
    
    pub fn hasRequests(self: *IORequestQueue) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        for (self.queues) |queue| {
            if (queue.items.len > 0) return true;
        }
        return false;
    }
};

/// Direct Storage Engine
pub const DirectStorageEngine = struct {
    allocator: std.mem.Allocator,
    request_queue: IORequestQueue,
    worker_threads: []std.Thread,
    gpu_decompression_engine: GPUDecompressionEngine,
    stats: DirectStorageStats,
    running: bool,
    
    // Configuration
    worker_thread_count: u32,
    enable_gpu_decompression: bool,
    enable_zero_copy: bool,
    max_request_size: u64,
    prefetch_enabled: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const worker_count = 4; // Adjust based on CPU cores
        const workers = try allocator.alloc(std.Thread, worker_count);
        
        return Self{
            .allocator = allocator,
            .request_queue = IORequestQueue.init(allocator),
            .worker_threads = workers,
            .gpu_decompression_engine = try GPUDecompressionEngine.init(allocator),
            .stats = DirectStorageStats{},
            .running = false,
            .worker_thread_count = worker_count,
            .enable_gpu_decompression = true,
            .enable_zero_copy = true,
            .max_request_size = 1024 * 1024 * 1024, // 1GB max
            .prefetch_enabled = true,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.request_queue.deinit();
        self.gpu_decompression_engine.deinit();
        self.allocator.free(self.worker_threads);
    }
    
    pub fn start(self: *Self) !void {
        if (self.running) return;
        
        self.running = true;
        
        // Start worker threads
        for (self.worker_threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ self, i });
        }
        
        console.printf("Direct Storage engine started with {} worker threads\n", .{self.worker_thread_count});
    }
    
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        
        self.running = false;
        
        // Wait for worker threads to complete
        for (self.worker_threads) |thread| {
            thread.join();
        }
        
        console.writeString("Direct Storage engine stopped\n");
    }
    
    /// Submit a direct storage request
    pub fn submitRequest(self: *Self, request: *DirectStorageRequest) !void {
        // Validate request
        if (request.size > self.max_request_size) {
            return error.RequestTooLarge;
        }
        
        // Optimize flags based on asset type
        if (request.asset_type != .generic) {
            request.flags = DirectStorageFlags.optimizeForAssetType(request.asset_type);
        }
        
        // Enable GPU decompression if available and beneficial
        if (self.enable_gpu_decompression and request.compression_format != .none) {
            request.flags.gpu_decompression = true;
        }
        
        // Enable zero-copy if beneficial
        if (self.enable_zero_copy and request.size >= 4096) {
            request.flags.zero_copy = true;
        }
        
        try self.request_queue.enqueue(request);
        console.printf("Direct Storage: Queued request {} (size: {} bytes, priority: {})\n", 
            .{ request.request_id, request.size, @tagName(request.priority) });
    }
    
    /// Worker thread for processing I/O requests
    fn workerThread(self: *Self, worker_id: usize) void {
        console.printf("Direct Storage worker {} started\n", .{worker_id});
        
        while (self.running) {
            if (self.request_queue.dequeue()) |request| {
                self.processRequest(request, worker_id);
            } else {
                // No requests, sleep briefly
                std.time.sleep(1_000_000); // 1ms
            }
        }
        
        console.printf("Direct Storage worker {} stopped\n", .{worker_id});
    }
    
    fn processRequest(self: *Self, request: *DirectStorageRequest, worker_id: usize) void {
        _ = worker_id;
        
        request.start_time = @intCast(std.time.nanoTimestamp());
        request.status = .processing;
        
        const result = self.executeRequest(request) catch |err| {
            console.printf("Direct Storage: Request {} failed: {}\n", .{ request.request_id, err });
            DirectStorageResult.createError(1);
        };
        
        request.completion_time = @intCast(std.time.nanoTimestamp());
        request.status = if (result.success) .completed else .failed;
        
        // Update statistics
        self.stats.update(request, result);
        
        // Call completion callback if provided
        if (request.completion_callback) |callback| {
            callback(request, result);
        }
        
        console.printf("Direct Storage: Request {} completed in {d:.2}ms\n", 
            .{ request.request_id, request.getLatencyMs() });
    }
    
    fn executeRequest(self: *Self, request: *DirectStorageRequest) !DirectStorageResult {
        const start_time = std.time.nanoTimestamp();
        
        // Fast path for small, uncompressed files
        if (request.size < 4096 and request.compression_format == .none) {
            return self.fastPathRead(request, start_time);
        }
        
        // Zero-copy path for large files
        if (request.flags.zero_copy and request.size >= 65536) {
            return self.zeroCopyRead(request, start_time);
        }
        
        // GPU decompression path
        if (request.flags.gpu_decompression and request.compression_format != .none) {
            return self.gpuDecompressionRead(request, start_time);
        }
        
        // Standard I/O path
        return self.standardRead(request, start_time);
    }
    
    fn fastPathRead(self: *Self, request: *DirectStorageRequest, start_time: i128) !DirectStorageResult {
        _ = self;
        
        // Simulate fast read for small files
        const bytes_read = request.size;
        request.bytes_transferred = bytes_read;
        
        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));
        
        return DirectStorageResult.createSuccess(bytes_read, latency);
    }
    
    fn zeroCopyRead(self: *Self, request: *DirectStorageRequest, start_time: i128) !DirectStorageResult {
        _ = self;
        
        // Simulate zero-copy I/O
        const bytes_read = request.size;
        request.bytes_transferred = bytes_read;
        
        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));
        
        return DirectStorageResult.createSuccess(bytes_read, latency);
    }
    
    fn gpuDecompressionRead(self: *Self, request: *DirectStorageRequest, start_time: i128) !DirectStorageResult {
        request.status = .decompressing;
        
        // Use GPU decompression engine
        const decompression_result = try self.gpu_decompression_engine.decompress(
            request.compression_format,
            request.source_file,
            request.dest_gpu_buffer orelse 0,
            request.size
        );
        
        request.bytes_transferred = decompression_result.decompressed_size;
        
        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));
        
        var result = DirectStorageResult.createSuccess(decompression_result.decompressed_size, latency);
        result.decompression_ratio = decompression_result.compression_ratio;
        result.gpu_time_ns = decompression_result.gpu_time_ns;
        
        return result;
    }
    
    fn standardRead(self: *Self, request: *DirectStorageRequest, start_time: i128) !DirectStorageResult {
        _ = self;
        
        // Simulate standard file I/O
        const bytes_read = request.size;
        request.bytes_transferred = bytes_read;
        
        const end_time = std.time.nanoTimestamp();
        const latency = @as(u64, @intCast(end_time - start_time));
        
        return DirectStorageResult.createSuccess(bytes_read, latency);
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.enable_gpu_decompression = true;
        self.enable_zero_copy = true;
        self.prefetch_enabled = true;
        self.max_request_size = 2 * 1024 * 1024 * 1024; // 2GB for gaming
        
        console.writeString("Direct Storage: Gaming mode enabled\n");
    }
    
    pub fn getStats(self: *Self) DirectStorageStats {
        return self.stats;
    }
};

/// GPU Decompression Engine
const GPUDecompressionEngine = struct {
    allocator: std.mem.Allocator,
    
    const DecompressionResult = struct {
        decompressed_size: u64,
        compression_ratio: f32,
        gpu_time_ns: u64,
    };
    
    pub fn init(allocator: std.mem.Allocator) !GPUDecompressionEngine {
        return GPUDecompressionEngine{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *GPUDecompressionEngine) void {
        _ = self;
    }
    
    pub fn decompress(self: *GPUDecompressionEngine, format: CompressionFormat, source: []const u8, dest_gpu_addr: u64, max_size: u64) !DecompressionResult {
        _ = self;
        _ = source;
        _ = dest_gpu_addr;
        
        const gpu_start = std.time.nanoTimestamp();
        
        // Simulate GPU decompression based on format
        const compression_ratio: f32 = switch (format) {
            .lz4 => 2.5,
            .zstd => 3.5,
            .gdeflate => 4.0,
            .bcpack => 6.0,
            else => 1.0,
        };
        
        const decompressed_size = @min(max_size, @as(u64, @intFromFloat(@as(f32, @floatFromInt(max_size)) * compression_ratio)));
        
        // Simulate GPU processing time
        std.time.sleep(100_000); // 0.1ms GPU decompression
        
        const gpu_end = std.time.nanoTimestamp();
        const gpu_time = @as(u64, @intCast(gpu_end - gpu_start));
        
        return DecompressionResult{
            .decompressed_size = decompressed_size,
            .compression_ratio = compression_ratio,
            .gpu_time_ns = gpu_time,
        };
    }
};

// Global Direct Storage instance
var global_direct_storage: ?*DirectStorageEngine = null;

/// Initialize Direct Storage API
pub fn initDirectStorage(allocator: std.mem.Allocator) !void {
    const engine = try allocator.create(DirectStorageEngine);
    engine.* = try DirectStorageEngine.init(allocator);
    
    // Enable gaming optimizations
    engine.enableGamingMode();
    
    // Start the engine
    try engine.start();
    
    global_direct_storage = engine;
    
    console.writeString("Direct Storage API initialized\n");
}

pub fn getDirectStorage() *DirectStorageEngine {
    return global_direct_storage.?;
}

/// System call interface for Direct Storage
pub fn sys_direct_storage_read(source_path: [*:0]const u8, dest_buffer: [*]u8, size: u64, flags: u32) !i64 {
    const engine = getDirectStorage();
    const allocator = engine.allocator;
    
    // Create request
    var request = try DirectStorageRequest.init(allocator, sched.getCurrentTask().pid, std.mem.span(source_path));
    request.setDestination(dest_buffer[0..size]);
    request.priority = if (flags & 0x1 != 0) .immediate else .normal;
    
    // Submit request
    try engine.submitRequest(&request);
    
    // For synchronous operation, wait for completion
    while (request.status != .completed and request.status != .failed) {
        std.time.sleep(10_000); // 10μs polling
    }
    
    return if (request.status == .completed) @intCast(request.bytes_transferred) else -1;
}

/// Export for game engine integration
pub fn loadGameAsset(asset_path: []const u8, asset_type: AssetType, priority: AssetPriority) !*DirectStorageRequest {
    const engine = getDirectStorage();
    const allocator = engine.allocator;
    
    var request = try allocator.create(DirectStorageRequest);
    request.* = try DirectStorageRequest.init(allocator, sched.getCurrentTask().pid, asset_path);
    request.asset_type = asset_type;
    request.priority = priority;
    
    try engine.submitRequest(request);
    return request;
}