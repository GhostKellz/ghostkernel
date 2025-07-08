//! Next-Generation Network Stack for Ghost Kernel
//! Ultra-low latency, zero-copy networking optimized for gaming and real-time applications

const std = @import("std");
const memory = @import("../mm/memory.zig");
const paging = @import("../mm/paging.zig");
const driver_framework = @import("../drivers/driver_framework.zig");
const sync = @import("../kernel/sync.zig");

/// Network protocols
pub const Protocol = enum(u8) {
    tcp = 6,
    udp = 17,
    icmp = 1,
    quic = 143,
    gaming_udp = 200,  // Custom gaming protocol
    vrr_sync = 201,    // VRR synchronization protocol
    _,
};

/// Network socket types
pub const SocketType = enum(u8) {
    stream = 1,        // TCP-like
    datagram = 2,      // UDP-like
    raw = 3,           // Raw sockets
    gaming = 4,        // Gaming-optimized socket
    zero_copy = 5,     // Zero-copy socket
    kernel_bypass = 6, // Kernel bypass socket
};

/// Network performance modes
pub const PerformanceMode = enum(u8) {
    balanced = 0,      // Balanced performance
    low_latency = 1,   // Ultra-low latency
    high_throughput = 2, // High throughput
    gaming = 3,        // Gaming optimized
    streaming = 4,     // Streaming optimized
    realtime = 5,      // Real-time applications
};

/// Network buffer management
pub const NetworkBuffer = struct {
    data: []u8,
    capacity: usize,
    read_offset: usize,
    write_offset: usize,
    dma_address: ?usize,
    zero_copy: bool,
    ref_count: std.atomic.Value(u32),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, size: usize, zero_copy: bool) !Self {
        const data = if (zero_copy) 
            try allocator.alignedAlloc(u8, 4096, size) // Page-aligned for zero-copy
        else
            try allocator.alloc(u8, size);
        
        return Self{
            .data = data,
            .capacity = size,
            .read_offset = 0,
            .write_offset = 0,
            .dma_address = if (zero_copy) paging.getPhysicalAddress(@intFromPtr(data.ptr)) else null,
            .zero_copy = zero_copy,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.zero_copy) {
            allocator.free(self.data);
        } else {
            allocator.free(self.data);
        }
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self, allocator: std.mem.Allocator) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            self.deinit(allocator);
        }
    }
    
    pub fn availableRead(self: *Self) usize {
        return self.write_offset - self.read_offset;
    }
    
    pub fn availableWrite(self: *Self) usize {
        return self.capacity - self.write_offset;
    }
    
    pub fn readData(self: *Self, buffer: []u8) usize {
        const available = self.availableRead();
        const read_size = @min(buffer.len, available);
        
        @memcpy(buffer[0..read_size], self.data[self.read_offset..self.read_offset + read_size]);
        self.read_offset += read_size;
        
        return read_size;
    }
    
    pub fn writeData(self: *Self, buffer: []const u8) usize {
        const available = self.availableWrite();
        const write_size = @min(buffer.len, available);
        
        @memcpy(self.data[self.write_offset..self.write_offset + write_size], buffer[0..write_size]);
        self.write_offset += write_size;
        
        return write_size;
    }
    
    pub fn compact(self: *Self) void {
        if (self.read_offset > 0) {
            const data_size = self.availableRead();
            if (data_size > 0) {
                std.mem.copyForwards(u8, self.data[0..data_size], self.data[self.read_offset..self.write_offset]);
            }
            self.read_offset = 0;
            self.write_offset = data_size;
        }
    }
};

/// Network packet structure
pub const NetworkPacket = struct {
    buffer: *NetworkBuffer,
    protocol: Protocol,
    source_addr: NetworkAddress,
    dest_addr: NetworkAddress,
    priority: u8,
    timestamp: u64,
    gaming_flags: GamingFlags,
    
    const Self = @This();
    
    pub fn init(buffer: *NetworkBuffer, protocol: Protocol) Self {
        return Self{
            .buffer = buffer,
            .protocol = protocol,
            .source_addr = NetworkAddress.init(),
            .dest_addr = NetworkAddress.init(),
            .priority = 0,
            .timestamp = std.time.nanoTimestamp(),
            .gaming_flags = GamingFlags{},
        };
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.buffer.put(allocator);
    }
};

/// Network address structure
pub const NetworkAddress = struct {
    family: AddressFamily,
    addr: union(AddressFamily) {
        ipv4: [4]u8,
        ipv6: [16]u8,
        mac: [6]u8,
    },
    port: u16,
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .family = .ipv4,
            .addr = .{ .ipv4 = [4]u8{0, 0, 0, 0} },
            .port = 0,
        };
    }
    
    pub fn initIPv4(addr: [4]u8, port: u16) Self {
        return Self{
            .family = .ipv4,
            .addr = .{ .ipv4 = addr },
            .port = port,
        };
    }
    
    pub fn initIPv6(addr: [16]u8, port: u16) Self {
        return Self{
            .family = .ipv6,
            .addr = .{ .ipv6 = addr },
            .port = port,
        };
    }
};

/// Address families
pub const AddressFamily = enum(u8) {
    ipv4 = 2,
    ipv6 = 10,
    mac = 1,
};

/// Gaming-specific flags
pub const GamingFlags = packed struct(u32) {
    low_latency: bool = false,
    high_priority: bool = false,
    zero_copy: bool = false,
    kernel_bypass: bool = false,
    vrr_sync: bool = false,
    frame_sync: bool = false,
    input_packet: bool = false,
    audio_packet: bool = false,
    video_packet: bool = false,
    _reserved: u23 = 0,
};

/// Network interface
pub const NetworkInterface = struct {
    name: []const u8,
    device: *driver_framework.Device,
    addresses: std.ArrayList(NetworkAddress),
    mtu: u16,
    flags: InterfaceFlags,
    stats: InterfaceStats,
    gaming_mode: bool,
    performance_mode: PerformanceMode,
    
    // Hardware offloading
    hw_checksum: bool,
    hw_segmentation: bool,
    hw_timestamping: bool,
    
    // Gaming optimizations
    interrupt_coalescing: bool,
    adaptive_rx: bool,
    zero_copy_rx: bool,
    zero_copy_tx: bool,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, device: *driver_framework.Device) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .device = device,
            .addresses = std.ArrayList(NetworkAddress).init(allocator),
            .mtu = 1500,
            .flags = InterfaceFlags{},
            .stats = InterfaceStats{},
            .gaming_mode = false,
            .performance_mode = .balanced,
            .hw_checksum = false,
            .hw_segmentation = false,
            .hw_timestamping = false,
            .interrupt_coalescing = false,
            .adaptive_rx = false,
            .zero_copy_rx = false,
            .zero_copy_tx = false,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.addresses.deinit();
    }
    
    pub fn enableGamingMode(self: *Self) !void {
        self.gaming_mode = true;
        self.performance_mode = .gaming;
        
        // Enable all gaming optimizations
        self.interrupt_coalescing = true;
        self.adaptive_rx = true;
        self.zero_copy_rx = true;
        self.zero_copy_tx = true;
        
        // Configure device for gaming
        try self.device.setGamingMode(true);
        try self.device.setLowLatency(true);
        
        // Update interface flags
        self.flags.low_latency = true;
        self.flags.high_performance = true;
    }
    
    pub fn disableGamingMode(self: *Self) !void {
        self.gaming_mode = false;
        self.performance_mode = .balanced;
        
        try self.device.setGamingMode(false);
        try self.device.setLowLatency(false);
        
        self.flags.low_latency = false;
        self.flags.high_performance = false;
    }
    
    pub fn transmit(self: *Self, packet: *NetworkPacket) !void {
        // Update statistics
        self.stats.tx_packets += 1;
        self.stats.tx_bytes += packet.buffer.availableRead();
        
        // Apply gaming optimizations
        if (self.gaming_mode) {
            packet.gaming_flags.low_latency = true;
            packet.priority = 7; // Highest priority
        }
        
        // Hardware offloading
        if (self.hw_checksum) {
            // Let hardware calculate checksum
        }
        
        if (self.hw_segmentation) {
            // Let hardware handle segmentation
        }
        
        // Zero-copy transmission
        if (self.zero_copy_tx and packet.buffer.zero_copy) {
            try self.transmitZeroCopy(packet);
        } else {
            try self.transmitCopy(packet);
        }
    }
    
    fn transmitZeroCopy(self: *Self, packet: *NetworkPacket) !void {
        // Direct DMA from packet buffer
        if (packet.buffer.dma_address) |dma_addr| {
            const dma_mapping = driver_framework.DMAMapping{
                .virtual_addr = @intFromPtr(packet.buffer.data.ptr),
                .physical_addr = dma_addr,
                .size = packet.buffer.availableRead(),
                .direction = .to_device,
                .coherent = true,
            };
            
            try dma_mapping.sync(.to_device);
            
            // Program network device DMA
            // This would be device-specific implementation
        }
    }
    
    fn transmitCopy(self: *Self, packet: *NetworkPacket) !void {
        _ = self;
        _ = packet;
        // Traditional copy-based transmission
    }
    
    pub fn receive(self: *Self, buffer: *NetworkBuffer) !?NetworkPacket {
        // Device-specific receive implementation
        _ = self;
        _ = buffer;
        return null;
    }
};

/// Interface flags
pub const InterfaceFlags = packed struct(u32) {
    up: bool = false,
    broadcast: bool = false,
    loopback: bool = false,
    point_to_point: bool = false,
    multicast: bool = false,
    promisc: bool = false,
    allmulti: bool = false,
    low_latency: bool = false,
    high_performance: bool = false,
    gaming_optimized: bool = false,
    _reserved: u22 = 0,
};

/// Interface statistics
pub const InterfaceStats = struct {
    rx_packets: u64 = 0,
    tx_packets: u64 = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_errors: u64 = 0,
    tx_errors: u64 = 0,
    rx_dropped: u64 = 0,
    tx_dropped: u64 = 0,
    rx_latency_ns: u64 = 0,
    tx_latency_ns: u64 = 0,
    gaming_packets: u64 = 0,
    frame_sync_packets: u64 = 0,
};

/// Network socket
pub const NetworkSocket = struct {
    socket_type: SocketType,
    protocol: Protocol,
    local_addr: NetworkAddress,
    remote_addr: NetworkAddress,
    performance_mode: PerformanceMode,
    gaming_flags: GamingFlags,
    
    // Buffers
    rx_buffer: *NetworkBuffer,
    tx_buffer: *NetworkBuffer,
    
    // State
    state: SocketState,
    flags: SocketFlags,
    
    // Performance metrics
    latency_ns: u64,
    throughput_bps: u64,
    packet_loss: f32,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, socket_type: SocketType, protocol: Protocol) !Self {
        const rx_buffer = try allocator.create(NetworkBuffer);
        rx_buffer.* = try NetworkBuffer.init(allocator, 64 * 1024, false); // 64KB RX buffer
        
        const tx_buffer = try allocator.create(NetworkBuffer);
        tx_buffer.* = try NetworkBuffer.init(allocator, 64 * 1024, false); // 64KB TX buffer
        
        return Self{
            .socket_type = socket_type,
            .protocol = protocol,
            .local_addr = NetworkAddress.init(),
            .remote_addr = NetworkAddress.init(),
            .performance_mode = .balanced,
            .gaming_flags = GamingFlags{},
            .rx_buffer = rx_buffer,
            .tx_buffer = tx_buffer,
            .state = .closed,
            .flags = SocketFlags{},
            .latency_ns = 0,
            .throughput_bps = 0,
            .packet_loss = 0.0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.rx_buffer.put(self.allocator);
        self.tx_buffer.put(self.allocator);
    }
    
    pub fn bind(self: *Self, addr: NetworkAddress) !void {
        self.local_addr = addr;
        self.state = .bound;
    }
    
    pub fn connect(self: *Self, addr: NetworkAddress) !void {
        self.remote_addr = addr;
        self.state = .connected;
    }
    
    pub fn send(self: *Self, data: []const u8) !usize {
        const written = self.tx_buffer.writeData(data);
        
        // Update performance metrics
        self.updateLatencyMetrics();
        self.updateThroughputMetrics(written);
        
        return written;
    }
    
    pub fn receive(self: *Self, buffer: []u8) !usize {
        const read = self.rx_buffer.readData(buffer);
        
        // Update performance metrics
        self.updateLatencyMetrics();
        
        return read;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_flags.low_latency = enabled;
        self.gaming_flags.high_priority = enabled;
        self.gaming_flags.zero_copy = enabled;
        
        if (enabled) {
            self.performance_mode = .gaming;
        } else {
            self.performance_mode = .balanced;
        }
    }
    
    pub fn enableKernelBypass(self: *Self) !void {
        self.gaming_flags.kernel_bypass = true;
        self.socket_type = .kernel_bypass;
        
        // Switch to zero-copy buffers
        self.rx_buffer.put(self.allocator);
        self.tx_buffer.put(self.allocator);
        
        self.rx_buffer = try self.allocator.create(NetworkBuffer);
        self.rx_buffer.* = try NetworkBuffer.init(self.allocator, 64 * 1024, true);
        
        self.tx_buffer = try self.allocator.create(NetworkBuffer);
        self.tx_buffer.* = try NetworkBuffer.init(self.allocator, 64 * 1024, true);
    }
    
    fn updateLatencyMetrics(self: *Self) void {
        // Calculate RTT and update latency metrics
        const now = std.time.nanoTimestamp();
        self.latency_ns = @intCast(now);
    }
    
    fn updateThroughputMetrics(self: *Self, bytes: usize) void {
        // Update throughput metrics
        self.throughput_bps = bytes * 8; // Convert to bits per second
    }
};

/// Socket states
pub const SocketState = enum(u8) {
    closed = 0,
    bound = 1,
    listening = 2,
    connected = 3,
    established = 4,
    closing = 5,
    error = 6,
};

/// Socket flags
pub const SocketFlags = packed struct(u32) {
    non_blocking: bool = false,
    broadcast: bool = false,
    keepalive: bool = false,
    linger: bool = false,
    oob_inline: bool = false,
    reuse_addr: bool = false,
    reuse_port: bool = false,
    timestamp: bool = false,
    gaming_mode: bool = false,
    zero_copy: bool = false,
    kernel_bypass: bool = false,
    _reserved: u21 = 0,
};

/// Network stack
pub const NetworkStack = struct {
    allocator: std.mem.Allocator,
    interfaces: std.ArrayList(*NetworkInterface),
    sockets: std.ArrayList(*NetworkSocket),
    routing_table: std.ArrayList(RouteEntry),
    
    // Gaming optimizations
    gaming_mode_enabled: bool,
    global_performance_mode: PerformanceMode,
    interrupt_affinity: ?u32,
    
    // Statistics
    total_packets: u64,
    gaming_packets: u64,
    zero_copy_packets: u64,
    kernel_bypass_packets: u64,
    
    // Synchronization
    stack_lock: sync.RWLock,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .interfaces = std.ArrayList(*NetworkInterface).init(allocator),
            .sockets = std.ArrayList(*NetworkSocket).init(allocator),
            .routing_table = std.ArrayList(RouteEntry).init(allocator),
            .gaming_mode_enabled = false,
            .global_performance_mode = .balanced,
            .interrupt_affinity = null,
            .total_packets = 0,
            .gaming_packets = 0,
            .zero_copy_packets = 0,
            .kernel_bypass_packets = 0,
            .stack_lock = sync.RWLock.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        // Clean up interfaces
        for (self.interfaces.items) |interface| {
            interface.deinit();
            self.allocator.destroy(interface);
        }
        self.interfaces.deinit();
        
        // Clean up sockets
        for (self.sockets.items) |socket| {
            socket.deinit();
            self.allocator.destroy(socket);
        }
        self.sockets.deinit();
        
        self.routing_table.deinit();
    }
    
    pub fn addInterface(self: *Self, interface: *NetworkInterface) !void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        try self.interfaces.append(interface);
        
        // Auto-enable gaming mode if globally enabled
        if (self.gaming_mode_enabled) {
            try interface.enableGamingMode();
        }
    }
    
    pub fn removeInterface(self: *Self, interface: *NetworkInterface) void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        for (self.interfaces.items, 0..) |iface, i| {
            if (iface == interface) {
                _ = self.interfaces.swapRemove(i);
                break;
            }
        }
    }
    
    pub fn createSocket(self: *Self, socket_type: SocketType, protocol: Protocol) !*NetworkSocket {
        const socket = try self.allocator.create(NetworkSocket);
        socket.* = try NetworkSocket.init(self.allocator, socket_type, protocol);
        
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        try self.sockets.append(socket);
        
        // Auto-enable gaming mode if globally enabled
        if (self.gaming_mode_enabled) {
            socket.setGamingMode(true);
        }
        
        return socket;
    }
    
    pub fn closeSocket(self: *Self, socket: *NetworkSocket) void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        for (self.sockets.items, 0..) |sock, i| {
            if (sock == socket) {
                _ = self.sockets.swapRemove(i);
                break;
            }
        }
        
        socket.deinit();
        self.allocator.destroy(socket);
    }
    
    pub fn enableGlobalGamingMode(self: *Self) !void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        self.gaming_mode_enabled = true;
        self.global_performance_mode = .gaming;
        
        // Enable gaming mode on all interfaces
        for (self.interfaces.items) |interface| {
            try interface.enableGamingMode();
        }
        
        // Enable gaming mode on all sockets
        for (self.sockets.items) |socket| {
            socket.setGamingMode(true);
        }
    }
    
    pub fn disableGlobalGamingMode(self: *Self) !void {
        self.stack_lock.writeLock();
        defer self.stack_lock.writeUnlock();
        
        self.gaming_mode_enabled = false;
        self.global_performance_mode = .balanced;
        
        // Disable gaming mode on all interfaces
        for (self.interfaces.items) |interface| {
            try interface.disableGamingMode();
        }
        
        // Disable gaming mode on all sockets
        for (self.sockets.items) |socket| {
            socket.setGamingMode(false);
        }
    }
    
    pub fn processPacket(self: *Self, packet: *NetworkPacket) !void {
        self.total_packets += 1;
        
        // Gaming packet processing
        if (packet.gaming_flags.low_latency) {
            self.gaming_packets += 1;
            
            // High-priority processing
            try self.processGamingPacket(packet);
        } else {
            // Standard packet processing
            try self.processStandardPacket(packet);
        }
        
        // Update statistics
        if (packet.gaming_flags.zero_copy) {
            self.zero_copy_packets += 1;
        }
        
        if (packet.gaming_flags.kernel_bypass) {
            self.kernel_bypass_packets += 1;
        }
    }
    
    fn processGamingPacket(self: *Self, packet: *NetworkPacket) !void {
        _ = self;
        _ = packet;
        // High-priority, low-latency packet processing
        // This would implement gaming-specific optimizations
    }
    
    fn processStandardPacket(self: *Self, packet: *NetworkPacket) !void {
        _ = self;
        _ = packet;
        // Standard packet processing
    }
    
    pub fn getPerformanceMetrics(self: *Self) NetworkStackMetrics {
        self.stack_lock.readLock();
        defer self.stack_lock.readUnlock();
        
        return NetworkStackMetrics{
            .total_packets = self.total_packets,
            .gaming_packets = self.gaming_packets,
            .zero_copy_packets = self.zero_copy_packets,
            .kernel_bypass_packets = self.kernel_bypass_packets,
            .interfaces_count = @intCast(self.interfaces.items.len),
            .sockets_count = @intCast(self.sockets.items.len),
            .gaming_mode_enabled = self.gaming_mode_enabled,
            .performance_mode = self.global_performance_mode,
        };
    }
};

/// Route entry
pub const RouteEntry = struct {
    destination: NetworkAddress,
    gateway: NetworkAddress,
    interface: *NetworkInterface,
    metric: u32,
    flags: RouteFlags,
};

/// Route flags
pub const RouteFlags = packed struct(u32) {
    up: bool = false,
    gateway: bool = false,
    host: bool = false,
    reject: bool = false,
    dynamic: bool = false,
    modified: bool = false,
    _reserved: u26 = 0,
};

/// Network stack metrics
pub const NetworkStackMetrics = struct {
    total_packets: u64,
    gaming_packets: u64,
    zero_copy_packets: u64,
    kernel_bypass_packets: u64,
    interfaces_count: u32,
    sockets_count: u32,
    gaming_mode_enabled: bool,
    performance_mode: PerformanceMode,
};

// Global network stack instance
var global_network_stack: ?*NetworkStack = null;

/// Initialize the network stack
pub fn initNetworkStack(allocator: std.mem.Allocator) !void {
    const stack = try allocator.create(NetworkStack);
    stack.* = NetworkStack.init(allocator);
    global_network_stack = stack;
}

/// Get the global network stack
pub fn getNetworkStack() *NetworkStack {
    return global_network_stack orelse @panic("Network stack not initialized");
}

// Tests
test "network buffer operations" {
    const allocator = std.testing.allocator;
    
    var buffer = try NetworkBuffer.init(allocator, 1024, false);
    defer buffer.deinit(allocator);
    
    const test_data = "Hello, World!";
    const written = buffer.writeData(test_data);
    try std.testing.expect(written == test_data.len);
    
    var read_buffer: [32]u8 = undefined;
    const read = buffer.readData(&read_buffer);
    try std.testing.expect(read == test_data.len);
    try std.testing.expectEqualStrings(test_data, read_buffer[0..read]);
}

test "network socket creation" {
    const allocator = std.testing.allocator;
    
    var socket = try NetworkSocket.init(allocator, .datagram, .udp);
    defer socket.deinit();
    
    try std.testing.expect(socket.socket_type == .datagram);
    try std.testing.expect(socket.protocol == .udp);
    try std.testing.expect(socket.state == .closed);
}

test "gaming mode activation" {
    const allocator = std.testing.allocator;
    
    var socket = try NetworkSocket.init(allocator, .gaming, .gaming_udp);
    defer socket.deinit();
    
    socket.setGamingMode(true);
    try std.testing.expect(socket.gaming_flags.low_latency);
    try std.testing.expect(socket.gaming_flags.high_priority);
    try std.testing.expect(socket.performance_mode == .gaming);
}

test "network stack initialization" {
    const allocator = std.testing.allocator;
    
    var stack = NetworkStack.init(allocator);
    defer stack.deinit();
    
    try std.testing.expect(stack.interfaces.items.len == 0);
    try std.testing.expect(stack.sockets.items.len == 0);
    try std.testing.expect(!stack.gaming_mode_enabled);
}