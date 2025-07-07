//! Network Stack for Ghost Kernel
//! Pure Zig implementation of TCP/IP stack optimized for gaming and low-latency applications

const std = @import("std");
const memory = @import("../mm/memory.zig");
const sync = @import("../kernel/sync.zig");
const driver_framework = @import("../drivers/driver_framework.zig");

/// Network protocols
pub const Protocol = enum(u8) {
    ip = 0,
    icmp = 1,
    tcp = 6,
    udp = 17,
    raw = 255,
};

/// IP address family
pub const AddressFamily = enum(u8) {
    inet = 2,        // IPv4
    inet6 = 10,      // IPv6
    packet = 17,     // Raw packet
};

/// Socket types
pub const SocketType = enum(u8) {
    stream = 1,      // TCP
    dgram = 2,       // UDP
    raw = 3,         // Raw socket
    packet = 10,     // Packet socket
};

/// Socket states
pub const SocketState = enum(u8) {
    closed = 0,
    listen = 1,
    syn_sent = 2,
    syn_rcvd = 3,
    established = 4,
    fin_wait1 = 5,
    fin_wait2 = 6,
    close_wait = 7,
    closing = 8,
    last_ack = 9,
    time_wait = 10,
};

/// Network interface types
pub const InterfaceType = enum(u8) {
    loopback = 0,
    ethernet = 1,
    wireless = 2,
    tunnel = 3,
    bridge = 4,
};

/// IPv4 address
pub const IPv4Address = packed struct {
    octets: [4]u8,
    
    const Self = @This();
    
    pub fn init(a: u8, b: u8, c: u8, d: u8) Self {
        return Self{ .octets = [4]u8{ a, b, c, d } };
    }
    
    pub fn fromU32(addr: u32) Self {
        return Self{ .octets = @bitCast(@byteSwap(addr)) };
    }
    
    pub fn toU32(self: Self) u32 {
        return @byteSwap(@as(u32, @bitCast(self.octets)));
    }
    
    pub fn isLoopback(self: Self) bool {
        return self.octets[0] == 127;
    }
    
    pub fn isPrivate(self: Self) bool {
        return (self.octets[0] == 10) or
            (self.octets[0] == 172 and self.octets[1] >= 16 and self.octets[1] <= 31) or
            (self.octets[0] == 192 and self.octets[1] == 168);
    }
    
    pub fn isBroadcast(self: Self) bool {
        return self.toU32() == 0xFFFFFFFF;
    }
    
    pub fn isMulticast(self: Self) bool {
        return (self.octets[0] & 0xF0) == 0xE0;
    }
    
    pub const LOCALHOST = IPv4Address.init(127, 0, 0, 1);
    pub const ANY = IPv4Address.init(0, 0, 0, 0);
    pub const BROADCAST = IPv4Address.init(255, 255, 255, 255);
};

/// IPv6 address
pub const IPv6Address = packed struct {
    octets: [16]u8,
    
    const Self = @This();
    
    pub fn init(segments: [8]u16) Self {
        var octets: [16]u8 = undefined;
        for (segments, 0..) |segment, i| {
            const bytes = @as([2]u8, @bitCast(@byteSwap(segment)));
            octets[i * 2] = bytes[0];
            octets[i * 2 + 1] = bytes[1];
        }
        return Self{ .octets = octets };
    }
    
    pub fn isLoopback(self: Self) bool {
        return std.mem.eql(u8, &self.octets, &IPv6Address.LOCALHOST.octets);
    }
    
    pub fn isLinkLocal(self: Self) bool {
        return self.octets[0] == 0xFE and (self.octets[1] & 0xC0) == 0x80;
    }
    
    pub fn isMulticast(self: Self) bool {
        return self.octets[0] == 0xFF;
    }
    
    pub const LOCALHOST = IPv6Address.init([8]u16{ 0, 0, 0, 0, 0, 0, 0, 1 });
    pub const ANY = IPv6Address.init([8]u16{ 0, 0, 0, 0, 0, 0, 0, 0 });
};

/// Socket address
pub const SocketAddress = union(AddressFamily) {
    inet: struct {
        addr: IPv4Address,
        port: u16,
    },
    inet6: struct {
        addr: IPv6Address,
        port: u16,
        flow_info: u32 = 0,
        scope_id: u32 = 0,
    },
    packet: struct {
        protocol: u16,
        interface_index: u32,
        hatype: u16,
        pkttype: u8,
        halen: u8,
        addr: [8]u8,
    },
};

/// Network buffer for packet data
pub const NetworkBuffer = struct {
    data: []u8,
    len: usize,
    capacity: usize,
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    
    // Header pointers for different layers
    mac_header: ?[*]u8 = null,
    network_header: ?[*]u8 = null,
    transport_header: ?[*]u8 = null,
    
    // Metadata
    timestamp: u64,
    interface: ?*NetworkInterface = null,
    priority: u8 = 0,
    gaming_optimized: bool = false,
    
    const Self = @This();
    
    pub fn alloc(allocator: std.mem.Allocator, size: usize) !*Self {
        const buffer = try allocator.create(Self);
        const data = try allocator.alloc(u8, size);
        
        buffer.* = Self{
            .data = data,
            .len = 0,
            .capacity = size,
            .ref_count = std.atomic.Value(u32).init(1),
            .allocator = allocator,
            .timestamp = @intCast(std.time.nanoTimestamp()),
        };
        
        return buffer;
    }
    
    pub fn clone(self: *Self) !*Self {
        const new_buffer = try Self.alloc(self.allocator, self.capacity);
        @memcpy(new_buffer.data[0..self.len], self.data[0..self.len]);
        new_buffer.len = self.len;
        new_buffer.mac_header = if (self.mac_header) |h| new_buffer.data.ptr + (@intFromPtr(h) - @intFromPtr(self.data.ptr)) else null;
        new_buffer.network_header = if (self.network_header) |h| new_buffer.data.ptr + (@intFromPtr(h) - @intFromPtr(self.data.ptr)) else null;
        new_buffer.transport_header = if (self.transport_header) |h| new_buffer.data.ptr + (@intFromPtr(h) - @intFromPtr(self.data.ptr)) else null;
        new_buffer.interface = self.interface;
        new_buffer.priority = self.priority;
        new_buffer.gaming_optimized = self.gaming_optimized;
        return new_buffer;
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
    
    pub fn push(self: *Self, size: usize) []u8 {
        if (self.len + size > self.capacity) {
            @panic("Buffer overflow");
        }
        const start = self.len;
        self.len += size;
        return self.data[start..self.len];
    }
    
    pub fn pop(self: *Self, size: usize) void {
        if (size > self.len) {
            @panic("Buffer underflow");
        }
        self.len -= size;
    }
    
    pub fn reserve(self: *Self, size: usize) []u8 {
        if (size > self.capacity) {
            @panic("Not enough capacity");
        }
        return self.data[0..size];
    }
    
    pub fn setMacHeader(self: *Self, offset: usize) void {
        if (offset >= self.len) @panic("Invalid MAC header offset");
        self.mac_header = self.data.ptr + offset;
    }
    
    pub fn setNetworkHeader(self: *Self, offset: usize) void {
        if (offset >= self.len) @panic("Invalid network header offset");
        self.network_header = self.data.ptr + offset;
    }
    
    pub fn setTransportHeader(self: *Self, offset: usize) void {
        if (offset >= self.len) @panic("Invalid transport header offset");
        self.transport_header = self.data.ptr + offset;
    }
};

/// Ethernet header
pub const EthernetHeader = packed struct {
    dest_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
    
    pub const ETHERTYPE_IP = 0x0800;
    pub const ETHERTYPE_IPV6 = 0x86DD;
    pub const ETHERTYPE_ARP = 0x0806;
};

/// IPv4 header
pub const IPv4Header = packed struct {
    version_ihl: u8,         // Version (4 bits) + IHL (4 bits)
    tos: u8,                 // Type of Service
    total_length: u16,       // Total length
    identification: u16,     // Identification
    flags_fragment: u16,     // Flags (3 bits) + Fragment offset (13 bits)
    ttl: u8,                 // Time to Live
    protocol: u8,            // Protocol
    checksum: u16,           // Header checksum
    src_addr: IPv4Address,   // Source address
    dest_addr: IPv4Address,  // Destination address
    
    const Self = @This();
    
    pub fn getVersion(self: Self) u4 {
        return @truncate(self.version_ihl >> 4);
    }
    
    pub fn getIHL(self: Self) u4 {
        return @truncate(self.version_ihl & 0x0F);
    }
    
    pub fn getHeaderLength(self: Self) u8 {
        return self.getIHL() * 4;
    }
    
    pub fn getDontFragment(self: Self) bool {
        return (std.mem.bigToNative(u16, self.flags_fragment) & 0x4000) != 0;
    }
    
    pub fn getMoreFragments(self: Self) bool {
        return (std.mem.bigToNative(u16, self.flags_fragment) & 0x2000) != 0;
    }
    
    pub fn getFragmentOffset(self: Self) u13 {
        return @truncate(std.mem.bigToNative(u16, self.flags_fragment) & 0x1FFF);
    }
    
    pub fn calculateChecksum(self: *Self) u16 {
        self.checksum = 0;
        const header_bytes = @as([*]const u8, @ptrCast(self))[0..@sizeOf(Self)];
        return internetChecksum(header_bytes);
    }
};

/// TCP header
pub const TCPHeader = packed struct {
    src_port: u16,           // Source port
    dest_port: u16,          // Destination port
    seq_num: u32,            // Sequence number
    ack_num: u32,            // Acknowledgment number
    header_len_flags: u16,   // Header length (4 bits) + Reserved (3 bits) + Flags (9 bits)
    window_size: u16,        // Window size
    checksum: u16,           // Checksum
    urgent_ptr: u16,         // Urgent pointer
    
    const Self = @This();
    
    pub fn getHeaderLength(self: Self) u4 {
        return @truncate((std.mem.bigToNative(u16, self.header_len_flags) >> 12) & 0x0F);
    }
    
    pub fn getFlags(self: Self) TCPFlags {
        return @bitCast(@as(u9, @truncate(std.mem.bigToNative(u16, self.header_len_flags) & 0x01FF)));
    }
    
    pub fn setFlags(self: *Self, flags: TCPFlags) void {
        const flags_value = @as(u16, @bitCast(flags));
        const header_len = (self.getHeaderLength() << 12);
        self.header_len_flags = std.mem.nativeToBig(u16, header_len | flags_value);
    }
};

/// TCP flags
pub const TCPFlags = packed struct(u9) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
    ns: bool = false,
};

/// UDP header
pub const UDPHeader = packed struct {
    src_port: u16,           // Source port
    dest_port: u16,          // Destination port
    length: u16,             // Length
    checksum: u16,           // Checksum
};

/// Network interface
pub const NetworkInterface = struct {
    name: []const u8,
    interface_type: InterfaceType,
    index: u32,
    flags: InterfaceFlags,
    mtu: u32,
    mac_address: [6]u8,
    ipv4_addresses: std.ArrayList(IPv4Config),
    ipv6_addresses: std.ArrayList(IPv6Config),
    
    // Statistics
    rx_packets: std.atomic.Value(u64),
    tx_packets: std.atomic.Value(u64),
    rx_bytes: std.atomic.Value(u64),
    tx_bytes: std.atomic.Value(u64),
    rx_errors: std.atomic.Value(u32),
    tx_errors: std.atomic.Value(u32),
    rx_dropped: std.atomic.Value(u32),
    tx_dropped: std.atomic.Value(u32),
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_mode: bool = false,
    priority_queue_enabled: bool = false,
    
    device: ?*driver_framework.Device = null,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, interface_type: InterfaceType) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .interface_type = interface_type,
            .index = 0,
            .flags = InterfaceFlags{},
            .mtu = 1500, // Standard Ethernet MTU
            .mac_address = [_]u8{0} ** 6,
            .ipv4_addresses = std.ArrayList(IPv4Config).init(allocator),
            .ipv6_addresses = std.ArrayList(IPv6Config).init(allocator),
            .rx_packets = std.atomic.Value(u64).init(0),
            .tx_packets = std.atomic.Value(u64).init(0),
            .rx_bytes = std.atomic.Value(u64).init(0),
            .tx_bytes = std.atomic.Value(u64).init(0),
            .rx_errors = std.atomic.Value(u32).init(0),
            .tx_errors = std.atomic.Value(u32).init(0),
            .rx_dropped = std.atomic.Value(u32).init(0),
            .tx_dropped = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.ipv4_addresses.deinit();
        self.ipv6_addresses.deinit();
    }
    
    pub fn addIPv4Address(self: *Self, config: IPv4Config) !void {
        try self.ipv4_addresses.append(config);
    }
    
    pub fn addIPv6Address(self: *Self, config: IPv6Config) !void {
        try self.ipv6_addresses.append(config);
    }
    
    pub fn transmit(self: *Self, buffer: *NetworkBuffer) !void {
        // Update statistics
        _ = self.tx_packets.fetchAdd(1, .release);
        _ = self.tx_bytes.fetchAdd(buffer.len, .release);
        
        // Apply gaming optimizations if enabled
        if (self.gaming_mode and buffer.gaming_optimized) {
            buffer.priority = 255; // Highest priority
        }
        
        // TODO: Actual transmission via device driver
        if (self.device) |device| {
            // Device-specific transmission
            _ = device;
        }
        
        buffer.put();
    }
    
    pub fn receive(self: *Self, buffer: *NetworkBuffer) !void {
        // Update statistics
        _ = self.rx_packets.fetchAdd(1, .release);
        _ = self.rx_bytes.fetchAdd(buffer.len, .release);
        
        buffer.interface = self;
        
        // TODO: Process received packet through network stack
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        self.low_latency_mode = enabled;
        self.priority_queue_enabled = enabled;
        
        // Configure device for gaming mode
        if (self.device) |device| {
            device.setGamingMode(enabled) catch {};
            device.setLowLatency(enabled) catch {};
        }
    }
};

/// Interface configuration flags
pub const InterfaceFlags = packed struct(u32) {
    up: bool = false,               // Interface is up
    broadcast: bool = false,        // Broadcast capable
    debug: bool = false,           // Debug mode
    loopback: bool = false,        // Loopback interface
    point_to_point: bool = false,  // Point-to-point link
    no_trailers: bool = false,     // Avoid use of trailers
    running: bool = false,         // Interface is running
    no_arp: bool = false,          // No ARP protocol
    promisc: bool = false,         // Promiscuous mode
    all_multi: bool = false,       // All multicast
    master: bool = false,          // Load balancer master
    slave: bool = false,           // Load balancer slave
    multicast: bool = false,       // Multicast capable
    portsel: bool = false,         // Can set media type
    automedia: bool = false,       // Auto media select active
    dynamic: bool = false,         // Dynamic interface
    _reserved: u16 = 0,
};

/// IPv4 configuration
pub const IPv4Config = struct {
    address: IPv4Address,
    netmask: IPv4Address,
    broadcast: IPv4Address,
    gateway: ?IPv4Address = null,
};

/// IPv6 configuration
pub const IPv6Config = struct {
    address: IPv6Address,
    prefix_length: u8,
    gateway: ?IPv6Address = null,
};

/// Socket structure
pub const Socket = struct {
    family: AddressFamily,
    socket_type: SocketType,
    protocol: Protocol,
    state: SocketState,
    local_addr: ?SocketAddress = null,
    remote_addr: ?SocketAddress = null,
    
    // Gaming optimizations
    gaming_priority: bool = false,
    low_latency: bool = false,
    no_delay: bool = false,          // TCP_NODELAY equivalent
    
    // Buffers
    receive_buffer: std.ArrayList(u8),
    send_buffer: std.ArrayList(u8),
    
    // Synchronization
    receive_lock: sync.Mutex,
    send_lock: sync.Mutex,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, family: AddressFamily, socket_type: SocketType, protocol: Protocol) Self {
        return Self{
            .family = family,
            .socket_type = socket_type,
            .protocol = protocol,
            .state = .closed,
            .receive_buffer = std.ArrayList(u8).init(allocator),
            .send_buffer = std.ArrayList(u8).init(allocator),
            .receive_lock = sync.Mutex.init(),
            .send_lock = sync.Mutex.init(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.receive_buffer.deinit();
        self.send_buffer.deinit();
    }
    
    pub fn bind(self: *Self, addr: SocketAddress) !void {
        self.local_addr = addr;
    }
    
    pub fn connect(self: *Self, addr: SocketAddress) !void {
        self.remote_addr = addr;
        
        switch (self.socket_type) {
            .stream => {
                // TCP connection establishment
                self.state = .syn_sent;
                // TODO: Send SYN packet
            },
            .dgram => {
                // UDP - just set remote address
                self.state = .established;
            },
            else => return error.NotSupported,
        }
    }
    
    pub fn listen(self: *Self, backlog: u32) !void {
        if (self.socket_type != .stream) {
            return error.InvalidOperation;
        }
        
        _ = backlog;
        self.state = .listen;
    }
    
    pub fn send(self: *Self, data: []const u8) !usize {
        self.send_lock.lock();
        defer self.send_lock.unlock();
        
        // Add data to send buffer
        try self.send_buffer.appendSlice(data);
        
        // TODO: Trigger actual transmission
        return data.len;
    }
    
    pub fn receive(self: *Self, buffer: []u8) !usize {
        self.receive_lock.lock();
        defer self.receive_lock.unlock();
        
        const available = @min(buffer.len, self.receive_buffer.items.len);
        if (available == 0) return 0;
        
        @memcpy(buffer[0..available], self.receive_buffer.items[0..available]);
        
        // Remove received data from buffer
        const remaining = self.receive_buffer.items.len - available;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.receive_buffer.items[0..remaining], self.receive_buffer.items[available..]);
        }
        try self.receive_buffer.resize(remaining);
        
        return available;
    }
    
    pub fn setGamingOptions(self: *Self, enabled: bool) void {
        self.gaming_priority = enabled;
        self.low_latency = enabled;
        self.no_delay = enabled;
    }
};

/// Network stack manager
pub const NetworkStack = struct {
    allocator: std.mem.Allocator,
    interfaces: std.ArrayList(*NetworkInterface),
    sockets: std.ArrayList(*Socket),
    routing_table: RoutingTable,
    arp_table: ARPTable,
    
    // Gaming optimizations
    gaming_mode_enabled: bool = false,
    low_latency_mode: bool = false,
    
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .interfaces = std.ArrayList(*NetworkInterface).init(allocator),
            .sockets = std.ArrayList(*Socket).init(allocator),
            .routing_table = RoutingTable.init(allocator),
            .arp_table = ARPTable.init(allocator),
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
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
        self.arp_table.deinit();
    }
    
    pub fn addInterface(self: *Self, interface: *NetworkInterface) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        interface.index = @intCast(self.interfaces.items.len + 1);
        try self.interfaces.append(interface);
        
        // Apply gaming mode if enabled
        if (self.gaming_mode_enabled) {
            interface.setGamingMode(true);
        }
    }
    
    pub fn createSocket(self: *Self, family: AddressFamily, socket_type: SocketType, protocol: Protocol) !*Socket {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const socket = try self.allocator.create(Socket);
        socket.* = Socket.init(self.allocator, family, socket_type, protocol);
        
        try self.sockets.append(socket);
        
        // Apply gaming optimizations if enabled
        if (self.gaming_mode_enabled) {
            socket.setGamingOptions(true);
        }
        
        return socket;
    }
    
    pub fn closeSocket(self: *Self, socket: *Socket) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.sockets.items, 0..) |s, i| {
            if (s == socket) {
                _ = self.sockets.swapRemove(i);
                socket.deinit();
                self.allocator.destroy(socket);
                break;
            }
        }
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = enabled;
        self.low_latency_mode = enabled;
        
        // Apply to all interfaces
        for (self.interfaces.items) |interface| {
            interface.setGamingMode(enabled);
        }
        
        // Apply to all sockets
        for (self.sockets.items) |socket| {
            socket.setGamingOptions(enabled);
        }
    }
    
    pub fn processPacket(self: *Self, buffer: *NetworkBuffer) !void {
        _ = self;
        defer buffer.put();
        
        // TODO: Implement packet processing pipeline
        // 1. Parse Ethernet header
        // 2. Process based on ethertype (IP, IPv6, ARP, etc.)
        // 3. Handle protocol-specific processing
        // 4. Deliver to appropriate socket
    }
};

/// Routing table entry
pub const RouteEntry = struct {
    destination: IPv4Address,
    netmask: IPv4Address,
    gateway: IPv4Address,
    interface: *NetworkInterface,
    metric: u32,
};

/// Routing table
pub const RoutingTable = struct {
    routes: std.ArrayList(RouteEntry),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .routes = std.ArrayList(RouteEntry).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.routes.deinit();
    }
    
    pub fn addRoute(self: *Self, entry: RouteEntry) !void {
        try self.routes.append(entry);
        
        // Sort by metric (lower is better)
        std.sort.insertion(RouteEntry, self.routes.items, {}, struct {
            fn lessThan(_: void, a: RouteEntry, b: RouteEntry) bool {
                return a.metric < b.metric;
            }
        }.lessThan);
    }
    
    pub fn lookup(self: *Self, dest_addr: IPv4Address) ?RouteEntry {
        for (self.routes.items) |route| {
            const dest_masked = IPv4Address.fromU32(dest_addr.toU32() & route.netmask.toU32());
            if (dest_masked.toU32() == route.destination.toU32()) {
                return route;
            }
        }
        return null;
    }
};

/// ARP table entry
pub const ARPEntry = struct {
    ip_addr: IPv4Address,
    mac_addr: [6]u8,
    interface: *NetworkInterface,
    timestamp: u64,
    static: bool = false,
};

/// ARP table
pub const ARPTable = struct {
    entries: std.HashMap(u32, ARPEntry),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .entries = std.HashMap(u32, ARPEntry).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }
    
    pub fn addEntry(self: *Self, entry: ARPEntry) !void {
        try self.entries.put(entry.ip_addr.toU32(), entry);
    }
    
    pub fn lookup(self: *Self, ip_addr: IPv4Address) ?ARPEntry {
        return self.entries.get(ip_addr.toU32());
    }
    
    pub fn removeExpiredEntries(self: *Self, current_time: u64) void {
        const timeout = 300_000_000_000; // 5 minutes in nanoseconds
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.static and (current_time - entry.value_ptr.timestamp) > timeout) {
                _ = self.entries.remove(entry.key_ptr.*);
            }
        }
    }
};

/// Calculate Internet checksum (RFC 1071)
pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    
    // Sum 16-bit words
    while (i + 1 < data.len) {
        const word = (@as(u16, data[i]) << 8) | data[i + 1];
        sum += word;
        i += 2;
    }
    
    // Add odd byte if present
    if (i < data.len) {
        sum += @as(u16, data[i]) << 8;
    }
    
    // Add carry
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    
    return ~@as(u16, @truncate(sum));
}

// Global network stack
var global_network_stack: ?*NetworkStack = null;

/// Initialize the network stack
pub fn initNetworkStack(allocator: std.mem.Allocator) !void {
    const stack = try allocator.create(NetworkStack);
    stack.* = NetworkStack.init(allocator);
    global_network_stack = stack;
    
    // Create loopback interface
    const loopback = try allocator.create(NetworkInterface);
    loopback.* = try NetworkInterface.init(allocator, "lo", .loopback);
    loopback.flags.up = true;
    loopback.flags.running = true;
    loopback.flags.loopback = true;
    
    // Add loopback addresses
    try loopback.addIPv4Address(IPv4Config{
        .address = IPv4Address.LOCALHOST,
        .netmask = IPv4Address.init(255, 0, 0, 0),
        .broadcast = IPv4Address.LOCALHOST,
    });
    
    try loopback.addIPv6Address(IPv6Config{
        .address = IPv6Address.LOCALHOST,
        .prefix_length = 128,
    });
    
    try stack.addInterface(loopback);
}

/// Get the global network stack
pub fn getNetworkStack() *NetworkStack {
    return global_network_stack orelse @panic("Network stack not initialized");
}

// Tests
test "IPv4 address operations" {
    const addr = IPv4Address.init(192, 168, 1, 1);
    
    try std.testing.expect(addr.isPrivate());
    try std.testing.expect(!addr.isLoopback());
    try std.testing.expect(!addr.isBroadcast());
    try std.testing.expect(!addr.isMulticast());
    
    const localhost = IPv4Address.LOCALHOST;
    try std.testing.expect(localhost.isLoopback());
}

test "network buffer operations" {
    const allocator = std.testing.allocator;
    
    const buffer = try NetworkBuffer.alloc(allocator, 1500);
    defer buffer.put();
    
    try std.testing.expect(buffer.capacity == 1500);
    try std.testing.expect(buffer.len == 0);
    
    const data = buffer.push(100);
    try std.testing.expect(data.len == 100);
    try std.testing.expect(buffer.len == 100);
    
    buffer.pop(50);
    try std.testing.expect(buffer.len == 50);
}

test "socket creation and operations" {
    const allocator = std.testing.allocator;
    
    var socket = Socket.init(allocator, .inet, .stream, .tcp);
    defer socket.deinit();
    
    try std.testing.expect(socket.state == .closed);
    try std.testing.expect(socket.family == .inet);
    try std.testing.expect(socket.socket_type == .stream);
    try std.testing.expect(socket.protocol == .tcp);
    
    socket.setGamingOptions(true);
    try std.testing.expect(socket.gaming_priority);
    try std.testing.expect(socket.low_latency);
    try std.testing.expect(socket.no_delay);
}

test "internet checksum calculation" {
    const data = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xac, 0x10, 0x0a, 0x63, 0xac, 0x10, 0x0a, 0x0c };
    const checksum = internetChecksum(&data);
    
    // Verify checksum is reasonable (actual value depends on data)
    try std.testing.expect(checksum != 0);
}