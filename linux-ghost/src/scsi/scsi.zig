//! SCSI (Small Computer System Interface) Command Interface
//! Compatible with SCSI-2, SCSI-3, and USB Mass Storage BOT
//! Supports all major SCSI commands and error handling

const std = @import("std");
const block = @import("../block/block_device.zig");
const sync = @import("../kernel/sync.zig");
const memory = @import("../mm/memory.zig");

/// SCSI command operation codes
pub const ScsiOpCode = enum(u8) {
    // 6-byte commands
    TEST_UNIT_READY = 0x00,
    REQUEST_SENSE = 0x03,
    FORMAT_UNIT = 0x04,
    READ_6 = 0x08,
    WRITE_6 = 0x0A,
    SEEK_6 = 0x0B,
    INQUIRY = 0x12,
    MODE_SELECT_6 = 0x15,
    RESERVE = 0x16,
    RELEASE = 0x17,
    MODE_SENSE_6 = 0x1A,
    START_STOP_UNIT = 0x1B,
    SEND_DIAGNOSTIC = 0x1D,
    PREVENT_ALLOW_MEDIUM_REMOVAL = 0x1E,
    
    // 10-byte commands
    READ_CAPACITY_10 = 0x25,
    READ_10 = 0x28,
    WRITE_10 = 0x2A,
    SEEK_10 = 0x2B,
    WRITE_VERIFY_10 = 0x2E,
    VERIFY_10 = 0x2F,
    SEARCH_HIGH_10 = 0x30,
    SEARCH_EQUAL_10 = 0x31,
    SEARCH_LOW_10 = 0x32,
    SET_LIMITS_10 = 0x33,
    PRE_FETCH_10 = 0x34,
    SYNCHRONIZE_CACHE_10 = 0x35,
    LOCK_UNLOCK_CACHE_10 = 0x36,
    READ_DEFECT_DATA_10 = 0x37,
    MEDIUM_SCAN = 0x38,
    WRITE_LONG_10 = 0x3F,
    
    // 12-byte commands
    READ_12 = 0xA8,
    WRITE_12 = 0xAA,
    WRITE_VERIFY_12 = 0xAE,
    SEARCH_HIGH_12 = 0xB0,
    SEARCH_EQUAL_12 = 0xB1,
    SEARCH_LOW_12 = 0xB2,
    
    // 16-byte commands
    READ_16 = 0x88,
    WRITE_16 = 0x8A,
    WRITE_VERIFY_16 = 0x8E,
    SYNCHRONIZE_CACHE_16 = 0x91,
    READ_CAPACITY_16 = 0x9E,
    
    // Variable length commands
    VARIABLE_LENGTH_CDB = 0x7F,
    
    // Vendor specific range
    VENDOR_SPECIFIC_START = 0xC0,
    VENDOR_SPECIFIC_END = 0xFF,
};

/// SCSI status codes
pub const ScsiStatus = enum(u8) {
    GOOD = 0x00,
    CHECK_CONDITION = 0x02,
    CONDITION_MET = 0x04,
    BUSY = 0x08,
    INTERMEDIATE = 0x10,
    INTERMEDIATE_CONDITION_MET = 0x14,
    RESERVATION_CONFLICT = 0x18,
    COMMAND_TERMINATED = 0x22,
    TASK_SET_FULL = 0x28,
    ACA_ACTIVE = 0x30,
    TASK_ABORTED = 0x40,
};

/// SCSI sense keys
pub const SenseKey = enum(u8) {
    NO_SENSE = 0x00,
    RECOVERED_ERROR = 0x01,
    NOT_READY = 0x02,
    MEDIUM_ERROR = 0x03,
    HARDWARE_ERROR = 0x04,
    ILLEGAL_REQUEST = 0x05,
    UNIT_ATTENTION = 0x06,
    DATA_PROTECT = 0x07,
    BLANK_CHECK = 0x08,
    VENDOR_SPECIFIC = 0x09,
    COPY_ABORTED = 0x0A,
    ABORTED_COMMAND = 0x0B,
    VOLUME_OVERFLOW = 0x0D,
    MISCOMPARE = 0x0E,
};

/// SCSI device types
pub const DeviceType = enum(u8) {
    DIRECT_ACCESS = 0x00,
    SEQUENTIAL_ACCESS = 0x01,
    PRINTER = 0x02,
    PROCESSOR = 0x03,
    WRITE_ONCE = 0x04,
    CD_ROM = 0x05,
    SCANNER = 0x06,
    OPTICAL_MEMORY = 0x07,
    MEDIUM_CHANGER = 0x08,
    COMMUNICATIONS = 0x09,
    ENCLOSURE_SERVICES = 0x0D,
    SIMPLIFIED_DIRECT_ACCESS = 0x0E,
    OPTICAL_CARD_READER = 0x0F,
    BRIDGE_CONTROLLER = 0x10,
    OBJECT_STORAGE = 0x11,
    AUTOMATION_DRIVE_INTERFACE = 0x12,
    SECURITY_MANAGER = 0x13,
    SIMPLIFIED_MULTIMEDIA = 0x14,
    UNKNOWN = 0x1F,
};

/// SCSI command descriptor block (CDB)
pub const ScsiCdb = union(enum) {
    cdb6: [6]u8,
    cdb10: [10]u8,
    cdb12: [12]u8,
    cdb16: [16]u8,
    cdb32: [32]u8,
    
    pub fn getOpCode(self: *const ScsiCdb) u8 {
        return switch (self.*) {
            .cdb6 => |cdb| cdb[0],
            .cdb10 => |cdb| cdb[0],
            .cdb12 => |cdb| cdb[0],
            .cdb16 => |cdb| cdb[0],
            .cdb32 => |cdb| cdb[0],
        };
    }
    
    pub fn getLength(self: *const ScsiCdb) u8 {
        return switch (self.*) {
            .cdb6 => 6,
            .cdb10 => 10,
            .cdb12 => 12,
            .cdb16 => 16,
            .cdb32 => 32,
        };
    }
};

/// SCSI sense data structure
pub const SenseData = struct {
    response_code: u8,
    sense_key: SenseKey,
    additional_sense_code: u8,
    additional_sense_code_qualifier: u8,
    information: [4]u8,
    additional_sense_length: u8,
    command_specific_info: [4]u8,
    field_replaceable_unit_code: u8,
    sense_key_specific: [3]u8,
    additional_sense_bytes: [244]u8,
};

/// SCSI command structure
pub const ScsiCommand = struct {
    cdb: ScsiCdb,
    data_direction: DataDirection,
    data_buffer: ?[]u8 = null,
    data_length: u32 = 0,
    timeout_ms: u32 = 30000,
    
    // Command results
    status: ScsiStatus = .GOOD,
    sense_data: ?SenseData = null,
    actual_length: u32 = 0,
    
    // Command tracking
    tag: u32 = 0,
    completion: ?*const fn(*ScsiCommand) void = null,
    private_data: ?*anyopaque = null,
};

/// Data direction for SCSI commands
pub const DataDirection = enum(u8) {
    NONE = 0,
    FROM_DEVICE = 1,
    TO_DEVICE = 2,
    BIDIRECTIONAL = 3,
};

/// Standard INQUIRY data structure
pub const InquiryData = packed struct {
    device_type: u8,
    rmb: u8,
    version: u8,
    response_data_format: u8,
    additional_length: u8,
    sccs: u8,
    bque: u8,
    cmd_que: u8,
    vendor_id: [8]u8,
    product_id: [16]u8,
    product_revision: [4]u8,
    vendor_specific: [20]u8,
    reserved: [40]u8,
};

/// READ CAPACITY (10) data structure
pub const ReadCapacity10Data = packed struct {
    last_logical_block: u32,
    block_length: u32,
    
    pub fn getLastLba(self: *const ReadCapacity10Data) u32 {
        return std.mem.bigToNative(u32, self.last_logical_block);
    }
    
    pub fn getBlockSize(self: *const ReadCapacity10Data) u32 {
        return std.mem.bigToNative(u32, self.block_length);
    }
};

/// READ CAPACITY (16) data structure
pub const ReadCapacity16Data = packed struct {
    last_logical_block: u64,
    block_length: u32,
    protection_type: u8,
    logical_blocks_per_physical_block: u8,
    lowest_aligned_logical_block: u16,
    reserved: [16]u8,
    
    pub fn getLastLba(self: *const ReadCapacity16Data) u64 {
        return std.mem.bigToNative(u64, self.last_logical_block);
    }
    
    pub fn getBlockSize(self: *const ReadCapacity16Data) u32 {
        return std.mem.bigToNative(u32, self.block_length);
    }
};

/// SCSI device structure
pub const ScsiDevice = struct {
    device_type: DeviceType,
    vendor_id: [8]u8,
    product_id: [16]u8,
    revision: [4]u8,
    
    // Device capabilities
    supports_command_queuing: bool = false,
    supports_wide_bus: bool = false,
    supports_sync_negotiation: bool = false,
    supports_linked_commands: bool = false,
    
    // Device geometry
    logical_block_size: u32 = 512,
    max_lba: u64 = 0,
    
    // Command execution
    execute_command: *const fn(*ScsiDevice, *ScsiCommand) error{DeviceError, InvalidCommand, Timeout}!void,
    
    // Private data
    private_data: ?*anyopaque = null,
    
    const Self = @This();
    
    pub fn init(device_type: DeviceType, execute_fn: *const fn(*ScsiDevice, *ScsiCommand) error{DeviceError, InvalidCommand, Timeout}!void) Self {
        return Self{
            .device_type = device_type,
            .vendor_id = [_]u8{0} ** 8,
            .product_id = [_]u8{0} ** 16,
            .revision = [_]u8{0} ** 4,
            .execute_command = execute_fn,
        };
    }
    
    pub fn inquiry(self: *Self, allocator: std.mem.Allocator) !InquiryData {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{ @intFromEnum(ScsiOpCode.INQUIRY), 0, 0, 0, @sizeOf(InquiryData), 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = @sizeOf(InquiryData),
        };
        
        var data_buffer = try allocator.alloc(u8, @sizeOf(InquiryData));
        defer allocator.free(data_buffer);
        command.data_buffer = data_buffer;
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
        
        return @as(*InquiryData, @ptrCast(@alignCast(data_buffer.ptr))).*;
    }
    
    pub fn testUnitReady(self: *Self) !void {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{ @intFromEnum(ScsiOpCode.TEST_UNIT_READY), 0, 0, 0, 0, 0 } },
            .data_direction = .NONE,
        };
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
    }
    
    pub fn readCapacity10(self: *Self, allocator: std.mem.Allocator) !ReadCapacity10Data {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{ @intFromEnum(ScsiOpCode.READ_CAPACITY_10), 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = @sizeOf(ReadCapacity10Data),
        };
        
        var data_buffer = try allocator.alloc(u8, @sizeOf(ReadCapacity10Data));
        defer allocator.free(data_buffer);
        command.data_buffer = data_buffer;
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
        
        return @as(*ReadCapacity10Data, @ptrCast(@alignCast(data_buffer.ptr))).*;
    }
    
    pub fn readCapacity16(self: *Self, allocator: std.mem.Allocator) !ReadCapacity16Data {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb16 = [_]u8{ @intFromEnum(ScsiOpCode.READ_CAPACITY_16), 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, @sizeOf(ReadCapacity16Data), 0, 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = @sizeOf(ReadCapacity16Data),
        };
        
        var data_buffer = try allocator.alloc(u8, @sizeOf(ReadCapacity16Data));
        defer allocator.free(data_buffer);
        command.data_buffer = data_buffer;
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
        
        return @as(*ReadCapacity16Data, @ptrCast(@alignCast(data_buffer.ptr))).*;
    }
    
    pub fn read10(self: *Self, lba: u32, transfer_length: u16, buffer: []u8) !void {
        if (buffer.len < transfer_length * self.logical_block_size) {
            return error.InvalidCommand;
        }
        
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{
                @intFromEnum(ScsiOpCode.READ_10),
                0,
                @intCast((lba >> 24) & 0xFF),
                @intCast((lba >> 16) & 0xFF),
                @intCast((lba >> 8) & 0xFF),
                @intCast(lba & 0xFF),
                0,
                @intCast((transfer_length >> 8) & 0xFF),
                @intCast(transfer_length & 0xFF),
                0,
            } },
            .data_direction = .FROM_DEVICE,
            .data_buffer = buffer,
            .data_length = transfer_length * self.logical_block_size,
        };
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
    }
    
    pub fn write10(self: *Self, lba: u32, transfer_length: u16, buffer: []const u8) !void {
        if (buffer.len < transfer_length * self.logical_block_size) {
            return error.InvalidCommand;
        }
        
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{
                @intFromEnum(ScsiOpCode.WRITE_10),
                0,
                @intCast((lba >> 24) & 0xFF),
                @intCast((lba >> 16) & 0xFF),
                @intCast((lba >> 8) & 0xFF),
                @intCast(lba & 0xFF),
                0,
                @intCast((transfer_length >> 8) & 0xFF),
                @intCast(transfer_length & 0xFF),
                0,
            } },
            .data_direction = .TO_DEVICE,
            .data_buffer = @constCast(buffer),
            .data_length = transfer_length * self.logical_block_size,
        };
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
    }
    
    pub fn synchronizeCache(self: *Self) !void {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{ @intFromEnum(ScsiOpCode.SYNCHRONIZE_CACHE_10), 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .data_direction = .NONE,
        };
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
    }
    
    pub fn startStopUnit(self: *Self, start: bool, load_eject: bool) !void {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{
                @intFromEnum(ScsiOpCode.START_STOP_UNIT),
                0,
                0,
                0,
                @as(u8, if (start) 1 else 0) | @as(u8, if (load_eject) 2 else 0),
                0,
            } },
            .data_direction = .NONE,
        };
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
    }
    
    pub fn requestSense(self: *Self, allocator: std.mem.Allocator) !SenseData {
        var command = ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{ @intFromEnum(ScsiOpCode.REQUEST_SENSE), 0, 0, 0, @sizeOf(SenseData), 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = @sizeOf(SenseData),
        };
        
        var data_buffer = try allocator.alloc(u8, @sizeOf(SenseData));
        defer allocator.free(data_buffer);
        command.data_buffer = data_buffer;
        
        try self.execute_command(self, &command);
        
        if (command.status != .GOOD) {
            return error.DeviceError;
        }
        
        return @as(*SenseData, @ptrCast(@alignCast(data_buffer.ptr))).*;
    }
};

/// SCSI error handling
pub const ScsiError = error{
    DeviceError,
    InvalidCommand,
    Timeout,
    NotReady,
    MediumError,
    HardwareError,
    IllegalRequest,
    UnitAttention,
    DataProtect,
    AbortedCommand,
    UnknownError,
};

/// Convert SCSI sense key to error
pub fn senseKeyToError(sense_key: SenseKey) ScsiError {
    return switch (sense_key) {
        .NOT_READY => ScsiError.NotReady,
        .MEDIUM_ERROR => ScsiError.MediumError,
        .HARDWARE_ERROR => ScsiError.HardwareError,
        .ILLEGAL_REQUEST => ScsiError.IllegalRequest,
        .UNIT_ATTENTION => ScsiError.UnitAttention,
        .DATA_PROTECT => ScsiError.DataProtect,
        .ABORTED_COMMAND => ScsiError.AbortedCommand,
        else => ScsiError.UnknownError,
    };
}

/// SCSI command builder helpers
pub const ScsiCommandBuilder = struct {
    pub fn testUnitReady() ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{ @intFromEnum(ScsiOpCode.TEST_UNIT_READY), 0, 0, 0, 0, 0 } },
            .data_direction = .NONE,
        };
    }
    
    pub fn inquiry(allocation_length: u8) ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb6 = [_]u8{ @intFromEnum(ScsiOpCode.INQUIRY), 0, 0, 0, allocation_length, 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = allocation_length,
        };
    }
    
    pub fn readCapacity10() ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{ @intFromEnum(ScsiOpCode.READ_CAPACITY_10), 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .data_direction = .FROM_DEVICE,
            .data_length = @sizeOf(ReadCapacity10Data),
        };
    }
    
    pub fn read10(lba: u32, transfer_length: u16) ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{
                @intFromEnum(ScsiOpCode.READ_10),
                0,
                @intCast((lba >> 24) & 0xFF),
                @intCast((lba >> 16) & 0xFF),
                @intCast((lba >> 8) & 0xFF),
                @intCast(lba & 0xFF),
                0,
                @intCast((transfer_length >> 8) & 0xFF),
                @intCast(transfer_length & 0xFF),
                0,
            } },
            .data_direction = .FROM_DEVICE,
            .data_length = transfer_length * 512, // Assume 512-byte blocks
        };
    }
    
    pub fn write10(lba: u32, transfer_length: u16) ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{
                @intFromEnum(ScsiOpCode.WRITE_10),
                0,
                @intCast((lba >> 24) & 0xFF),
                @intCast((lba >> 16) & 0xFF),
                @intCast((lba >> 8) & 0xFF),
                @intCast(lba & 0xFF),
                0,
                @intCast((transfer_length >> 8) & 0xFF),
                @intCast(transfer_length & 0xFF),
                0,
            } },
            .data_direction = .TO_DEVICE,
            .data_length = transfer_length * 512, // Assume 512-byte blocks
        };
    }
    
    pub fn synchronizeCache() ScsiCommand {
        return ScsiCommand{
            .cdb = ScsiCdb{ .cdb10 = [_]u8{ @intFromEnum(ScsiOpCode.SYNCHRONIZE_CACHE_10), 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .data_direction = .NONE,
        };
    }
};

/// SCSI utility functions
pub const ScsiUtils = struct {
    pub fn isValidOpCode(opcode: u8) bool {
        return switch (opcode) {
            0x00...0x1F, // 6-byte commands
            0x20...0x5F, // 10-byte commands
            0x80...0x9F, // 16-byte commands
            0xA0...0xBF, // 12-byte commands
            0xC0...0xFF, // Vendor specific
            => true,
            else => false,
        };
    }
    
    pub fn getCdbLength(opcode: u8) u8 {
        return switch (opcode) {
            0x00...0x1F => 6,
            0x20...0x5F => 10,
            0x80...0x9F => 16,
            0xA0...0xBF => 12,
            0xC0...0xFF => 6, // Vendor specific, assume 6-byte
            else => 0,
        };
    }
    
    pub fn getCommandName(opcode: u8) []const u8 {
        return switch (opcode) {
            0x00 => "TEST_UNIT_READY",
            0x03 => "REQUEST_SENSE",
            0x04 => "FORMAT_UNIT",
            0x08 => "READ_6",
            0x0A => "WRITE_6",
            0x12 => "INQUIRY",
            0x1A => "MODE_SENSE_6",
            0x1B => "START_STOP_UNIT",
            0x25 => "READ_CAPACITY_10",
            0x28 => "READ_10",
            0x2A => "WRITE_10",
            0x35 => "SYNCHRONIZE_CACHE_10",
            0x88 => "READ_16",
            0x8A => "WRITE_16",
            0x9E => "READ_CAPACITY_16",
            0xA8 => "READ_12",
            0xAA => "WRITE_12",
            else => "UNKNOWN",
        };
    }
    
    pub fn formatSenseData(sense_data: *const SenseData) []const u8 {
        // This would return a formatted string of the sense data
        // For now, just return the sense key description
        return switch (sense_data.sense_key) {
            .NO_SENSE => "No Sense",
            .RECOVERED_ERROR => "Recovered Error",
            .NOT_READY => "Not Ready",
            .MEDIUM_ERROR => "Medium Error",
            .HARDWARE_ERROR => "Hardware Error",
            .ILLEGAL_REQUEST => "Illegal Request",
            .UNIT_ATTENTION => "Unit Attention",
            .DATA_PROTECT => "Data Protect",
            .BLANK_CHECK => "Blank Check",
            .VENDOR_SPECIFIC => "Vendor Specific",
            .COPY_ABORTED => "Copy Aborted",
            .ABORTED_COMMAND => "Aborted Command",
            .VOLUME_OVERFLOW => "Volume Overflow",
            .MISCOMPARE => "Miscompare",
        };
    }
};

// Common SCSI constants
pub const SCSI_MAX_LOGICAL_UNITS = 8;
pub const SCSI_MAX_TARGETS = 16;
pub const SCSI_MAX_COMMAND_SIZE = 32;
pub const SCSI_DEFAULT_TIMEOUT_MS = 30000;
pub const SCSI_SENSE_BUFFER_SIZE = 252;

// SCSI version constants
pub const SCSI_VERSION_1 = 0x01;
pub const SCSI_VERSION_2 = 0x02;
pub const SCSI_VERSION_3 = 0x03;
pub const SCSI_VERSION_SPC = 0x03;
pub const SCSI_VERSION_SPC2 = 0x04;
pub const SCSI_VERSION_SPC3 = 0x05;