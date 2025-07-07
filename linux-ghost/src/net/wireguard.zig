//! WireGuard VPN Protocol Implementation for Ghost Kernel
//! Pure Zig implementation of WireGuard (RFC) with gaming optimizations
//! Built-in kernel VPN for GhostMesh and high-performance secure networking

const std = @import("std");
const network = @import("network.zig");
const memory = @import("../mm/memory.zig");
const sync = @import("../kernel/sync.zig");
const crypto = std.crypto;

/// WireGuard constants
pub const WIREGUARD_VERSION = 1;
pub const NOISE_PUBLIC_KEY_LEN = 32;
pub const NOISE_PRIVATE_KEY_LEN = 32;
pub const NOISE_SYMMETRIC_KEY_LEN = 32;
pub const NOISE_HASH_LEN = 32;
pub const NOISE_TIMESTAMP_LEN = 12;
pub const NOISE_AUTHTAG_LEN = 16;
pub const COOKIE_LEN = 16;
pub const COOKIE_NONCE_LEN = 24;
pub const COOKIE_KEY_LEN = 32;
pub const REKEY_TIMEOUT = 5; // seconds
pub const KEEPALIVE_TIMEOUT = 10; // seconds
pub const MAX_TIMER_HANDSHAKES = 90; // seconds
pub const MAX_PEERS = 2048;

/// WireGuard message types
pub const MessageType = enum(u8) {
    handshake_initiation = 1,
    handshake_response = 2,
    cookie_reply = 3,
    transport_data = 4,
};

/// WireGuard handshake states
pub const HandshakeState = enum(u8) {
    none = 0,
    created_initiation = 1,
    consumed_initiation = 2,
    created_response = 3,
    consumed_response = 4,
};

/// WireGuard peer states
pub const PeerState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    disconnecting = 3,
};

/// Noise protocol keys
pub const NoiseKeys = struct {
    private_key: [NOISE_PRIVATE_KEY_LEN]u8,
    public_key: [NOISE_PUBLIC_KEY_LEN]u8,
    
    const Self = @This();
    
    pub fn generate(rng: std.Random) Self {
        var keys = Self{
            .private_key = undefined,
            .public_key = undefined,
        };
        
        // Generate Curve25519 key pair
        rng.bytes(&keys.private_key);
        keys.private_key[0] &= 248;
        keys.private_key[31] &= 127;
        keys.private_key[31] |= 64;
        
        // Compute public key
        crypto.dh.X25519.scalarmult(&keys.public_key, &keys.private_key, &crypto.dh.X25519.basepoint);
        
        return keys;
    }
    
    pub fn sharedSecret(private_key: [NOISE_PRIVATE_KEY_LEN]u8, public_key: [NOISE_PUBLIC_KEY_LEN]u8) [NOISE_SYMMETRIC_KEY_LEN]u8 {
        var shared: [NOISE_SYMMETRIC_KEY_LEN]u8 = undefined;
        crypto.dh.X25519.scalarmult(&shared, &private_key, &public_key);
        return shared;
    }
};

/// ChaCha20Poly1305 encryption context
pub const ChaChaPolyContext = struct {
    key: [32]u8,
    counter: u64,
    
    const Self = @This();
    
    pub fn init(key: [32]u8) Self {
        return Self{
            .key = key,
            .counter = 0,
        };
    }
    
    pub fn encrypt(self: *Self, plaintext: []const u8, additional_data: []const u8, ciphertext: []u8, tag: []u8) !void {
        if (ciphertext.len < plaintext.len) return error.BufferTooSmall;
        if (tag.len < 16) return error.BufferTooSmall;
        
        var nonce: [12]u8 = [_]u8{0} ** 12;
        std.mem.writeInt(u64, nonce[4..12], self.counter, .little);
        
        crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(
            ciphertext[0..plaintext.len],
            tag[0..16],
            plaintext,
            additional_data,
            nonce,
            self.key
        );
        
        self.counter += 1;
    }
    
    pub fn decrypt(self: *Self, ciphertext: []const u8, tag: []const u8, additional_data: []const u8, plaintext: []u8) !void {
        if (plaintext.len < ciphertext.len) return error.BufferTooSmall;
        if (tag.len < 16) return error.BufferTooSmall;
        
        var nonce: [12]u8 = [_]u8{0} ** 12;
        std.mem.writeInt(u64, nonce[4..12], self.counter, .little);
        
        try crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(
            plaintext[0..ciphertext.len],
            ciphertext,
            tag[0..16],
            additional_data,
            nonce,
            self.key
        );
        
        self.counter += 1;
    }
    
    pub fn setCounter(self: *Self, counter: u64) void {
        self.counter = counter;
    }
};

/// WireGuard handshake initiation message
pub const HandshakeInitiation = packed struct {
    message_type: u8 = @intFromEnum(MessageType.handshake_initiation),
    reserved: [3]u8 = [_]u8{0} ** 3,
    sender_index: u32,
    unencrypted_ephemeral: [NOISE_PUBLIC_KEY_LEN]u8,
    encrypted_static: [NOISE_PUBLIC_KEY_LEN + NOISE_AUTHTAG_LEN]u8,
    encrypted_timestamp: [NOISE_TIMESTAMP_LEN + NOISE_AUTHTAG_LEN]u8,
    mac1: [COOKIE_LEN]u8,
    mac2: [COOKIE_LEN]u8,
};

/// WireGuard handshake response message
pub const HandshakeResponse = packed struct {
    message_type: u8 = @intFromEnum(MessageType.handshake_response),
    reserved: [3]u8 = [_]u8{0} ** 3,
    sender_index: u32,
    receiver_index: u32,
    unencrypted_ephemeral: [NOISE_PUBLIC_KEY_LEN]u8,
    encrypted_nothing: [NOISE_AUTHTAG_LEN]u8,
    mac1: [COOKIE_LEN]u8,
    mac2: [COOKIE_LEN]u8,
};

/// WireGuard cookie reply message
pub const CookieReply = packed struct {
    message_type: u8 = @intFromEnum(MessageType.cookie_reply),
    reserved: [3]u8 = [_]u8{0} ** 3,
    receiver_index: u32,
    nonce: [COOKIE_NONCE_LEN]u8,
    encrypted_cookie: [COOKIE_LEN + NOISE_AUTHTAG_LEN]u8,
};

/// WireGuard transport data message
pub const TransportData = packed struct {
    message_type: u8 = @intFromEnum(MessageType.transport_data),
    reserved: [3]u8 = [_]u8{0} ** 3,
    receiver_index: u32,
    counter: u64,
    // Followed by encrypted packet data and auth tag
};

/// WireGuard session keys
pub const SessionKeys = struct {
    sending_key: [NOISE_SYMMETRIC_KEY_LEN]u8,
    receiving_key: [NOISE_SYMMETRIC_KEY_LEN]u8,
    sending_context: ChaChaPolyContext,
    receiving_context: ChaChaPolyContext,
    created_at: u64,
    
    const Self = @This();
    
    pub fn init(sending_key: [NOISE_SYMMETRIC_KEY_LEN]u8, receiving_key: [NOISE_SYMMETRIC_KEY_LEN]u8) Self {
        return Self{
            .sending_key = sending_key,
            .receiving_key = receiving_key,
            .sending_context = ChaChaPolyContext.init(sending_key),
            .receiving_context = ChaChaPolyContext.init(receiving_key),
            .created_at = @intCast(std.time.microTimestamp()),
        };
    }
    
    pub fn isExpired(self: Self) bool {
        const now = @as(u64, @intCast(std.time.microTimestamp()));
        const age_seconds = (now - self.created_at) / 1_000_000;
        return age_seconds > REKEY_TIMEOUT;
    }
};

/// WireGuard peer
pub const WireGuardPeer = struct {
    // Identity
    public_key: [NOISE_PUBLIC_KEY_LEN]u8,
    preshared_key: ?[NOISE_SYMMETRIC_KEY_LEN]u8 = null,
    
    // Network configuration
    endpoint: ?network.SocketAddress = null,
    allowed_ips: std.ArrayList(AllowedIP),
    persistent_keepalive: ?u16 = null, // seconds
    
    // State
    state: PeerState,
    handshake_state: HandshakeState,
    sender_index: u32,
    receiver_index: u32,
    
    // Session keys
    current_session: ?SessionKeys = null,
    previous_session: ?SessionKeys = null,
    next_session: ?SessionKeys = null,
    
    // Handshake data
    handshake_hash: [NOISE_HASH_LEN]u8,
    handshake_chaining_key: [NOISE_HASH_LEN]u8,
    ephemeral_private: [NOISE_PRIVATE_KEY_LEN]u8,
    remote_ephemeral: [NOISE_PUBLIC_KEY_LEN]u8,
    
    // Timing
    last_handshake_initiation: u64 = 0,
    last_handshake_response: u64 = 0,
    last_packet_received: u64 = 0,
    last_packet_sent: u64 = 0,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_mode: bool = false,
    priority: u8 = 128,
    
    // Statistics
    tx_bytes: std.atomic.Value(u64),
    rx_bytes: std.atomic.Value(u64),
    tx_packets: std.atomic.Value(u64),
    rx_packets: std.atomic.Value(u64),
    handshake_attempts: std.atomic.Value(u32),
    handshake_failures: std.atomic.Value(u32),
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, public_key: [NOISE_PUBLIC_KEY_LEN]u8) Self {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        
        return Self{
            .public_key = public_key,
            .allowed_ips = std.ArrayList(AllowedIP).init(allocator),
            .state = .disconnected,
            .handshake_state = .none,
            .sender_index = rng.random().int(u32),
            .receiver_index = 0,
            .handshake_hash = [_]u8{0} ** NOISE_HASH_LEN,
            .handshake_chaining_key = [_]u8{0} ** NOISE_HASH_LEN,
            .ephemeral_private = [_]u8{0} ** NOISE_PRIVATE_KEY_LEN,
            .remote_ephemeral = [_]u8{0} ** NOISE_PUBLIC_KEY_LEN,
            .tx_bytes = std.atomic.Value(u64).init(0),
            .rx_bytes = std.atomic.Value(u64).init(0),
            .tx_packets = std.atomic.Value(u64).init(0),
            .rx_packets = std.atomic.Value(u64).init(0),
            .handshake_attempts = std.atomic.Value(u32).init(0),
            .handshake_failures = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allowed_ips.deinit();
    }
    
    pub fn addAllowedIP(self: *Self, allowed_ip: AllowedIP) !void {
        try self.allowed_ips.append(allowed_ip);
    }
    
    pub fn isAllowedIP(self: *Self, ip: network.IPv4Address) bool {
        for (self.allowed_ips.items) |allowed| {
            if (allowed.contains(ip)) return true;
        }
        return false;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.gaming_mode = enabled;
        self.low_latency_mode = enabled;
        self.priority = if (enabled) 255 else 128;
    }
    
    pub fn needsHandshake(self: *Self) bool {
        const now = @as(u64, @intCast(std.time.microTimestamp()));
        
        // No current session
        if (self.current_session == null) return true;
        
        // Session expired
        if (self.current_session.?.isExpired()) return true;
        
        // Haven't attempted handshake recently
        const handshake_age = (now - self.last_handshake_initiation) / 1_000_000;
        return handshake_age > REKEY_TIMEOUT;
    }
    
    pub fn needsKeepalive(self: *Self) bool {
        if (self.persistent_keepalive == null) return false;
        
        const now = @as(u64, @intCast(std.time.microTimestamp()));
        const last_sent_age = (now - self.last_packet_sent) / 1_000_000;
        
        return last_sent_age > self.persistent_keepalive.?;
    }
    
    pub fn updateStats(self: *Self, bytes: u64, sent: bool) void {
        if (sent) {
            _ = self.tx_bytes.fetchAdd(bytes, .release);
            _ = self.tx_packets.fetchAdd(1, .release);
            self.last_packet_sent = @intCast(std.time.microTimestamp());
        } else {
            _ = self.rx_bytes.fetchAdd(bytes, .release);
            _ = self.rx_packets.fetchAdd(1, .release);
            self.last_packet_received = @intCast(std.time.microTimestamp());
        }
    }
    
    pub fn getMetrics(self: *Self) PeerMetrics {
        return PeerMetrics{
            .tx_bytes = self.tx_bytes.load(.acquire),
            .rx_bytes = self.rx_bytes.load(.acquire),
            .tx_packets = self.tx_packets.load(.acquire),
            .rx_packets = self.rx_packets.load(.acquire),
            .handshake_attempts = self.handshake_attempts.load(.acquire),
            .handshake_failures = self.handshake_failures.load(.acquire),
            .state = self.state,
            .last_handshake = @max(self.last_handshake_initiation, self.last_handshake_response),
            .gaming_mode = self.gaming_mode,
        };
    }
};

/// Allowed IP range for a peer
pub const AllowedIP = struct {
    address: network.IPv4Address,
    prefix_len: u8,
    
    const Self = @This();
    
    pub fn init(address: network.IPv4Address, prefix_len: u8) Self {
        return Self{
            .address = address,
            .prefix_len = prefix_len,
        };
    }
    
    pub fn contains(self: Self, ip: network.IPv4Address) bool {
        if (self.prefix_len == 0) return true;
        if (self.prefix_len > 32) return false;
        
        const mask = ~(@as(u32, 0)) << @intCast(32 - self.prefix_len);
        const network_addr = self.address.toU32() & mask;
        const test_addr = ip.toU32() & mask;
        
        return network_addr == test_addr;
    }
};

/// WireGuard interface
pub const WireGuardInterface = struct {
    // Interface configuration
    name: []const u8,
    private_key: [NOISE_PRIVATE_KEY_LEN]u8,
    public_key: [NOISE_PUBLIC_KEY_LEN]u8,
    listen_port: u16,
    fwmark: ?u32 = null,
    
    // Network configuration
    addresses: std.ArrayList(network.IPv4Address),
    dns_servers: std.ArrayList(network.IPv4Address),
    mtu: u16 = 1420, // Default WireGuard MTU
    
    // Peers
    peers: std.HashMap(u32, *WireGuardPeer), // Keyed by peer index
    peer_lookup: std.HashMap(u64, *WireGuardPeer), // Keyed by public key hash
    
    // Network socket
    socket: ?*network.Socket = null,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    ghostmesh_enabled: bool = false,
    
    // State
    up: bool = false,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, private_key: [NOISE_PRIVATE_KEY_LEN]u8) !Self {
        var public_key: [NOISE_PUBLIC_KEY_LEN]u8 = undefined;
        crypto.dh.X25519.scalarmult(&public_key, &private_key, &crypto.dh.X25519.basepoint);
        
        return Self{
            .name = try allocator.dupe(u8, name),
            .private_key = private_key,
            .public_key = public_key,
            .listen_port = 51820, // Default WireGuard port
            .addresses = std.ArrayList(network.IPv4Address).init(allocator),
            .dns_servers = std.ArrayList(network.IPv4Address).init(allocator),
            .peers = std.HashMap(u32, *WireGuardPeer).init(allocator),
            .peer_lookup = std.HashMap(u64, *WireGuardPeer).init(allocator),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up peers
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.peers.deinit();
        self.peer_lookup.deinit();
        
        self.addresses.deinit();
        self.dns_servers.deinit();
        self.allocator.free(self.name);
    }
    
    pub fn addAddress(self: *Self, address: network.IPv4Address) !void {
        try self.addresses.append(address);
    }
    
    pub fn addDNS(self: *Self, dns: network.IPv4Address) !void {
        try self.dns_servers.append(dns);
    }
    
    pub fn addPeer(self: *Self, peer: *WireGuardPeer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const peer_hash = self.hashPublicKey(peer.public_key);
        
        try self.peers.put(peer.sender_index, peer);
        try self.peer_lookup.put(peer_hash, peer);
        
        // Apply gaming mode if enabled
        if (self.gaming_mode) {
            peer.setGamingMode(true);
        }
    }
    
    pub fn removePeer(self: *Self, public_key: [NOISE_PUBLIC_KEY_LEN]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const peer_hash = self.hashPublicKey(public_key);
        
        if (self.peer_lookup.fetchRemove(peer_hash)) |removed| {
            _ = self.peers.remove(removed.value.sender_index);
            removed.value.deinit();
            self.allocator.destroy(removed.value);
        }
    }
    
    pub fn findPeer(self: *Self, public_key: [NOISE_PUBLIC_KEY_LEN]u8) ?*WireGuardPeer {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const peer_hash = self.hashPublicKey(public_key);
        return self.peer_lookup.get(peer_hash);
    }
    
    pub fn findPeerByIndex(self: *Self, sender_index: u32) ?*WireGuardPeer {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.peers.get(sender_index);
    }
    
    pub fn up(self: *Self) !void {
        if (self.up) return;
        
        // Create UDP socket
        const network_stack = network.getNetworkStack();
        self.socket = try network_stack.createSocket(.inet, .dgram, .udp);
        
        // Bind to listen port
        const bind_addr = network.SocketAddress{
            .inet = .{
                .addr = network.IPv4Address.ANY,
                .port = self.listen_port,
            },
        };
        try self.socket.?.bind(bind_addr);
        
        // Apply gaming mode to socket
        if (self.gaming_mode) {
            self.socket.?.setGamingOptions(true);
        }
        
        self.up = true;
    }
    
    pub fn down(self: *Self) void {
        if (!self.up) return;
        
        if (self.socket) |socket| {
            const network_stack = network.getNetworkStack();
            network_stack.closeSocket(socket);
            self.socket = null;
        }
        
        self.up = false;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode = enabled;
        
        // Apply to socket
        if (self.socket) |socket| {
            socket.setGamingOptions(enabled);
        }
        
        // Apply to all peers
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            entry.value_ptr.*.setGamingMode(enabled);
        }
    }
    
    pub fn enableGhostMesh(self: *Self) void {
        self.ghostmesh_enabled = true;
        self.setGamingMode(true);
        
        // GhostMesh specific optimizations
        self.mtu = 1380; // Optimized for gaming
    }
    
    pub fn processIncomingPacket(self: *Self, packet_data: []const u8, from: network.SocketAddress) !void {
        if (packet_data.len < 4) return; // Minimum WireGuard packet size
        
        const message_type: MessageType = @enumFromInt(packet_data[0]);
        
        switch (message_type) {
            .handshake_initiation => {
                try self.processHandshakeInitiation(packet_data, from);
            },
            .handshake_response => {
                try self.processHandshakeResponse(packet_data, from);
            },
            .cookie_reply => {
                try self.processCookieReply(packet_data, from);
            },
            .transport_data => {
                try self.processTransportData(packet_data, from);
            },
        }
    }
    
    pub fn sendPacket(self: *Self, peer: *WireGuardPeer, ip_packet: []const u8) !void {
        if (!self.up or self.socket == null) return error.InterfaceDown;
        if (peer.current_session == null) return error.NoSession;
        if (peer.endpoint == null) return error.NoEndpoint;
        
        // Allocate buffer for WireGuard packet
        const wg_packet_size = @sizeOf(TransportData) + ip_packet.len + NOISE_AUTHTAG_LEN;
        const wg_packet = try self.allocator.alloc(u8, wg_packet_size);
        defer self.allocator.free(wg_packet);
        
        // Create transport data header
        var transport_header = TransportData{
            .receiver_index = peer.receiver_index,
            .counter = peer.current_session.?.sending_context.counter,
        };
        
        // Copy header to packet
        @memcpy(wg_packet[0..@sizeOf(TransportData)], std.mem.asBytes(&transport_header));
        
        // Encrypt IP packet
        const ciphertext = wg_packet[@sizeOf(TransportData)..@sizeOf(TransportData) + ip_packet.len];
        const auth_tag = wg_packet[@sizeOf(TransportData) + ip_packet.len..];
        
        try peer.current_session.?.sending_context.encrypt(
            ip_packet,
            wg_packet[0..@sizeOf(TransportData)], // Additional authenticated data
            ciphertext,
            auth_tag
        );
        
        // Send packet
        _ = try self.socket.?.send(wg_packet);
        peer.updateStats(wg_packet.len, true);
    }
    
    fn processHandshakeInitiation(self: *Self, packet_data: []const u8, from: network.SocketAddress) !void {
        if (packet_data.len != @sizeOf(HandshakeInitiation)) return;
        
        const handshake = @as(*const HandshakeInitiation, @ptrCast(@alignCast(packet_data.ptr))).*;
        
        // TODO: Implement full handshake initiation processing
        // This involves:
        // 1. Validate MAC1 and MAC2
        // 2. Decrypt static key and timestamp
        // 3. Generate ephemeral key pair
        // 4. Derive session keys
        // 5. Send handshake response
        
        _ = self;
        _ = handshake;
        _ = from;
    }
    
    fn processHandshakeResponse(self: *Self, packet_data: []const u8, from: network.SocketAddress) !void {
        if (packet_data.len != @sizeOf(HandshakeResponse)) return;
        
        const handshake = @as(*const HandshakeResponse, @ptrCast(@alignCast(packet_data.ptr))).*;
        
        // TODO: Implement handshake response processing
        
        _ = self;
        _ = handshake;
        _ = from;
    }
    
    fn processCookieReply(self: *Self, packet_data: []const u8, from: network.SocketAddress) !void {
        if (packet_data.len != @sizeOf(CookieReply)) return;
        
        const cookie = @as(*const CookieReply, @ptrCast(@alignCast(packet_data.ptr))).*;
        
        // TODO: Implement cookie reply processing
        
        _ = self;
        _ = cookie;
        _ = from;
    }
    
    fn processTransportData(self: *Self, packet_data: []const u8, from: network.SocketAddress) !void {
        if (packet_data.len < @sizeOf(TransportData) + NOISE_AUTHTAG_LEN) return;
        
        const transport_header = @as(*const TransportData, @ptrCast(@alignCast(packet_data.ptr))).*;
        
        // Find peer by receiver index
        const peer = self.findPeerByIndex(transport_header.receiver_index) orelse return;
        
        if (peer.current_session == null) return;
        
        // Extract ciphertext and auth tag
        const header_size = @sizeOf(TransportData);
        const ciphertext = packet_data[header_size..packet_data.len - NOISE_AUTHTAG_LEN];
        const auth_tag = packet_data[packet_data.len - NOISE_AUTHTAG_LEN..];
        
        // Decrypt packet
        const plaintext = try self.allocator.alloc(u8, ciphertext.len);
        defer self.allocator.free(plaintext);
        
        peer.current_session.?.receiving_context.setCounter(transport_header.counter);
        try peer.current_session.?.receiving_context.decrypt(
            ciphertext,
            auth_tag,
            packet_data[0..header_size], // Additional authenticated data
            plaintext
        );
        
        // Update endpoint
        peer.endpoint = from;
        peer.updateStats(packet_data.len, false);
        
        // Forward decrypted IP packet to network stack
        try self.forwardToNetworkStack(plaintext);
    }
    
    fn forwardToNetworkStack(self: *Self, ip_packet: []const u8) !void {
        // Create network buffer and forward to IP processing
        const network_stack = network.getNetworkStack();
        _ = network_stack;
        _ = ip_packet;
        _ = self;
        
        // TODO: Create NetworkBuffer and process IP packet
    }
    
    fn hashPublicKey(self: Self, public_key: [NOISE_PUBLIC_KEY_LEN]u8) u64 {
        _ = self;
        return std.hash_map.hashString(&public_key);
    }
    
    pub fn getStatus(self: *Self) InterfaceStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var total_tx: u64 = 0;
        var total_rx: u64 = 0;
        var connected_peers: u32 = 0;
        
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            const metrics = entry.value_ptr.*.getMetrics();
            total_tx += metrics.tx_bytes;
            total_rx += metrics.rx_bytes;
            if (metrics.state == .connected) connected_peers += 1;
        }
        
        return InterfaceStatus{
            .name = self.name,
            .up = self.up,
            .listen_port = self.listen_port,
            .total_peers = @intCast(self.peers.count()),
            .connected_peers = connected_peers,
            .tx_bytes = total_tx,
            .rx_bytes = total_rx,
            .gaming_mode = self.gaming_mode,
            .ghostmesh_enabled = self.ghostmesh_enabled,
        };
    }
};

/// Peer performance metrics
pub const PeerMetrics = struct {
    tx_bytes: u64,
    rx_bytes: u64,
    tx_packets: u64,
    rx_packets: u64,
    handshake_attempts: u32,
    handshake_failures: u32,
    state: PeerState,
    last_handshake: u64,
    gaming_mode: bool,
};

/// Interface status
pub const InterfaceStatus = struct {
    name: []const u8,
    up: bool,
    listen_port: u16,
    total_peers: u32,
    connected_peers: u32,
    tx_bytes: u64,
    rx_bytes: u64,
    gaming_mode: bool,
    ghostmesh_enabled: bool,
};

/// WireGuard manager for multiple interfaces
pub const WireGuardManager = struct {
    interfaces: std.HashMap(u64, *WireGuardInterface), // Keyed by name hash
    
    // Gaming optimizations
    gaming_mode_enabled: bool = false,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .interfaces = std.HashMap(u64, *WireGuardInterface).init(allocator),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up interfaces
        var interface_iter = self.interfaces.iterator();
        while (interface_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.interfaces.deinit();
    }
    
    pub fn createInterface(self: *Self, name: []const u8, private_key: [NOISE_PRIVATE_KEY_LEN]u8) !*WireGuardInterface {
        const interface = try self.allocator.create(WireGuardInterface);
        interface.* = try WireGuardInterface.init(self.allocator, name, private_key);
        
        const name_hash = std.hash_map.hashString(name);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.interfaces.put(name_hash, interface);
        
        // Apply gaming mode if enabled
        if (self.gaming_mode_enabled) {
            interface.setGamingMode(true);
        }
        
        return interface;
    }
    
    pub fn removeInterface(self: *Self, name: []const u8) void {
        const name_hash = std.hash_map.hashString(name);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.interfaces.fetchRemove(name_hash)) |removed| {
            removed.value.deinit();
            self.allocator.destroy(removed.value);
        }
    }
    
    pub fn findInterface(self: *Self, name: []const u8) ?*WireGuardInterface {
        const name_hash = std.hash_map.hashString(name);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.interfaces.get(name_hash);
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = true;
        
        // Apply to all interfaces
        var interface_iter = self.interfaces.iterator();
        while (interface_iter.next()) |entry| {
            entry.value_ptr.*.setGamingMode(true);
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = false;
        
        // Apply to all interfaces
        var interface_iter = self.interfaces.iterator();
        while (interface_iter.next()) |entry| {
            entry.value_ptr.*.setGamingMode(false);
        }
    }
    
    pub fn createGhostMeshInterface(self: *Self, name: []const u8, private_key: [NOISE_PRIVATE_KEY_LEN]u8) !*WireGuardInterface {
        const interface = try self.createInterface(name, private_key);
        interface.enableGhostMesh();
        return interface;
    }
    
    pub fn getSystemStatus(self: *Self) WireGuardSystemStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var status = WireGuardSystemStatus{
            .total_interfaces = @intCast(self.interfaces.count()),
            .active_interfaces = 0,
            .total_peers = 0,
            .connected_peers = 0,
            .total_tx_bytes = 0,
            .total_rx_bytes = 0,
            .gaming_mode_enabled = self.gaming_mode_enabled,
            .ghostmesh_interfaces = 0,
        };
        
        var interface_iter = self.interfaces.iterator();
        while (interface_iter.next()) |entry| {
            const interface_status = entry.value_ptr.*.getStatus();
            
            if (interface_status.up) status.active_interfaces += 1;
            status.total_peers += interface_status.total_peers;
            status.connected_peers += interface_status.connected_peers;
            status.total_tx_bytes += interface_status.tx_bytes;
            status.total_rx_bytes += interface_status.rx_bytes;
            if (interface_status.ghostmesh_enabled) status.ghostmesh_interfaces += 1;
        }
        
        return status;
    }
};

/// WireGuard system status
pub const WireGuardSystemStatus = struct {
    total_interfaces: u32,
    active_interfaces: u32,
    total_peers: u32,
    connected_peers: u32,
    total_tx_bytes: u64,
    total_rx_bytes: u64,
    gaming_mode_enabled: bool,
    ghostmesh_interfaces: u32,
};

// Global WireGuard manager
var global_wireguard_manager: ?*WireGuardManager = null;

/// Initialize WireGuard subsystem
pub fn initWireGuard(allocator: std.mem.Allocator) !void {
    const wg = try allocator.create(WireGuardManager);
    wg.* = WireGuardManager.init(allocator);
    global_wireguard_manager = wg;
}

/// Get the global WireGuard manager
pub fn getWireGuardManager() *WireGuardManager {
    return global_wireguard_manager orelse @panic("WireGuard not initialized");
}

// Tests
test "WireGuard key generation" {
    var rng = std.Random.DefaultPrng.init(12345);
    const keys = NoiseKeys.generate(rng.random());
    
    try std.testing.expect(keys.private_key.len == NOISE_PRIVATE_KEY_LEN);
    try std.testing.expect(keys.public_key.len == NOISE_PUBLIC_KEY_LEN);
    
    // Test key exchange
    var rng2 = std.Random.DefaultPrng.init(54321);
    const keys2 = NoiseKeys.generate(rng2.random());
    
    const shared1 = NoiseKeys.sharedSecret(keys.private_key, keys2.public_key);
    const shared2 = NoiseKeys.sharedSecret(keys2.private_key, keys.public_key);
    
    try std.testing.expect(std.mem.eql(u8, &shared1, &shared2));
}

test "ChaCha20Poly1305 encryption" {
    var ctx = ChaChaPolyContext.init([_]u8{1} ** 32);
    
    const plaintext = "Hello, WireGuard!";
    var ciphertext: [32]u8 = undefined;
    var tag: [16]u8 = undefined;
    
    try ctx.encrypt(plaintext, "", ciphertext[0..plaintext.len], &tag);
    
    // Reset counter for decryption
    ctx.setCounter(0);
    
    var decrypted: [32]u8 = undefined;
    try ctx.decrypt(ciphertext[0..plaintext.len], &tag, "", decrypted[0..plaintext.len]);
    
    try std.testing.expect(std.mem.eql(u8, decrypted[0..plaintext.len], plaintext));
}

test "AllowedIP range checking" {
    const allowed = AllowedIP.init(network.IPv4Address.init(192, 168, 1, 0), 24);
    
    try std.testing.expect(allowed.contains(network.IPv4Address.init(192, 168, 1, 1)));
    try std.testing.expect(allowed.contains(network.IPv4Address.init(192, 168, 1, 254)));
    try std.testing.expect(!allowed.contains(network.IPv4Address.init(192, 168, 2, 1)));
    try std.testing.expect(!allowed.contains(network.IPv4Address.init(10, 0, 0, 1)));
}

test "WireGuard interface management" {
    const allocator = std.testing.allocator;
    
    var manager = WireGuardManager.init(allocator);
    defer manager.deinit();
    
    var rng = std.Random.DefaultPrng.init(12345);
    var private_key: [NOISE_PRIVATE_KEY_LEN]u8 = undefined;
    rng.random().bytes(&private_key);
    
    const interface = try manager.createInterface("wg0", private_key);
    try std.testing.expect(std.mem.eql(u8, interface.name, "wg0"));
    
    const found = manager.findInterface("wg0");
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == interface);
    
    manager.enableGamingMode();
    try std.testing.expect(manager.gaming_mode_enabled);
    try std.testing.expect(interface.gaming_mode);
    
    const status = manager.getSystemStatus();
    try std.testing.expect(status.total_interfaces == 1);
    try std.testing.expect(status.gaming_mode_enabled);
}