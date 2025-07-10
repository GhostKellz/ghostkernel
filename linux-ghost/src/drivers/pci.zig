//! PCI (Peripheral Component Interconnect) subsystem for Ghost Kernel
//! Handles PCI device enumeration, configuration, and management

const std = @import("std");
const driver_framework = @import("driver_framework.zig");
const memory = @import("../mm/memory.zig");
const paging = @import("../mm/paging.zig");

/// PCI configuration space addresses
const PCI_CONFIG_ADDRESS = 0xCF8;
const PCI_CONFIG_DATA = 0xCFC;

/// PCI header type masks
const PCI_HEADER_TYPE_MASK = 0x7F;
const PCI_HEADER_TYPE_MULTIFUNCTION = 0x80;

/// PCI header types
const PCI_HEADER_TYPE_NORMAL = 0x00;
const PCI_HEADER_TYPE_BRIDGE = 0x01;
const PCI_HEADER_TYPE_CARDBUS = 0x02;

/// PCI command register bits
pub const PCI_COMMAND = packed struct(u16) {
    io_space: bool = false,
    memory_space: bool = false,
    bus_master: bool = false,
    special_cycles: bool = false,
    memory_write_invalidate: bool = false,
    vga_palette_snoop: bool = false,
    parity_error_response: bool = false,
    stepping_control: bool = false,
    serr_enable: bool = false,
    fast_b2b_enable: bool = false,
    interrupt_disable: bool = false,
    _reserved: u5 = 0,
};

/// PCI status register bits
pub const PCI_STATUS = packed struct(u16) {
    _reserved1: u3 = 0,
    interrupt_status: bool = false,
    capabilities_list: bool = false,
    capable_66mhz: bool = false,
    _reserved2: u1 = 0,
    fast_b2b_capable: bool = false,
    master_data_parity_error: bool = false,
    devsel_timing: u2 = 0,
    signaled_target_abort: bool = false,
    received_target_abort: bool = false,
    received_master_abort: bool = false,
    signaled_system_error: bool = false,
    detected_parity_error: bool = false,
};

/// PCI device class codes
pub const PCIClass = enum(u8) {
    unclassified = 0x00,
    mass_storage = 0x01,
    network = 0x02,
    display = 0x03,
    multimedia = 0x04,
    memory = 0x05,
    bridge = 0x06,
    communication = 0x07,
    system = 0x08,
    input = 0x09,
    docking = 0x0A,
    processor = 0x0B,
    serial_bus = 0x0C,
    wireless = 0x0D,
    intelligent = 0x0E,
    satellite = 0x0F,
    encryption = 0x10,
    signal_processing = 0x11,
    processing_accelerator = 0x12,
    non_essential = 0x13,
    _,
};

/// PCI configuration space header (Type 0 - Normal)
pub const PCIConfigHeader = extern struct {
    vendor_id: u16,
    device_id: u16,
    command: u16,
    status: u16,
    revision_id: u8,
    prog_if: u8,
    subclass: u8,
    class_code: u8,
    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,
    cardbus_cis_ptr: u32,
    subsystem_vendor_id: u16,
    subsystem_id: u16,
    expansion_rom_base: u32,
    capabilities_ptr: u8,
    _reserved: [7]u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,
};

/// PCI Base Address Register (BAR) info
pub const PCIBar = struct {
    base_address: usize,
    size: usize,
    is_memory: bool,
    is_prefetchable: bool,
    is_64bit: bool,
};

/// PCI capability IDs
pub const PCICapability = enum(u8) {
    power_management = 0x01,
    agp = 0x02,
    vpd = 0x03,
    slot_id = 0x04,
    msi = 0x05,
    hot_swap = 0x06,
    pci_x = 0x07,
    hyper_transport = 0x08,
    vendor_specific = 0x09,
    debug_port = 0x0A,
    resource_control = 0x0B,
    hot_plug = 0x0C,
    bridge_subsystem = 0x0D,
    agp_8x = 0x0E,
    secure_device = 0x0F,
    pci_express = 0x10,
    msi_x = 0x11,
    sata = 0x12,
    advanced_features = 0x13,
    enhanced_allocation = 0x14,
    flattening_portal = 0x15,
    _,
};

/// MSI capability structure
pub const MSICapability = extern struct {
    capability_id: u8,
    next_ptr: u8,
    message_control: u16,
    message_address_lo: u32,
    message_address_hi: u32,
    message_data: u16,
    mask_bits: u32,
    pending_bits: u32,
};

/// MSI-X capability structure
pub const MSIXCapability = extern struct {
    capability_id: u8,
    next_ptr: u8,
    message_control: u16,
    table_offset: u32,
    pba_offset: u32,
};

/// PCI Express capability structure
pub const PCIeCapability = extern struct {
    capability_id: u8,
    next_ptr: u8,
    pcie_capabilities: u16,
    device_capabilities: u32,
    device_control: u16,
    device_status: u16,
    link_capabilities: u32,
    link_control: u16,
    link_status: u16,
    slot_capabilities: u32,
    slot_control: u16,
    slot_status: u16,
    root_control: u16,
    root_capabilities: u16,
    root_status: u32,
    device_capabilities2: u32,
    device_control2: u16,
    device_status2: u16,
    link_capabilities2: u32,
    link_control2: u16,
    link_status2: u16,
    slot_capabilities2: u32,
    slot_control2: u16,
    slot_status2: u16,
};

/// PCI device structure
pub const PCIDevice = struct {
    device: driver_framework.Device,
    bus: u8,
    device_num: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,
    bars: [6]?PCIBar,
    capabilities: std.ArrayList(PCICapability),
    is_pcie: bool,
    msi_capable: bool,
    msix_capable: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, bus: u8, device_num: u8, function: u8) !Self {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "pci:{x:0>2}:{x:0>2}.{}", .{ bus, device_num, function });
        
        return Self{
            .device = try driver_framework.Device.init(allocator, name, .pci, &pci_device_ops),
            .bus = bus,
            .device_num = device_num,
            .function = function,
            .vendor_id = 0,
            .device_id = 0,
            .class_code = 0,
            .subclass = 0,
            .prog_if = 0,
            .header_type = 0,
            .bars = [_]?PCIBar{null} ** 6,
            .capabilities = std.ArrayList(PCICapability).init(allocator),
            .is_pcie = false,
            .msi_capable = false,
            .msix_capable = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.capabilities.deinit();
        self.device.deinit();
    }
    
    pub fn readConfig(self: *Self, comptime T: type, offset: u8) T {
        const address = makePCIAddress(self.bus, self.device_num, self.function, offset);
        
        // Write address to CONFIG_ADDRESS
        var config_port = driver_framework.IOPort{ .start = PCI_CONFIG_ADDRESS, .end = PCI_CONFIG_ADDRESS + 3, .name = "PCI_CONFIG" };
        config_port.writeDword(0, address);
        
        // Read data from CONFIG_DATA
        var data_port = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" };
        const data = data_port.readDword(0);
        
        return switch (T) {
            u8 => @truncate(data >> @as(u5, @truncate((offset & 3) * 8))),
            u16 => @truncate(data >> @as(u5, @truncate((offset & 2) * 8))),
            u32 => data,
            else => @compileError("Invalid PCI config read type"),
        };
    }
    
    pub fn writeConfig(self: *Self, comptime T: type, offset: u8, value: T) void {
        const address = makePCIAddress(self.bus, self.device_num, self.function, offset);
        
        // Write address to CONFIG_ADDRESS
        const config_port = driver_framework.IOPort{ .start = PCI_CONFIG_ADDRESS, .end = PCI_CONFIG_ADDRESS + 3, .name = "PCI_CONFIG" };
        config_port.writeDword(0, address);
        
        switch (T) {
            u8 => {
                const data_port = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" };
                var data = data_port.readDword(0);
                const shift = @as(u5, @truncate((offset & 3) * 8));
                data = (data & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
                data_port.writeDword(0, data);
            },
            u16 => {
                const data_port = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" };
                var data = data_port.readDword(0);
                const shift = @as(u5, @truncate((offset & 2) * 8));
                data = (data & ~(@as(u32, 0xFFFF) << shift)) | (@as(u32, value) << shift);
                data_port.writeDword(0, data);
            },
            u32 => {
                const data_port = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" };
                data_port.writeDword(0, value);
            },
            else => @compileError("Invalid PCI config write type"),
        }
    }
    
    pub fn enableDevice(self: *Self) !void {
        var command = @as(PCI_COMMAND, @bitCast(self.readConfig(u16, 0x04)));
        command.io_space = true;
        command.memory_space = true;
        command.bus_master = true;
        self.writeConfig(u16, 0x04, @bitCast(command));
    }
    
    pub fn disableDevice(self: *Self) void {
        var command = @as(PCI_COMMAND, @bitCast(self.readConfig(u16, 0x04)));
        command.io_space = false;
        command.memory_space = false;
        command.bus_master = false;
        self.writeConfig(u16, 0x04, @bitCast(command));
    }
    
    pub fn parseBAR(self: *Self, bar_index: u8) !?PCIBar {
        if (bar_index >= 6) return null;
        
        const bar_offset = 0x10 + (bar_index * 4);
        const bar_value = self.readConfig(u32, bar_offset);
        
        if (bar_value == 0) return null;
        
        // Write all 1s to determine size
        self.writeConfig(u32, bar_offset, 0xFFFFFFFF);
        const size_value = self.readConfig(u32, bar_offset);
        self.writeConfig(u32, bar_offset, bar_value);
        
        var bar = PCIBar{
            .base_address = 0,
            .size = 0,
            .is_memory = false,
            .is_prefetchable = false,
            .is_64bit = false,
        };
        
        if (bar_value & 1) {
            // I/O space BAR
            bar.is_memory = false;
            bar.base_address = bar_value & 0xFFFFFFFC;
            bar.size = (~(size_value & 0xFFFFFFFC)) + 1;
        } else {
            // Memory space BAR
            bar.is_memory = true;
            bar.is_prefetchable = (bar_value & 0x8) != 0;
            
            const bar_type = (bar_value >> 1) & 0x3;
            switch (bar_type) {
                0 => {
                    // 32-bit BAR
                    bar.is_64bit = false;
                    bar.base_address = bar_value & 0xFFFFFFF0;
                    bar.size = (~(size_value & 0xFFFFFFF0)) + 1;
                },
                2 => {
                    // 64-bit BAR
                    bar.is_64bit = true;
                    const high_value = self.readConfig(u32, bar_offset + 4);
                    bar.base_address = (@as(u64, high_value) << 32) | (bar_value & 0xFFFFFFF0);
                    
                    self.writeConfig(u32, bar_offset + 4, 0xFFFFFFFF);
                    const high_size = self.readConfig(u32, bar_offset + 4);
                    self.writeConfig(u32, bar_offset + 4, high_value);
                    
                    const full_size = (@as(u64, high_size) << 32) | (size_value & 0xFFFFFFF0);
                    bar.size = (~full_size) + 1;
                },
                else => return null,
            }
        }
        
        return bar;
    }
    
    pub fn scanCapabilities(self: *Self) !void {
        const status = @as(PCI_STATUS, @bitCast(self.readConfig(u16, 0x06)));
        if (!status.capabilities_list) return;
        
        var cap_ptr = self.readConfig(u8, 0x34) & 0xFC;
        
        while (cap_ptr != 0) {
            const cap_id = self.readConfig(u8, cap_ptr);
            const capability = @as(PCICapability, @enumFromInt(cap_id));
            
            try self.capabilities.append(capability);
            
            switch (capability) {
                .msi => self.msi_capable = true,
                .msi_x => self.msix_capable = true,
                .pci_express => self.is_pcie = true,
                else => {},
            }
            
            cap_ptr = self.readConfig(u8, cap_ptr + 1) & 0xFC;
        }
    }
    
    pub fn enableMSI(self: *Self) !void {
        if (!self.msi_capable) return driver_framework.DriverError.OperationNotSupported;
        
        // Find MSI capability
        var cap_ptr = self.readConfig(u8, 0x34) & 0xFC;
        while (cap_ptr != 0) {
            if (self.readConfig(u8, cap_ptr) == @intFromEnum(PCICapability.msi)) {
                // Enable MSI
                var control = self.readConfig(u16, cap_ptr + 2);
                control |= 1; // Enable bit
                self.writeConfig(u16, cap_ptr + 2, control);
                break;
            }
            cap_ptr = self.readConfig(u8, cap_ptr + 1) & 0xFC;
        }
    }
    
    pub fn mapBAR(self: *Self, bar_index: u8) !driver_framework.MemoryRegion {
        if (bar_index >= 6 or self.bars[bar_index] == null) {
            return driver_framework.DriverError.InvalidParameter;
        }
        
        const bar = self.bars[bar_index].?;
        if (!bar.is_memory) {
            return driver_framework.DriverError.InvalidOperation;
        }
        
        // Map physical memory to virtual
        const virt_addr = try paging.mapPhysical(bar.base_address, bar.size, 
            paging.PAGE_PRESENT | paging.PAGE_WRITABLE | paging.PAGE_CACHE_DISABLE);
        
        return driver_framework.MemoryRegion{
            .physical_start = bar.base_address,
            .virtual_start = virt_addr,
            .size = bar.size,
            .cacheable = false,
        };
    }
};

/// PCI device operations
var pci_device_ops = driver_framework.DeviceOps{
    .probe = pciProbe,
    .remove = pciRemove,
    .device_suspend = pciSuspend,
    .device_resume = pciResume,
};

fn pciProbe(device: *driver_framework.Device) driver_framework.DriverError!void {
    const pci_dev = @fieldParentPtr(PCIDevice, "device", device);
    
    // Read basic PCI info
    pci_dev.vendor_id = pci_dev.readConfig(u16, 0x00);
    pci_dev.device_id = pci_dev.readConfig(u16, 0x02);
    
    if (pci_dev.vendor_id == 0xFFFF) {
        return driver_framework.DriverError.DeviceNotFound;
    }
    
    // Read class info
    pci_dev.revision_id = pci_dev.readConfig(u8, 0x08);
    pci_dev.prog_if = pci_dev.readConfig(u8, 0x09);
    pci_dev.subclass = pci_dev.readConfig(u8, 0x0A);
    pci_dev.class_code = pci_dev.readConfig(u8, 0x0B);
    pci_dev.header_type = pci_dev.readConfig(u8, 0x0E);
    
    // Update device IDs
    device.vendor_id = pci_dev.vendor_id;
    device.device_id = pci_dev.device_id;
    
    // Parse BARs
    const num_bars: u8 = if ((pci_dev.header_type & PCI_HEADER_TYPE_MASK) == PCI_HEADER_TYPE_NORMAL) 6 else 2;
    var bar_index: u8 = 0;
    while (bar_index < num_bars) : (bar_index += 1) {
        if (try pci_dev.parseBAR(bar_index)) |bar| {
            pci_dev.bars[bar_index] = bar;
            if (bar.is_64bit and bar_index < 5) {
                bar_index += 1; // Skip next BAR for 64-bit
            }
        }
    }
    
    // Scan capabilities
    try pci_dev.scanCapabilities();
    
    // Set device capabilities based on PCI features
    if (pci_dev.is_pcie) {
        device.capabilities.dma_64bit = true;
    }
    if (pci_dev.msi_capable or pci_dev.msix_capable) {
        device.capabilities.msi = pci_dev.msi_capable;
        device.capabilities.msix = pci_dev.msix_capable;
    }
}

fn pciRemove(device: *driver_framework.Device) void {
    const pci_dev = @fieldParentPtr(PCIDevice, "device", device);
    pci_dev.disableDevice();
}

fn pciSuspend(device: *driver_framework.Device, state: driver_framework.PowerState) driver_framework.DriverError!void {
    _ = state;
    const pci_dev = @fieldParentPtr(PCIDevice, "device", device);
    pci_dev.disableDevice();
}

fn pciResume(device: *driver_framework.Device) driver_framework.DriverError!void {
    const pci_dev = @fieldParentPtr(PCIDevice, "device", device);
    try pci_dev.enableDevice();
}

/// Make PCI configuration address
fn makePCIAddress(bus: u8, device: u5, function: u3, offset: u8) u32 {
    return 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        (offset & 0xFC);
}

/// PCI bus scanner
pub const PCIScanner = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(*PCIDevice),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .devices = std.ArrayList(*PCIDevice).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.devices.items) |device| {
            device.deinit();
            self.allocator.destroy(device);
        }
        self.devices.deinit();
    }
    
    pub fn scanAllBuses(self: *Self) !void {
        // Scan all possible buses (0-255)
        for (0..256) |bus| {
            try self.scanBus(@truncate(bus));
        }
    }
    
    pub fn scanBus(self: *Self, bus: u8) !void {
        // Scan all possible devices on the bus (0-31)
        for (0..32) |device| {
            try self.scanDevice(bus, @truncate(device));
        }
    }
    
    pub fn scanDevice(self: *Self, bus: u8, device_num: u8) !void {
        // Check function 0 first
        const vendor_id = self.readConfigWord(bus, device_num, 0, 0x00);
        if (vendor_id == 0xFFFF) return; // No device
        
        // Check if multifunction device
        const header_type = self.readConfigByte(bus, device_num, 0, 0x0E);
        const is_multifunction = (header_type & PCI_HEADER_TYPE_MULTIFUNCTION) != 0;
        
        // Scan all functions
        const max_functions: u8 = if (is_multifunction) 8 else 1;
        for (0..max_functions) |function| {
            try self.scanFunction(bus, device_num, @truncate(function));
        }
    }
    
    pub fn scanFunction(self: *Self, bus: u8, device_num: u8, function: u8) !void {
        const vendor_id = self.readConfigWord(bus, device_num, function, 0x00);
        if (vendor_id == 0xFFFF) return; // No function
        
        // Create PCI device
        const pci_device = try self.allocator.create(PCIDevice);
        pci_device.* = try PCIDevice.init(self.allocator, bus, device_num, function);
        
        // Probe the device
        pciProbe(&pci_device.device) catch |err| {
            pci_device.deinit();
            self.allocator.destroy(pci_device);
            return err;
        };
        
        try self.devices.append(pci_device);
        
        // Register with device manager
        const dm = driver_framework.getDeviceManager();
        try dm.registerDevice(&pci_device.device);
        
        // Check for PCI bridges
        const class_code = pci_device.class_code;
        if (class_code == @intFromEnum(PCIClass.bridge)) {
            const subclass = pci_device.subclass;
            if (subclass == 0x04) { // PCI-to-PCI bridge
                const secondary_bus = self.readConfigByte(bus, device_num, function, 0x19);
                try self.scanBus(secondary_bus);
            }
        }
    }
    
    fn readConfigByte(self: *Self, bus: u8, device: u8, function: u8, offset: u8) u8 {
        _ = self;
        const address = makePCIAddress(bus, @truncate(device), @truncate(function), offset);
        
        const config_port = driver_framework.IOPort{ .start = PCI_CONFIG_ADDRESS, .end = PCI_CONFIG_ADDRESS + 3, .name = "PCI_CONFIG" };
        config_port.writeDword(0, address);
        
        const data = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" }
            .readDword(0);
        
        return @truncate(data >> @as(u5, @truncate((offset & 3) * 8)));
    }
    
    fn readConfigWord(self: *Self, bus: u8, device: u8, function: u8, offset: u8) u16 {
        _ = self;
        const address = makePCIAddress(bus, @truncate(device), @truncate(function), offset);
        
        const config_port = driver_framework.IOPort{ .start = PCI_CONFIG_ADDRESS, .end = PCI_CONFIG_ADDRESS + 3, .name = "PCI_CONFIG" };
        config_port.writeDword(0, address);
        
        const data = driver_framework.IOPort{ .start = PCI_CONFIG_DATA, .end = PCI_CONFIG_DATA + 3, .name = "PCI_DATA" }
            .readDword(0);
        
        return @truncate(data >> @as(u5, @truncate((offset & 2) * 8)));
    }
    
    pub fn findDevicesByClass(self: *Self, class: PCIClass, subclass: ?u8) []const *PCIDevice {
        var matches = std.ArrayList(*PCIDevice).init(self.allocator);
        defer matches.deinit();
        
        for (self.devices.items) |device| {
            if (@as(PCIClass, @enumFromInt(device.class_code)) == class) {
                if (subclass == null or device.subclass == subclass.?) {
                    matches.append(device) catch continue;
                }
            }
        }
        
        return matches.toOwnedSlice() catch &[_]*PCIDevice{};
    }
    
    pub fn findDeviceByVendor(self: *Self, vendor_id: u16, device_id: ?u16) ?*PCIDevice {
        for (self.devices.items) |device| {
            if (device.vendor_id == vendor_id) {
                if (device_id == null or device.device_id == device_id.?) {
                    return device;
                }
            }
        }
        return null;
    }
};

/// Known PCI vendor IDs
pub const PCIVendor = enum(u16) {
    intel = 0x8086,
    amd = 0x1022,
    nvidia = 0x10DE,
    realtek = 0x10EC,
    broadcom = 0x14E4,
    qualcomm = 0x17CB,
    red_hat = 0x1AF4,
    vmware = 0x15AD,
    _,
};

/// Initialize PCI subsystem
pub fn initPCI(allocator: std.mem.Allocator) !void {
    var scanner = PCIScanner.init(allocator);
    defer scanner.deinit();
    
    try scanner.scanAllBuses();
    
    // Log found devices
    for (scanner.devices.items) |device| {
        std.log.info("PCI device found: {:04x}:{:04x} at {:02x}:{:02x}.{} - class {:02x}:{:02x}", .{
            device.vendor_id,
            device.device_id,
            device.bus,
            device.device_num,
            device.function,
            device.class_code,
            device.subclass,
        });
    }
}