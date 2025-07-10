//! USB Mass Storage Driver for Ghost Kernel
//! Implements USB Mass Storage Bulk-Only Transport (BOT)
//! Supports SCSI command set for USB drives, SSDs, and other storage devices

const std = @import("std");
const usb = @import("usb_core.zig");
const block = @import("../../block/block_device.zig");
const scsi = @import("../../scsi/scsi.zig");
const memory = @import("../../mm/memory.zig");
const sync = @import("../../kernel/sync.zig");

/// Mass Storage subclass codes
pub const MassStorageSubclass = enum(u8) {
    rbc = 0x01,              // Reduced Block Commands (flash devices)
    sff8020i = 0x02,         // CD/DVD devices
    qic157 = 0x03,           // Tape devices
    ufi = 0x04,              // Floppy devices
    sff8070i = 0x05,         // Floppy devices
    scsi = 0x06,             // SCSI transparent command set
    lsd_fs = 0x07,           // LSD FS
    ieee1667 = 0x08,         // IEEE 1667
    vendor_specific = 0xFF,
};

/// Mass Storage protocol codes
pub const MassStorageProtocol = enum(u8) {
    cbi_cdb = 0x00,          // Control/Bulk/Interrupt with CDB
    cbi_no_cdb = 0x01,       // Control/Bulk/Interrupt without CDB
    bulk_only = 0x50,        // Bulk-Only Transport (BOT)
    uas = 0x62,              // USB Attached SCSI
    vendor_specific = 0xFF,
};

/// Mass Storage class-specific requests
pub const MassStorageRequest = enum(u8) {
    get_max_lun = 0xFE,      // Get maximum logical unit number
    bulk_reset = 0xFF,       // Bulk-Only Mass Storage Reset
};

/// Command Block Wrapper (CBW) for Bulk-Only Transport
pub const CommandBlockWrapper = packed struct {
    signature: u32,          // dCBWSignature = 0x43425355 ("USBC")
    tag: u32,                // dCBWTag - unique per command
    transfer_length: u32,    // dCBWDataTransferLength
    flags: u8,               // bmCBWFlags - bit 7: direction (0=out, 1=in)
    lun: u8,                 // bCBWLUN - target logical unit
    cb_length: u8,           // bCBWCBLength - command block length (1-16)
    cb: [16]u8,              // CBWCB - command block (SCSI command)
    
    pub const SIGNATURE: u32 = 0x43425355; // "USBC"
    pub const FLAGS_DATA_IN: u8 = 0x80;
    pub const FLAGS_DATA_OUT: u8 = 0x00;
};

/// Command Status Wrapper (CSW) for Bulk-Only Transport
pub const CommandStatusWrapper = packed struct {
    signature: u32,          // dCSWSignature = 0x53425355 ("USBS")
    tag: u32,                // dCSWTag - must match CBW tag
    residue: u32,            // dCSWDataResidue - difference between expected and actual
    status: u8,              // bCSWStatus - command status
    
    pub const SIGNATURE: u32 = 0x53425355; // "USBS"
    pub const STATUS_PASSED: u8 = 0x00;
    pub const STATUS_FAILED: u8 = 0x01;
    pub const STATUS_PHASE_ERROR: u8 = 0x02;
};

/// USB Mass Storage device
pub const MassStorageDevice = struct {
    usb_device: *usb.USBDevice,
    interface: *usb.Interface,
    
    // Device properties
    subclass: MassStorageSubclass,
    protocol: MassStorageProtocol,
    max_lun: u8 = 0,
    
    // Endpoints
    bulk_in: *usb.Endpoint,
    bulk_out: *usb.Endpoint,
    interrupt: ?*usb.Endpoint = null,
    
    // Command state
    next_tag: std.atomic.Value(u32),
    
    // Logical units (SCSI targets)
    luns: []LogicalUnit,
    
    // Performance optimization
    use_uas: bool = false,           // USB Attached SCSI
    supports_streams: bool = false,   // USB 3.0 streams
    max_transfer_size: usize = 65536, // Maximum transfer size
    
    // Statistics
    commands_sent: std.atomic.Value(u64),
    commands_completed: std.atomic.Value(u64),
    bytes_read: std.atomic.Value(u64),
    bytes_written: std.atomic.Value(u64),
    
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *usb.USBDevice, interface: *usb.Interface) !Self {
        const subclass = @as(MassStorageSubclass, @enumFromInt(interface.descriptor.interface_subclass));
        const protocol = @as(MassStorageProtocol, @enumFromInt(interface.descriptor.interface_protocol));
        
        // Find bulk endpoints
        var bulk_in: ?*usb.Endpoint = null;
        var bulk_out: ?*usb.Endpoint = null;
        var interrupt: ?*usb.Endpoint = null;
        
        for (interface.endpoints.items) |*endpoint| {
            switch (endpoint.descriptor.getTransferType()) {
                .bulk => {
                    if (endpoint.descriptor.getDirection() == .in) {
                        bulk_in = endpoint;
                    } else {
                        bulk_out = endpoint;
                    }
                },
                .interrupt => interrupt = endpoint,
                else => {},
            }
        }
        
        if (bulk_in == null or bulk_out == null) {
            return error.NoBulkEndpoints;
        }
        
        return Self{
            .usb_device = device,
            .interface = interface,
            .subclass = subclass,
            .protocol = protocol,
            .bulk_in = bulk_in.?,
            .bulk_out = bulk_out.?,
            .interrupt = interrupt,
            .next_tag = std.atomic.Value(u32).init(1),
            .luns = &[_]LogicalUnit{},
            .commands_sent = std.atomic.Value(u64).init(0),
            .commands_completed = std.atomic.Value(u64).init(0),
            .bytes_read = std.atomic.Value(u64).init(0),
            .bytes_written = std.atomic.Value(u64).init(0),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.luns) |*lun| {
            lun.deinit();
        }
        self.allocator.free(self.luns);
    }
    
    pub fn start(self: *Self) !void {
        // Get maximum LUN
        try self.getMaxLun();
        
        // Initialize logical units
        self.luns = try self.allocator.alloc(LogicalUnit, self.max_lun + 1);
        for (self.luns, 0..) |*lun, i| {
            lun.* = try LogicalUnit.init(self.allocator, self, @intCast(i));
        }
        
        // Initialize each LUN
        for (self.luns) |*lun| {
            try lun.initialize();
        }
        
        // Check for USB 3.0 features
        if (self.usb_device.speed == .super or self.usb_device.speed == .super_plus) {
            // TODO: Check for stream support
            self.max_transfer_size = 1024 * 1024; // 1MB for USB 3.0
        }
    }
    
    pub fn stop(self: *Self) void {
        _ = self;
    }
    
    fn getMaxLun(self: *Self) !void {
        if (self.protocol != .bulk_only) {
            self.max_lun = 0;
            return;
        }
        
        var max_lun: [1]u8 = undefined;
        
        var setup = usb.SetupPacket{
            .request_type = 0xA1, // Device to host, class, interface
            .request = @intFromEnum(MassStorageRequest.get_max_lun),
            .value = 0,
            .index = self.interface.descriptor.interface_number,
            .length = 1,
        };
        
        self.usb_device.controlTransfer(&setup, &max_lun) catch {
            // Some devices don't support this command
            self.max_lun = 0;
            return;
        };
        
        self.max_lun = max_lun[0];
    }
    
    pub fn resetBulkOnly(self: *Self) !void {
        if (self.protocol != .bulk_only) return;
        
        var setup = usb.SetupPacket{
            .request_type = 0x21, // Host to device, class, interface
            .request = @intFromEnum(MassStorageRequest.bulk_reset),
            .value = 0,
            .index = self.interface.descriptor.interface_number,
            .length = 0,
        };
        
        try self.usb_device.controlTransfer(&setup, &[_]u8{});
    }
    
    pub fn sendCommand(self: *Self, lun: u8, command: []const u8, data_direction: scsi.DataDirection, buffer: []u8) !usize {
        if (lun > self.max_lun) return error.InvalidLun;
        
        switch (self.protocol) {
            .bulk_only => return try self.sendBulkOnlyCommand(lun, command, data_direction, buffer),
            .uas => return try self.sendUASCommand(lun, command, data_direction, buffer),
            else => return error.UnsupportedProtocol,
        }
    }
    
    fn sendBulkOnlyCommand(self: *Self, lun: u8, command: []const u8, data_direction: scsi.DataDirection, buffer: []u8) !usize {
        if (command.len > 16) return error.CommandTooLong;
        
        const tag = self.next_tag.fetchAdd(1, .monotonic);
        
        // Build CBW
        var cbw = CommandBlockWrapper{
            .signature = CommandBlockWrapper.SIGNATURE,
            .tag = tag,
            .transfer_length = @intCast(buffer.len),
            .flags = if (data_direction == .from_device) CommandBlockWrapper.FLAGS_DATA_IN else CommandBlockWrapper.FLAGS_DATA_OUT,
            .lun = lun,
            .cb_length = @intCast(command.len),
            .cb = [_]u8{0} ** 16,
        };
        
        @memcpy(cbw.cb[0..command.len], command);
        
        // Send CBW
        var cbw_urb = usb.URB{
            .device = self.usb_device,
            .endpoint = self.bulk_out.descriptor.endpoint_address,
            .transfer_type = .bulk,
            .direction = .out,
            .buffer = std.mem.asBytes(&cbw),
            .gaming_device = false,
        };
        
        try self.usb_device.submitTransfer(&cbw_urb);
        _ = self.commands_sent.fetchAdd(1, .release);
        
        // Data phase (if any)
        var actual_length: usize = 0;
        if (buffer.len > 0) {
            var data_urb = usb.URB{
                .device = self.usb_device,
                .endpoint = if (data_direction == .from_device) self.bulk_in.descriptor.endpoint_address else self.bulk_out.descriptor.endpoint_address,
                .transfer_type = .bulk,
                .direction = if (data_direction == .from_device) .in else .out,
                .buffer = buffer,
                .gaming_device = false,
            };
            
            try self.usb_device.submitTransfer(&data_urb);
            actual_length = data_urb.actual_length;
            
            // Update statistics
            if (data_direction == .from_device) {
                _ = self.bytes_read.fetchAdd(actual_length, .release);
            } else {
                _ = self.bytes_written.fetchAdd(actual_length, .release);
            }
        }
        
        // Receive CSW
        var csw: CommandStatusWrapper = undefined;
        var csw_urb = usb.URB{
            .device = self.usb_device,
            .endpoint = self.bulk_in.descriptor.endpoint_address,
            .transfer_type = .bulk,
            .direction = .in,
            .buffer = std.mem.asBytes(&csw),
            .gaming_device = false,
        };
        
        try self.usb_device.submitTransfer(&csw_urb);
        
        // Validate CSW
        if (csw.signature != CommandStatusWrapper.SIGNATURE) {
            return error.InvalidCSWSignature;
        }
        
        if (csw.tag != tag) {
            return error.CSWTagMismatch;
        }
        
        if (csw.status != CommandStatusWrapper.STATUS_PASSED) {
            return error.CommandFailed;
        }
        
        _ = self.commands_completed.fetchAdd(1, .release);
        
        return actual_length - csw.residue;
    }
    
    fn sendUASCommand(self: *Self, lun: u8, command: []const u8, data_direction: scsi.DataDirection, buffer: []u8) !usize {
        // TODO: Implement USB Attached SCSI protocol
        _ = self;
        _ = lun;
        _ = command;
        _ = data_direction;
        _ = buffer;
        return error.NotImplemented;
    }
    
    pub fn getPerformanceMetrics(self: *Self) MassStoragePerformanceMetrics {
        const commands_sent = self.commands_sent.load(.acquire);
        const commands_completed = self.commands_completed.load(.acquire);
        
        return MassStoragePerformanceMetrics{
            .commands_sent = commands_sent,
            .commands_completed = commands_completed,
            .commands_pending = commands_sent - commands_completed,
            .bytes_read = self.bytes_read.load(.acquire),
            .bytes_written = self.bytes_written.load(.acquire),
            .protocol = self.protocol,
            .max_lun = self.max_lun,
        };
    }
};

/// Logical Unit (SCSI target)
pub const LogicalUnit = struct {
    device: *MassStorageDevice,
    lun: u8,
    
    // Device information
    vendor_id: [8]u8 = [_]u8{' '} ** 8,
    product_id: [16]u8 = [_]u8{' '} ** 16,
    product_rev: [4]u8 = [_]u8{' '} ** 4,
    
    // Device properties
    device_type: scsi.DeviceType = .direct_access,
    removable: bool = false,
    write_protected: bool = false,
    
    // Capacity
    block_size: u32 = 512,
    total_blocks: u64 = 0,
    
    // Block device registration
    block_device: ?*block.BlockDevice = null,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: *MassStorageDevice, lun: u8) !Self {
        return Self{
            .device = device,
            .lun = lun,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.block_device) |blk| {
            block.unregisterDevice(blk);
            self.allocator.destroy(blk);
        }
    }
    
    pub fn initialize(self: *Self) !void {
        // Send INQUIRY command
        try self.inquiry();
        
        // Test unit ready
        try self.testUnitReady();
        
        // Read capacity
        try self.readCapacity();
        
        // Register as block device
        try self.registerBlockDevice();
    }
    
    fn inquiry(self: *Self) !void {
        var inquiry_cmd = scsi.InquiryCommand{
            .opcode = scsi.OPCODE_INQUIRY,
            .evpd = 0,
            .page_code = 0,
            .allocation_length = @byteSwap(@as(u16, @sizeOf(scsi.InquiryData))),
            .control = 0,
        };
        
        var inquiry_data: scsi.InquiryData = undefined;
        const len = try self.device.sendCommand(
            self.lun,
            std.mem.asBytes(&inquiry_cmd)[0..6],
            .from_device,
            std.mem.asBytes(&inquiry_data),
        );
        
        if (len < @sizeOf(scsi.InquiryData)) {
            return error.InquiryFailed;
        }
        
        // Extract device information
        self.device_type = @enumFromInt(inquiry_data.peripheral_device_type);
        self.removable = (inquiry_data.rmb & 0x80) != 0;
        
        @memcpy(&self.vendor_id, &inquiry_data.vendor_id);
        @memcpy(&self.product_id, &inquiry_data.product_id);
        @memcpy(&self.product_rev, &inquiry_data.product_rev);
    }
    
    fn testUnitReady(self: *Self) !void {
        const tur_cmd = [_]u8{ scsi.OPCODE_TEST_UNIT_READY, 0, 0, 0, 0, 0 };
        
        // Retry a few times as device may need time to spin up
        var retries: u8 = 5;
        while (retries > 0) : (retries -= 1) {
            self.device.sendCommand(self.lun, &tur_cmd, .none, &[_]u8{}) catch |err| {
                if (retries == 1) return err;
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            break;
        }
    }
    
    fn readCapacity(self: *Self) !void {
        // Try READ CAPACITY(16) first for large devices
        var read_cap16_cmd = [_]u8{
            scsi.OPCODE_SERVICE_ACTION_IN,
            0x10, // SERVICE ACTION(16)
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 32, // Allocation length
            0, 0,
        };
        
        var cap16_data: scsi.ReadCapacity16Data = undefined;
        self.device.sendCommand(
            self.lun,
            &read_cap16_cmd,
            .from_device,
            std.mem.asBytes(&cap16_data),
        ) catch {
            // Fall back to READ CAPACITY(10)
            var read_cap10_cmd = [_]u8{
                scsi.OPCODE_READ_CAPACITY,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            };
            
            var cap10_data: scsi.ReadCapacity10Data = undefined;
            const len = try self.device.sendCommand(
                self.lun,
                &read_cap10_cmd,
                .from_device,
                std.mem.asBytes(&cap10_data),
            );
            
            if (len < @sizeOf(scsi.ReadCapacity10Data)) {
                return error.ReadCapacityFailed;
            }
            
            self.total_blocks = @byteSwap(cap10_data.last_lba) + 1;
            self.block_size = @byteSwap(cap10_data.block_size);
            return;
        };
        
        self.total_blocks = @byteSwap(cap16_data.last_lba) + 1;
        self.block_size = @byteSwap(cap16_data.block_size);
    }
    
    fn registerBlockDevice(self: *Self) !void {
        const blk = try self.allocator.create(block.BlockDevice);
        
        // Create device name
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "usb-storage-{d}-{d}", .{ self.device.usb_device.address, self.lun });
        
        blk.* = block.BlockDevice{
            .name = try self.allocator.dupe(u8, name),
            .device_type = .disk,
            .block_size = self.block_size,
            .total_blocks = self.total_blocks,
            .removable = self.removable,
            .read_only = self.write_protected,
            .ops = &mass_storage_block_ops,
            .private_data = self,
            .allocator = self.allocator,
        };
        
        try block.registerDevice(blk);
        self.block_device = blk;
    }
    
    pub fn readBlocks(self: *Self, start_block: u64, num_blocks: u32, buffer: []u8) !void {
        const expected_size = num_blocks * self.block_size;
        if (buffer.len < expected_size) return error.BufferTooSmall;
        
        // Use READ(16) for large block addresses
        if (start_block > 0xFFFFFFFF or num_blocks > 0xFFFF) {
            var read16_cmd = scsi.Read16Command{
                .opcode = scsi.OPCODE_READ_16,
                .flags = 0,
                .lba = @byteSwap(start_block),
                .transfer_length = @byteSwap(num_blocks),
                .group_number = 0,
                .control = 0,
            };
            
            const len = try self.device.sendCommand(
                self.lun,
                std.mem.asBytes(&read16_cmd),
                .from_device,
                buffer[0..expected_size],
            );
            
            if (len != expected_size) {
                return error.IncompleteRead;
            }
        } else {
            // Use READ(10) for smaller addresses
            var read10_cmd = scsi.Read10Command{
                .opcode = scsi.OPCODE_READ_10,
                .flags = 0,
                .lba = @byteSwap(@as(u32, @intCast(start_block))),
                .group_number = 0,
                .transfer_length = @byteSwap(@as(u16, @intCast(num_blocks))),
                .control = 0,
            };
            
            const len = try self.device.sendCommand(
                self.lun,
                std.mem.asBytes(&read10_cmd),
                .from_device,
                buffer[0..expected_size],
            );
            
            if (len != expected_size) {
                return error.IncompleteRead;
            }
        }
    }
    
    pub fn writeBlocks(self: *Self, start_block: u64, num_blocks: u32, buffer: []const u8) !void {
        if (self.write_protected) return error.WriteProtected;
        
        const expected_size = num_blocks * self.block_size;
        if (buffer.len < expected_size) return error.BufferTooSmall;
        
        // Use WRITE(16) for large block addresses
        if (start_block > 0xFFFFFFFF or num_blocks > 0xFFFF) {
            var write16_cmd = scsi.Write16Command{
                .opcode = scsi.OPCODE_WRITE_16,
                .flags = 0,
                .lba = @byteSwap(start_block),
                .transfer_length = @byteSwap(num_blocks),
                .group_number = 0,
                .control = 0,
            };
            
            var write_buffer = try self.allocator.alloc(u8, expected_size);
            defer self.allocator.free(write_buffer);
            @memcpy(write_buffer, buffer[0..expected_size]);
            
            const len = try self.device.sendCommand(
                self.lun,
                std.mem.asBytes(&write16_cmd),
                .to_device,
                write_buffer,
            );
            
            if (len != expected_size) {
                return error.IncompleteWrite;
            }
        } else {
            // Use WRITE(10) for smaller addresses
            var write10_cmd = scsi.Write10Command{
                .opcode = scsi.OPCODE_WRITE_10,
                .flags = 0,
                .lba = @byteSwap(@as(u32, @intCast(start_block))),
                .group_number = 0,
                .transfer_length = @byteSwap(@as(u16, @intCast(num_blocks))),
                .control = 0,
            };
            
            var write_buffer = try self.allocator.alloc(u8, expected_size);
            defer self.allocator.free(write_buffer);
            @memcpy(write_buffer, buffer[0..expected_size]);
            
            const len = try self.device.sendCommand(
                self.lun,
                std.mem.asBytes(&write10_cmd),
                .to_device,
                write_buffer,
            );
            
            if (len != expected_size) {
                return error.IncompleteWrite;
            }
        }
    }
    
    pub fn flush(self: *Self) !void {
        const sync_cache_cmd = [_]u8{
            scsi.OPCODE_SYNCHRONIZE_CACHE,
            0, 0, 0, 0, 0, 0, 0, 0, 0,
        };
        
        _ = try self.device.sendCommand(
            self.lun,
            &sync_cache_cmd,
            .none,
            &[_]u8{},
        );
    }
};

/// Mass storage performance metrics
pub const MassStoragePerformanceMetrics = struct {
    commands_sent: u64,
    commands_completed: u64,
    commands_pending: u64,
    bytes_read: u64,
    bytes_written: u64,
    protocol: MassStorageProtocol,
    max_lun: u8,
};

/// Block device operations for mass storage
const mass_storage_block_ops = block.BlockDeviceOps{
    .read = massStorageRead,
    .write = massStorageWrite,
    .flush = massStorageFlush,
    .discard = null,
    .get_geometry = massStorageGetGeometry,
};

fn massStorageRead(dev: *block.BlockDevice, start_block: u64, num_blocks: u32, buffer: []u8) !void {
    const lun = @as(*LogicalUnit, @ptrCast(@alignCast(dev.private_data.?)));
    try lun.readBlocks(start_block, num_blocks, buffer);
}

fn massStorageWrite(dev: *block.BlockDevice, start_block: u64, num_blocks: u32, buffer: []const u8) !void {
    const lun = @as(*LogicalUnit, @ptrCast(@alignCast(dev.private_data.?)));
    try lun.writeBlocks(start_block, num_blocks, buffer);
}

fn massStorageFlush(dev: *block.BlockDevice) !void {
    const lun = @as(*LogicalUnit, @ptrCast(@alignCast(dev.private_data.?)));
    try lun.flush();
}

fn massStorageGetGeometry(dev: *block.BlockDevice) block.BlockDeviceGeometry {
    const lun = @as(*LogicalUnit, @ptrCast(@alignCast(dev.private_data.?)));
    
    // Estimate geometry for compatibility
    const total_sectors = lun.total_blocks;
    const sectors_per_track: u32 = 63;
    const heads: u32 = 255;
    const cylinders: u32 = @intCast(@min(total_sectors / (sectors_per_track * heads), 65535));
    
    return block.BlockDeviceGeometry{
        .cylinders = cylinders,
        .heads = heads,
        .sectors_per_track = sectors_per_track,
        .start = 0,
    };
}

/// USB Mass Storage driver
pub const usb_mass_storage_driver = usb.USBDriver{
    .name = "usb-storage",
    .probe = massStorageProbe,
    .disconnect = massStorageDisconnect,
    .supported_devices = &[_]usb.USBDriver.DeviceID{
        // Support all mass storage class devices
        .{ .vendor_id = 0, .product_id = 0, .class = .mass_storage },
    },
};

fn massStorageProbe(device: *usb.USBDevice, interface: *usb.Interface) !void {
    // Only handle mass storage class interfaces
    if (interface.descriptor.interface_class != @intFromEnum(usb.USBClass.mass_storage)) {
        return error.NotMassStorageDevice;
    }
    
    // Create mass storage device
    const allocator = device.allocator;
    const ms = try allocator.create(MassStorageDevice);
    ms.* = try MassStorageDevice.init(allocator, device, interface);
    
    // Store in interface private data
    interface.driver = &usb_mass_storage_driver;
    
    // Start the mass storage device
    try ms.start();
}

fn massStorageDisconnect(device: *usb.USBDevice, interface: *usb.Interface) void {
    _ = device;
    _ = interface;
    // TODO: Clean up mass storage device
}