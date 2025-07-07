//! QUIC Protocol Implementation for Ghost Kernel
//! Pure Zig implementation of QUIC (RFC 9000) with gaming optimizations
//! Features: 0-RTT, multiplexed streams, built-in encryption, loss recovery

const std = @import("std");
const network = @import("network.zig");
const memory = @import("../mm/memory.zig");
const sync = @import("../kernel/sync.zig");

/// QUIC version constants
pub const QUIC_VERSION_1 = 0x00000001;
pub const QUIC_VERSION_DRAFT_29 = 0xff00001d;
pub const QUIC_VERSION_NEGOTIATION = 0x00000000;

/// QUIC packet types
pub const PacketType = enum(u8) {
    initial = 0x00,
    zero_rtt = 0x01,
    handshake = 0x02,
    retry = 0x03,
    version_negotiation = 0x00, // Special case
    one_rtt = 0x40, // Short header packets
};

/// QUIC frame types
pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // Base for stream frames (0x08-0x0f)
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close_quic = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
};

/// QUIC connection states
pub const ConnectionState = enum(u8) {
    idle = 0,
    connecting = 1,
    connected = 2,
    closing = 3,
    draining = 4,
    closed = 5,
};

/// QUIC stream states
pub const StreamState = enum(u8) {
    idle = 0,
    open = 1,
    half_closed_local = 2,
    half_closed_remote = 3,
    closed = 4,
    reset_sent = 5,
    reset_received = 6,
};

/// QUIC stream types
pub const StreamType = enum(u2) {
    bidirectional_client = 0b00,
    unidirectional_client = 0b01,
    bidirectional_server = 0b10,
    unidirectional_server = 0b11,
};

/// QUIC connection ID
pub const ConnectionID = struct {
    data: [20]u8, // Max length is 20 bytes
    len: u8,
    
    const Self = @This();
    
    pub fn init(data: []const u8) Self {
        var cid = Self{
            .data = [_]u8{0} ** 20,
            .len = @min(@intCast(data.len), 20),
        };
        @memcpy(cid.data[0..cid.len], data[0..cid.len]);
        return cid;
    }
    
    pub fn random(rng: std.Random) Self {
        var cid = Self{
            .data = undefined,
            .len = 8, // Common length
        };
        rng.bytes(cid.data[0..cid.len]);
        return cid;
    }
    
    pub fn equal(self: Self, other: Self) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.data[0..self.len], other.data[0..other.len]);
    }
    
    pub fn slice(self: Self) []const u8 {
        return self.data[0..self.len];
    }
};

/// QUIC packet number
pub const PacketNumber = u64;

/// QUIC stream ID
pub const StreamID = u64;

/// QUIC error codes
pub const QUICError = error{
    NoError,
    InternalError,
    ConnectionRefused,
    FlowControlError,
    StreamLimitError,
    StreamStateError,
    FinalSizeError,
    FrameEncodingError,
    TransportParameterError,
    ConnectionIDLimitError,
    ProtocolViolation,
    InvalidToken,
    ApplicationError,
    CryptoBufferExceeded,
    KeyUpdateError,
    AEADLimitReached,
    NoViablePathError,
    
    // Implementation errors
    InvalidPacket,
    UnsupportedVersion,
    BufferTooSmall,
    StreamNotFound,
    ConnectionNotFound,
};

/// QUIC transport parameters
pub const TransportParameters = struct {
    original_destination_connection_id: ?ConnectionID = null,
    max_idle_timeout: u64 = 30000, // milliseconds
    stateless_reset_token: ?[16]u8 = null,
    max_udp_payload_size: u64 = 1200,
    initial_max_data: u64 = 1048576, // 1MB
    initial_max_stream_data_bidi_local: u64 = 262144, // 256KB
    initial_max_stream_data_bidi_remote: u64 = 262144, // 256KB
    initial_max_stream_data_uni: u64 = 262144, // 256KB
    initial_max_streams_bidi: u64 = 100,
    initial_max_streams_uni: u64 = 100,
    ack_delay_exponent: u8 = 3,
    max_ack_delay: u64 = 25, // milliseconds
    disable_active_migration: bool = false,
    preferred_address: ?PreferredAddress = null,
    active_connection_id_limit: u64 = 8,
    initial_source_connection_id: ?ConnectionID = null,
    retry_source_connection_id: ?ConnectionID = null,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_mode: bool = false,
    zero_rtt_enabled: bool = true,
};

/// Preferred address for migration
pub const PreferredAddress = struct {
    ipv4_address: ?network.IPv4Address = null,
    ipv4_port: u16 = 0,
    ipv6_address: ?network.IPv6Address = null,
    ipv6_port: u16 = 0,
    connection_id: ConnectionID,
    stateless_reset_token: [16]u8,
};

/// QUIC packet header
pub const PacketHeader = struct {
    header_form: bool, // 0 = short, 1 = long
    packet_type: PacketType,
    type_specific: u8,
    version: u32,
    dest_connection_id: ConnectionID,
    src_connection_id: ?ConnectionID = null,
    token: ?[]const u8 = null,
    packet_number: PacketNumber,
    
    const Self = @This();
    
    pub fn isLongHeader(self: Self) bool {
        return self.header_form;
    }
    
    pub fn isShortHeader(self: Self) bool {
        return !self.header_form;
    }
    
    pub fn encode(self: Self, buffer: []u8) !usize {
        var pos: usize = 0;
        
        if (self.isLongHeader()) {
            // Long header format
            if (buffer.len < 4) return QUICError.BufferTooSmall;
            
            // First byte: header form + packet type + type-specific
            buffer[pos] = 0x80 | (@as(u8, @intFromEnum(self.packet_type)) << 4) | (self.type_specific & 0x0F);
            pos += 1;
            
            // Version (4 bytes, big endian)
            std.mem.writeInt(u32, buffer[pos..pos + 4], self.version, .big);
            pos += 4;
            
            // Destination Connection ID Length + Connection ID
            if (pos >= buffer.len) return QUICError.BufferTooSmall;
            buffer[pos] = self.dest_connection_id.len;
            pos += 1;
            
            if (pos + self.dest_connection_id.len > buffer.len) return QUICError.BufferTooSmall;
            @memcpy(buffer[pos..pos + self.dest_connection_id.len], self.dest_connection_id.slice());
            pos += self.dest_connection_id.len;
            
            // Source Connection ID Length + Connection ID
            if (self.src_connection_id) |src_cid| {
                if (pos >= buffer.len) return QUICError.BufferTooSmall;
                buffer[pos] = src_cid.len;
                pos += 1;
                
                if (pos + src_cid.len > buffer.len) return QUICError.BufferTooSmall;
                @memcpy(buffer[pos..pos + src_cid.len], src_cid.slice());
                pos += src_cid.len;
            } else {
                if (pos >= buffer.len) return QUICError.BufferTooSmall;
                buffer[pos] = 0;
                pos += 1;
            }
            
            // Token (for Initial and Retry packets)
            if (self.packet_type == .initial or self.packet_type == .retry) {
                if (self.token) |token| {
                    // Encode token length as variable-length integer
                    const token_len_encoded = try encodeVarint(token.len, buffer[pos..]);
                    pos += token_len_encoded;
                    
                    if (pos + token.len > buffer.len) return QUICError.BufferTooSmall;
                    @memcpy(buffer[pos..pos + token.len], token);
                    pos += token.len;
                } else {
                    buffer[pos] = 0; // Zero length token
                    pos += 1;
                }
            }
        } else {
            // Short header format
            if (buffer.len < 1) return QUICError.BufferTooSmall;
            
            // First byte: header form + spin bit + reserved + key phase + packet number length
            buffer[pos] = 0x40; // Short header
            pos += 1;
            
            // Destination Connection ID
            if (pos + self.dest_connection_id.len > buffer.len) return QUICError.BufferTooSmall;
            @memcpy(buffer[pos..pos + self.dest_connection_id.len], self.dest_connection_id.slice());
            pos += self.dest_connection_id.len;
        }
        
        // Packet Number (variable length)
        const pn_encoded = try encodePacketNumber(self.packet_number, buffer[pos..]);
        pos += pn_encoded;
        
        return pos;
    }
};

/// QUIC frame
pub const Frame = union(FrameType) {
    padding: PaddingFrame,
    ping: PingFrame,
    ack: AckFrame,
    ack_ecn: AckECNFrame,
    reset_stream: ResetStreamFrame,
    stop_sending: StopSendingFrame,
    crypto: CryptoFrame,
    new_token: NewTokenFrame,
    stream: StreamFrame,
    max_data: MaxDataFrame,
    max_stream_data: MaxStreamDataFrame,
    max_streams_bidi: MaxStreamsFrame,
    max_streams_uni: MaxStreamsFrame,
    data_blocked: DataBlockedFrame,
    stream_data_blocked: StreamDataBlockedFrame,
    streams_blocked_bidi: StreamsBlockedFrame,
    streams_blocked_uni: StreamsBlockedFrame,
    new_connection_id: NewConnectionIDFrame,
    retire_connection_id: RetireConnectionIDFrame,
    path_challenge: PathChallengeFrame,
    path_response: PathResponseFrame,
    connection_close_quic: ConnectionCloseFrame,
    connection_close_app: ConnectionCloseFrame,
    handshake_done: HandshakeDoneFrame,
    
    pub fn encode(self: Frame, buffer: []u8) !usize {
        var pos: usize = 0;
        
        // Encode frame type
        buffer[pos] = @intFromEnum(self);
        pos += 1;
        
        // Encode frame-specific data
        switch (self) {
            .stream => |stream_frame| {
                pos += try stream_frame.encode(buffer[pos..]);
            },
            .ack => |ack_frame| {
                pos += try ack_frame.encode(buffer[pos..]);
            },
            .crypto => |crypto_frame| {
                pos += try crypto_frame.encode(buffer[pos..]);
            },
            .ping, .handshake_done => {
                // No additional data
            },
            else => {
                // TODO: Implement other frame types
                return QUICError.FrameEncodingError;
            },
        }
        
        return pos;
    }
};

/// QUIC stream frame
pub const StreamFrame = struct {
    stream_id: StreamID,
    offset: u64,
    data: []const u8,
    fin: bool = false,
    
    const Self = @This();
    
    pub fn encode(self: Self, buffer: []u8) !usize {
        var pos: usize = 0;
        
        // Stream ID (variable-length integer)
        pos += try encodeVarint(self.stream_id, buffer[pos..]);
        
        // Offset (if present)
        if (self.offset > 0) {
            pos += try encodeVarint(self.offset, buffer[pos..]);
        }
        
        // Length (variable-length integer)
        pos += try encodeVarint(self.data.len, buffer[pos..]);
        
        // Data
        if (pos + self.data.len > buffer.len) return QUICError.BufferTooSmall;
        @memcpy(buffer[pos..pos + self.data.len], self.data);
        pos += self.data.len;
        
        return pos;
    }
};

/// QUIC ACK frame
pub const AckFrame = struct {
    largest_acknowledged: PacketNumber,
    ack_delay: u64,
    ack_ranges: []const AckRange,
    
    const AckRange = struct {
        gap: u64,
        length: u64,
    };
    
    const Self = @This();
    
    pub fn encode(self: Self, buffer: []u8) !usize {
        var pos: usize = 0;
        
        // Largest Acknowledged
        pos += try encodeVarint(self.largest_acknowledged, buffer[pos..]);
        
        // ACK Delay
        pos += try encodeVarint(self.ack_delay, buffer[pos..]);
        
        // ACK Range Count
        pos += try encodeVarint(self.ack_ranges.len - 1, buffer[pos..]);
        
        // First ACK Range
        pos += try encodeVarint(self.ack_ranges[0].length, buffer[pos..]);
        
        // Additional ACK Ranges
        for (self.ack_ranges[1..]) |range| {
            pos += try encodeVarint(range.gap, buffer[pos..]);
            pos += try encodeVarint(range.length, buffer[pos..]);
        }
        
        return pos;
    }
};

/// QUIC crypto frame
pub const CryptoFrame = struct {
    offset: u64,
    data: []const u8,
    
    const Self = @This();
    
    pub fn encode(self: Self, buffer: []u8) !usize {
        var pos: usize = 0;
        
        // Offset
        pos += try encodeVarint(self.offset, buffer[pos..]);
        
        // Length
        pos += try encodeVarint(self.data.len, buffer[pos..]);
        
        // Data
        if (pos + self.data.len > buffer.len) return QUICError.BufferTooSmall;
        @memcpy(buffer[pos..pos + self.data.len], self.data);
        pos += self.data.len;
        
        return pos;
    }
};

// Placeholder frame types (implement as needed)
pub const PaddingFrame = struct {};
pub const PingFrame = struct {};
pub const AckECNFrame = struct {};
pub const ResetStreamFrame = struct {};
pub const StopSendingFrame = struct {};
pub const NewTokenFrame = struct {};
pub const MaxDataFrame = struct {};
pub const MaxStreamDataFrame = struct {};
pub const MaxStreamsFrame = struct {};
pub const DataBlockedFrame = struct {};
pub const StreamDataBlockedFrame = struct {};
pub const StreamsBlockedFrame = struct {};
pub const NewConnectionIDFrame = struct {};
pub const RetireConnectionIDFrame = struct {};
pub const PathChallengeFrame = struct {};
pub const PathResponseFrame = struct {};
pub const ConnectionCloseFrame = struct {};
pub const HandshakeDoneFrame = struct {};

/// QUIC stream
pub const QUICStream = struct {
    id: StreamID,
    state: StreamState,
    stream_type: StreamType,
    
    // Flow control
    max_data: u64,
    data_sent: u64,
    data_received: u64,
    max_stream_data_local: u64,
    max_stream_data_remote: u64,
    
    // Buffers
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    
    // Gaming optimizations
    priority: u8 = 128,
    low_latency: bool = false,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, id: StreamID, stream_type: StreamType) Self {
        return Self{
            .id = id,
            .state = .idle,
            .stream_type = stream_type,
            .max_data = 1048576, // 1MB default
            .data_sent = 0,
            .data_received = 0,
            .max_stream_data_local = 262144, // 256KB
            .max_stream_data_remote = 262144, // 256KB
            .send_buffer = std.ArrayList(u8).init(allocator),
            .recv_buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
    }
    
    pub fn write(self: *Self, data: []const u8) !usize {
        if (self.state != .open and self.state != .half_closed_remote) {
            return QUICError.StreamStateError;
        }
        
        // Check flow control
        if (self.data_sent + data.len > self.max_stream_data_remote) {
            return QUICError.FlowControlError;
        }
        
        try self.send_buffer.appendSlice(data);
        return data.len;
    }
    
    pub fn read(self: *Self, buffer: []u8) !usize {
        if (self.state != .open and self.state != .half_closed_local) {
            return QUICError.StreamStateError;
        }
        
        const to_read = @min(buffer.len, self.recv_buffer.items.len);
        if (to_read == 0) return 0;
        
        @memcpy(buffer[0..to_read], self.recv_buffer.items[0..to_read]);
        
        // Remove read data
        const remaining = self.recv_buffer.items.len - to_read;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining], self.recv_buffer.items[to_read..]);
        }
        try self.recv_buffer.resize(remaining);
        
        return to_read;
    }
    
    pub fn close(self: *Self) void {
        switch (self.state) {
            .open => self.state = .half_closed_local,
            .half_closed_remote => self.state = .closed,
            else => {},
        }
    }
    
    pub fn isClientInitiated(self: Self) bool {
        return (self.id & 0x01) == 0;
    }
    
    pub fn isBidirectional(self: Self) bool {
        return (self.id & 0x02) == 0;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.low_latency = enabled;
        self.priority = if (enabled) 255 else 128;
    }
};

/// QUIC connection
pub const QUICConnection = struct {
    // Connection identifiers
    local_connection_id: ConnectionID,
    remote_connection_id: ConnectionID,
    
    // Connection state
    state: ConnectionState,
    version: u32,
    
    // Network addressing
    local_address: network.SocketAddress,
    remote_address: network.SocketAddress,
    
    // Transport parameters
    local_transport_params: TransportParameters,
    remote_transport_params: ?TransportParameters = null,
    
    // Streams
    streams: std.HashMap(StreamID, *QUICStream),
    next_stream_id_bidi: StreamID,
    next_stream_id_uni: StreamID,
    
    // Packet number spaces
    initial_packet_number: PacketNumber = 0,
    handshake_packet_number: PacketNumber = 0,
    application_packet_number: PacketNumber = 0,
    
    // Flow control
    max_data_local: u64,
    max_data_remote: u64,
    data_sent: u64,
    data_received: u64,
    
    // Congestion control
    congestion_window: u64,
    bytes_in_flight: u64,
    ssthresh: u64,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    low_latency_mode: bool = false,
    zero_rtt_enabled: bool = true,
    
    // Timing
    rtt_latest: u64 = 0,
    rtt_smoothed: u64 = 0,
    rtt_variance: u64 = 0,
    min_rtt: u64 = std.math.maxInt(u64),
    
    // Performance metrics
    packets_sent: std.atomic.Value(u64),
    packets_received: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    packet_losses: std.atomic.Value(u32),
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn initClient(allocator: std.mem.Allocator, local_addr: network.SocketAddress, remote_addr: network.SocketAddress) !Self {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        
        return Self{
            .local_connection_id = ConnectionID.random(rng.random()),
            .remote_connection_id = ConnectionID.init(&[_]u8{}), // Will be set by server
            .state = .idle,
            .version = QUIC_VERSION_1,
            .local_address = local_addr,
            .remote_address = remote_addr,
            .local_transport_params = TransportParameters{},
            .streams = std.HashMap(StreamID, *QUICStream).init(allocator),
            .next_stream_id_bidi = 0, // Client-initiated bidirectional streams start at 0
            .next_stream_id_uni = 2,  // Client-initiated unidirectional streams start at 2
            .max_data_local = 1048576, // 1MB
            .max_data_remote = 1048576, // 1MB
            .data_sent = 0,
            .data_received = 0,
            .congestion_window = 10 * 1200, // 10 packets * 1200 bytes
            .bytes_in_flight = 0,
            .ssthresh = std.math.maxInt(u64),
            .packets_sent = std.atomic.Value(u64).init(0),
            .packets_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .packet_losses = std.atomic.Value(u32).init(0),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn initServer(allocator: std.mem.Allocator, local_addr: network.SocketAddress, remote_addr: network.SocketAddress, client_cid: ConnectionID) !Self {
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        
        return Self{
            .local_connection_id = ConnectionID.random(rng.random()),
            .remote_connection_id = client_cid,
            .state = .idle,
            .version = QUIC_VERSION_1,
            .local_address = local_addr,
            .remote_address = remote_addr,
            .local_transport_params = TransportParameters{},
            .streams = std.HashMap(StreamID, *QUICStream).init(allocator),
            .next_stream_id_bidi = 1, // Server-initiated bidirectional streams start at 1
            .next_stream_id_uni = 3,  // Server-initiated unidirectional streams start at 3
            .max_data_local = 1048576, // 1MB
            .max_data_remote = 1048576, // 1MB
            .data_sent = 0,
            .data_received = 0,
            .congestion_window = 10 * 1200, // 10 packets * 1200 bytes
            .bytes_in_flight = 0,
            .ssthresh = std.math.maxInt(u64),
            .packets_sent = std.atomic.Value(u64).init(0),
            .packets_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .packet_losses = std.atomic.Value(u32).init(0),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up streams
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
    }
    
    pub fn connect(self: *Self) !void {
        if (self.state != .idle) return QUICError.ProtocolViolation;
        
        self.state = .connecting;
        
        // Send Initial packet
        try self.sendInitialPacket();
    }
    
    pub fn createStream(self: *Self, bidirectional: bool) !*QUICStream {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const stream_id = if (bidirectional) blk: {
            const id = self.next_stream_id_bidi;
            self.next_stream_id_bidi += 4; // Increment by 4 to maintain stream type
            break :blk id;
        } else blk: {
            const id = self.next_stream_id_uni;
            self.next_stream_id_uni += 4;
            break :blk id;
        };
        
        const stream_type: StreamType = if (bidirectional) .bidirectional_client else .unidirectional_client;
        
        const stream = try self.allocator.create(QUICStream);
        stream.* = QUICStream.init(self.allocator, stream_id, stream_type);
        stream.state = .open;
        
        // Apply gaming mode if enabled
        if (self.gaming_mode) {
            stream.setGamingMode(true);
        }
        
        try self.streams.put(stream_id, stream);
        
        return stream;
    }
    
    pub fn getStream(self: *Self, stream_id: StreamID) ?*QUICStream {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.streams.get(stream_id);
    }
    
    pub fn closeStream(self: *Self, stream_id: StreamID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.streams.fetchRemove(stream_id)) |removed| {
            removed.value.deinit();
            self.allocator.destroy(removed.value);
        }
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode = enabled;
        self.low_latency_mode = enabled;
        self.zero_rtt_enabled = enabled;
        
        // Apply to transport parameters
        self.local_transport_params.gaming_mode = enabled;
        self.local_transport_params.low_latency_mode = enabled;
        self.local_transport_params.zero_rtt_enabled = enabled;
        
        if (enabled) {
            // Aggressive settings for gaming
            self.local_transport_params.max_idle_timeout = 10000; // 10 seconds
            self.local_transport_params.max_ack_delay = 5; // 5ms
            self.local_transport_params.initial_max_data = 4194304; // 4MB
            self.local_transport_params.initial_max_streams_bidi = 1000;
        }
        
        // Apply to all streams
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.setGamingMode(enabled);
        }
    }
    
    pub fn updateRTT(self: *Self, latest_rtt: u64) void {
        self.rtt_latest = latest_rtt;
        self.min_rtt = @min(self.min_rtt, latest_rtt);
        
        if (self.rtt_smoothed == 0) {
            self.rtt_smoothed = latest_rtt;
            self.rtt_variance = latest_rtt / 2;
        } else {
            const rtt_diff = if (latest_rtt > self.rtt_smoothed) 
                latest_rtt - self.rtt_smoothed 
            else 
                self.rtt_smoothed - latest_rtt;
            
            self.rtt_variance = (3 * self.rtt_variance + rtt_diff) / 4;
            self.rtt_smoothed = (7 * self.rtt_smoothed + latest_rtt) / 8;
        }
    }
    
    pub fn getRTO(self: Self) u64 {
        const pto = self.rtt_smoothed + @max(4 * self.rtt_variance, 1000); // 1ms minimum
        return @max(pto, if (self.gaming_mode) 5000 else 20000); // 5ms for gaming, 20ms normally
    }
    
    fn sendInitialPacket(self: *Self) !void {
        // TODO: Implement Initial packet sending
        // This would involve:
        // 1. Creating Initial packet header
        // 2. Adding CRYPTO frame with ClientHello
        // 3. Padding packet to minimum size
        // 4. Encrypting packet
        // 5. Sending via UDP socket
        _ = self;
    }
    
    pub fn processPacket(self: *Self, packet_data: []const u8) !void {
        // TODO: Implement packet processing
        // This would involve:
        // 1. Parsing packet header
        // 2. Decrypting packet
        // 3. Processing frames
        // 4. Updating connection state
        // 5. Triggering ACKs if needed
        _ = self;
        _ = packet_data;
    }
    
    pub fn getPerformanceMetrics(self: *Self) QUICConnectionMetrics {
        return QUICConnectionMetrics{
            .packets_sent = self.packets_sent.load(.acquire),
            .packets_received = self.packets_received.load(.acquire),
            .bytes_sent = self.bytes_sent.load(.acquire),
            .bytes_received = self.bytes_received.load(.acquire),
            .packet_losses = self.packet_losses.load(.acquire),
            .rtt_latest = self.rtt_latest,
            .rtt_smoothed = self.rtt_smoothed,
            .min_rtt = self.min_rtt,
            .congestion_window = self.congestion_window,
            .bytes_in_flight = self.bytes_in_flight,
            .active_streams = @intCast(self.streams.count()),
            .gaming_mode = self.gaming_mode,
        };
    }
};

/// QUIC connection performance metrics
pub const QUICConnectionMetrics = struct {
    packets_sent: u64,
    packets_received: u64,
    bytes_sent: u64,
    bytes_received: u64,
    packet_losses: u32,
    rtt_latest: u64,
    rtt_smoothed: u64,
    min_rtt: u64,
    congestion_window: u64,
    bytes_in_flight: u64,
    active_streams: u32,
    gaming_mode: bool,
};

/// QUIC endpoint (server or client)
pub const QUICEndpoint = struct {
    connections: std.HashMap(u64, *QUICConnection), // Keyed by connection ID hash
    socket: *network.Socket,
    is_server: bool,
    
    // Gaming optimizations
    gaming_mode: bool = false,
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, socket: *network.Socket, is_server: bool) Self {
        return Self{
            .connections = std.HashMap(u64, *QUICConnection).init(allocator),
            .socket = socket,
            .is_server = is_server,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up connections
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }
    
    pub fn connect(self: *Self, remote_addr: network.SocketAddress) !*QUICConnection {
        if (self.is_server) return QUICError.ProtocolViolation;
        
        const conn = try self.allocator.create(QUICConnection);
        conn.* = try QUICConnection.initClient(self.allocator, self.socket.local_addr.?, remote_addr);
        
        if (self.gaming_mode) {
            conn.setGamingMode(true);
        }
        
        try conn.connect();
        
        const conn_hash = self.hashConnectionID(conn.local_connection_id);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.put(conn_hash, conn);
        
        return conn;
    }
    
    pub fn listen(self: *Self) !void {
        if (!self.is_server) return QUICError.ProtocolViolation;
        
        // Start listening for incoming packets
        // This would typically be done in a separate thread
    }
    
    pub fn processIncomingPacket(self: *Self, packet_data: []const u8, remote_addr: network.SocketAddress) !void {
        // Parse packet header to extract connection ID
        // Look up connection or create new one for server
        // Process packet in connection context
        _ = self;
        _ = packet_data;
        _ = remote_addr;
    }
    
    pub fn setGamingMode(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode = enabled;
        
        // Apply to all connections
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            entry.value_ptr.*.setGamingMode(enabled);
        }
        
        // Set socket gaming options
        self.socket.setGamingOptions(enabled);
    }
    
    fn hashConnectionID(self: Self, cid: ConnectionID) u64 {
        _ = self;
        return std.hash_map.hashString(cid.slice());
    }
};

/// Utility functions

/// Encode variable-length integer (RFC 9000 Section 16)
fn encodeVarint(value: u64, buffer: []u8) !usize {
    if (value < 64) {
        // Single byte encoding
        if (buffer.len < 1) return QUICError.BufferTooSmall;
        buffer[0] = @intCast(value);
        return 1;
    } else if (value < 16384) {
        // Two byte encoding
        if (buffer.len < 2) return QUICError.BufferTooSmall;
        const val = @as(u16, @intCast(value)) | 0x4000;
        std.mem.writeInt(u16, buffer[0..2], val, .big);
        return 2;
    } else if (value < 1073741824) {
        // Four byte encoding
        if (buffer.len < 4) return QUICError.BufferTooSmall;
        const val = @as(u32, @intCast(value)) | 0x80000000;
        std.mem.writeInt(u32, buffer[0..4], val, .big);
        return 4;
    } else {
        // Eight byte encoding
        if (buffer.len < 8) return QUICError.BufferTooSmall;
        const val = value | 0xC000000000000000;
        std.mem.writeInt(u64, buffer[0..8], val, .big);
        return 8;
    }
}

/// Decode variable-length integer
fn decodeVarint(buffer: []const u8) !struct { value: u64, bytes_read: usize } {
    if (buffer.len == 0) return QUICError.BufferTooSmall;
    
    const first_byte = buffer[0];
    const length_bits = (first_byte & 0xC0) >> 6;
    
    switch (length_bits) {
        0 => {
            // Single byte
            return .{ .value = first_byte & 0x3F, .bytes_read = 1 };
        },
        1 => {
            // Two bytes
            if (buffer.len < 2) return QUICError.BufferTooSmall;
            const val = std.mem.readInt(u16, buffer[0..2], .big);
            return .{ .value = val & 0x3FFF, .bytes_read = 2 };
        },
        2 => {
            // Four bytes
            if (buffer.len < 4) return QUICError.BufferTooSmall;
            const val = std.mem.readInt(u32, buffer[0..4], .big);
            return .{ .value = val & 0x3FFFFFFF, .bytes_read = 4 };
        },
        3 => {
            // Eight bytes
            if (buffer.len < 8) return QUICError.BufferTooSmall;
            const val = std.mem.readInt(u64, buffer[0..8], .big);
            return .{ .value = val & 0x3FFFFFFFFFFFFFFF, .bytes_read = 8 };
        },
    }
}

/// Encode packet number (variable length)
fn encodePacketNumber(pn: PacketNumber, buffer: []u8) !usize {
    // Simplified packet number encoding (should be optimized based on largest_acked)
    if (pn < 256) {
        if (buffer.len < 1) return QUICError.BufferTooSmall;
        buffer[0] = @intCast(pn);
        return 1;
    } else if (pn < 65536) {
        if (buffer.len < 2) return QUICError.BufferTooSmall;
        std.mem.writeInt(u16, buffer[0..2], @intCast(pn), .big);
        return 2;
    } else if (pn < 16777216) {
        if (buffer.len < 3) return QUICError.BufferTooSmall;
        buffer[0] = @intCast((pn >> 16) & 0xFF);
        buffer[1] = @intCast((pn >> 8) & 0xFF);
        buffer[2] = @intCast(pn & 0xFF);
        return 3;
    } else {
        if (buffer.len < 4) return QUICError.BufferTooSmall;
        std.mem.writeInt(u32, buffer[0..4], @intCast(pn), .big);
        return 4;
    }
}

// Tests
test "Connection ID operations" {
    const cid1 = ConnectionID.init(&[_]u8{ 1, 2, 3, 4 });
    const cid2 = ConnectionID.init(&[_]u8{ 1, 2, 3, 4 });
    const cid3 = ConnectionID.init(&[_]u8{ 5, 6, 7, 8 });
    
    try std.testing.expect(cid1.equal(cid2));
    try std.testing.expect(!cid1.equal(cid3));
    try std.testing.expect(cid1.len == 4);
    try std.testing.expect(std.mem.eql(u8, cid1.slice(), &[_]u8{ 1, 2, 3, 4 }));
}

test "Variable-length integer encoding/decoding" {
    var buffer: [8]u8 = undefined;
    
    // Test single byte
    const len1 = try encodeVarint(42, &buffer);
    try std.testing.expect(len1 == 1);
    try std.testing.expect(buffer[0] == 42);
    
    const decoded1 = try decodeVarint(buffer[0..len1]);
    try std.testing.expect(decoded1.value == 42);
    try std.testing.expect(decoded1.bytes_read == 1);
    
    // Test two bytes
    const len2 = try encodeVarint(1000, &buffer);
    try std.testing.expect(len2 == 2);
    
    const decoded2 = try decodeVarint(buffer[0..len2]);
    try std.testing.expect(decoded2.value == 1000);
    try std.testing.expect(decoded2.bytes_read == 2);
    
    // Test four bytes
    const len4 = try encodeVarint(100000, &buffer);
    try std.testing.expect(len4 == 4);
    
    const decoded4 = try decodeVarint(buffer[0..len4]);
    try std.testing.expect(decoded4.value == 100000);
    try std.testing.expect(decoded4.bytes_read == 4);
}

test "QUIC stream operations" {
    const allocator = std.testing.allocator;
    
    var stream = QUICStream.init(allocator, 0, .bidirectional_client);
    defer stream.deinit();
    
    stream.state = .open;
    
    // Test writing
    const test_data = "Hello, QUIC!";
    const written = try stream.write(test_data);
    try std.testing.expect(written == test_data.len);
    
    // Test reading (need to move data from send to recv buffer for test)
    try stream.recv_buffer.appendSlice(test_data);
    
    var read_buffer: [20]u8 = undefined;
    const read_bytes = try stream.read(&read_buffer);
    try std.testing.expect(read_bytes == test_data.len);
    try std.testing.expect(std.mem.eql(u8, read_buffer[0..read_bytes], test_data));
    
    // Test gaming mode
    stream.setGamingMode(true);
    try std.testing.expect(stream.low_latency);
    try std.testing.expect(stream.priority == 255);
}