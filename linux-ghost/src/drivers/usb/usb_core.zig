//! USB Core Subsystem for Ghost Kernel
//! Pure Zig implementation of USB stack optimized for low-latency input devices
//! Focus on gaming peripherals, keyboards, mice, and controllers

const std = @import("std");
const memory = @import("../../mm/memory.zig");
const sync = @import("../../kernel/sync.zig");
const driver_framework = @import("../driver_framework.zig");

/// USB speeds
pub const USBSpeed = enum(u8) {
    low = 0,        // 1.5 Mbps (USB 1.0)
    full = 1,       // 12 Mbps (USB 1.1)
    high = 2,       // 480 Mbps (USB 2.0)
    super = 3,      // 5 Gbps (USB 3.0)
    super_plus = 4, // 10 Gbps (USB 3.1)
    super_plus_gen2 = 5, // 20 Gbps (USB 3.2)
};

/// USB device classes
pub const USBClass = enum(u8) {
    use_interface = 0x00,
    audio = 0x01,
    communications = 0x02,
    hid = 0x03,              // Human Interface Device (keyboards, mice, gamepads)
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    mass_storage = 0x08,
    hub = 0x09,
    cdc_data = 0x0A,
    smart_card = 0x0B,
    content_security = 0x0D,
    video = 0x0E,
    personal_healthcare = 0x0F,
    audio_video = 0x10,
    billboard = 0x11,
    usb_c_bridge = 0x12,
    diagnostic = 0xDC,
    wireless_controller = 0xE0,
    miscellaneous = 0xEF,
    application_specific = 0xFE,
    vendor_specific = 0xFF,
};

/// USB transfer types
pub const TransferType = enum(u8) {
    control = 0,
    isochronous = 1,
    bulk = 2,
    interrupt = 3,
};

/// USB endpoint directions
pub const EndpointDirection = enum(u1) {
    out = 0,    // Host to device
    in = 1,     // Device to host
};

/// USB request types
pub const RequestType = enum(u8) {
    get_status = 0x00,
    clear_feature = 0x01,
    set_feature = 0x03,
    set_address = 0x05,
    get_descriptor = 0x06,
    set_descriptor = 0x07,
    get_configuration = 0x08,
    set_configuration = 0x09,
    get_interface = 0x0A,
    set_interface = 0x0B,
    synch_frame = 0x0C,
};

/// USB descriptor types
pub const DescriptorType = enum(u8) {
    device = 0x01,
    configuration = 0x02,
    string = 0x03,
    interface = 0x04,
    endpoint = 0x05,
    device_qualifier = 0x06,
    other_speed_config = 0x07,
    interface_power = 0x08,
    otg = 0x09,
    debug = 0x0A,
    interface_association = 0x0B,
    bos = 0x0F,
    device_capability = 0x10,
    hid = 0x21,
    hid_report = 0x22,
    hid_physical = 0x23,
    hub = 0x29,
    superspeed_hub = 0x2A,
    ss_endpoint_companion = 0x30,
};

/// USB device states
pub const DeviceState = enum(u8) {
    detached = 0,
    attached = 1,
    powered = 2,
    default = 3,
    address = 4,
    configured = 5,
    suspended = 6,
};

/// USB control request setup packet
pub const SetupPacket = packed struct {
    request_type: u8,       // bmRequestType
    request: u8,            // bRequest
    value: u16,             // wValue
    index: u16,             // wIndex
    length: u16,            // wLength
};

/// USB device descriptor
pub const DeviceDescriptor = packed struct {
    length: u8,             // bLength
    descriptor_type: u8,    // bDescriptorType
    usb_version: u16,       // bcdUSB
    device_class: u8,       // bDeviceClass
    device_subclass: u8,    // bDeviceSubClass
    device_protocol: u8,    // bDeviceProtocol
    max_packet_size0: u8,   // bMaxPacketSize0
    vendor_id: u16,         // idVendor
    product_id: u16,        // idProduct
    device_version: u16,    // bcdDevice
    manufacturer: u8,       // iManufacturer
    product: u8,            // iProduct
    serial_number: u8,      // iSerialNumber
    num_configurations: u8, // bNumConfigurations
};

/// USB configuration descriptor
pub const ConfigurationDescriptor = packed struct {
    length: u8,             // bLength
    descriptor_type: u8,    // bDescriptorType
    total_length: u16,      // wTotalLength
    num_interfaces: u8,     // bNumInterfaces
    configuration_value: u8, // bConfigurationValue
    configuration: u8,      // iConfiguration
    attributes: u8,         // bmAttributes
    max_power: u8,          // bMaxPower (in 2mA units)
};

/// USB interface descriptor
pub const InterfaceDescriptor = packed struct {
    length: u8,             // bLength
    descriptor_type: u8,    // bDescriptorType
    interface_number: u8,   // bInterfaceNumber
    alternate_setting: u8,  // bAlternateSetting
    num_endpoints: u8,      // bNumEndpoints
    interface_class: u8,    // bInterfaceClass
    interface_subclass: u8, // bInterfaceSubClass
    interface_protocol: u8, // bInterfaceProtocol
    interface: u8,          // iInterface
};

/// USB endpoint descriptor
pub const EndpointDescriptor = packed struct {
    length: u8,             // bLength
    descriptor_type: u8,    // bDescriptorType
    endpoint_address: u8,   // bEndpointAddress
    attributes: u8,         // bmAttributes
    max_packet_size: u16,   // wMaxPacketSize
    interval: u8,           // bInterval
    
    const Self = @This();
    
    pub fn getDirection(self: Self) EndpointDirection {
        return @enumFromInt((self.endpoint_address & 0x80) >> 7);
    }
    
    pub fn getNumber(self: Self) u4 {
        return @truncate(self.endpoint_address & 0x0F);
    }
    
    pub fn getTransferType(self: Self) TransferType {
        return @enumFromInt(self.attributes & 0x03);
    }
    
    pub fn getMaxPacketSize(self: Self) u16 {
        return self.max_packet_size & 0x07FF;
    }
    
    pub fn getAdditionalTransactions(self: Self) u8 {
        return @truncate((self.max_packet_size & 0x1800) >> 11);
    }
};

/// USB transfer request block (URB)
pub const URB = struct {
    device: *USBDevice,
    endpoint: u8,
    transfer_type: TransferType,
    direction: EndpointDirection,
    buffer: []u8,
    actual_length: usize = 0,
    status: URBStatus = .pending,
    
    // Completion callback
    completion_fn: ?*const fn (*URB) void = null,
    context: ?*anyopaque = null,
    
    // Gaming optimization flags
    low_latency: bool = false,
    high_priority: bool = false,
    gaming_device: bool = false,
    
    // Timing information
    submit_time: u64 = 0,
    complete_time: u64 = 0,
    
    const Self = @This();
    
    pub fn getLatency(self: *const Self) u64 {
        if (self.complete_time > self.submit_time) {
            return self.complete_time - self.submit_time;
        }
        return 0;
    }
};

/// URB status codes
pub const URBStatus = enum(u8) {
    pending = 0,
    completed = 1,
    error = 2,
    cancelled = 3,
    stalled = 4,
    timeout = 5,
    overflow = 6,
    underflow = 7,
    crc_error = 8,
    bitstuff_error = 9,
    no_response = 10,
};

/// USB device structure
pub const USBDevice = struct {
    address: u8,
    speed: USBSpeed,
    state: DeviceState,
    parent_hub: ?*USBHub,
    port_number: u8,
    
    // Device information
    device_descriptor: DeviceDescriptor,
    configuration_descriptor: ?ConfigurationDescriptor = null,
    configurations: std.ArrayList(Configuration),
    current_configuration: u8 = 0,
    
    // Gaming device optimization
    is_gaming_device: bool = false,
    is_input_device: bool = false,
    low_latency_mode: bool = false,
    polling_rate_hz: u32 = 0,
    
    // Performance metrics
    total_transfers: std.atomic.Value(u64),
    successful_transfers: std.atomic.Value(u64),
    failed_transfers: std.atomic.Value(u32),
    avg_latency_ns: std.atomic.Value(u64),
    
    // Host controller
    hcd: *HostControllerDriver,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, hcd: *HostControllerDriver, address: u8, speed: USBSpeed) Self {
        return Self{
            .address = address,
            .speed = speed,
            .state = .default,
            .parent_hub = null,
            .port_number = 0,
            .device_descriptor = std.mem.zeroes(DeviceDescriptor),
            .configurations = std.ArrayList(Configuration).init(allocator),
            .total_transfers = std.atomic.Value(u64).init(0),
            .successful_transfers = std.atomic.Value(u64).init(0),
            .failed_transfers = std.atomic.Value(u32).init(0),
            .avg_latency_ns = std.atomic.Value(u64).init(0),
            .hcd = hcd,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.configurations.items) |*config| {
            config.deinit();
        }
        self.configurations.deinit();
    }
    
    pub fn getDeviceDescriptor(self: *Self) !void {
        var setup = SetupPacket{
            .request_type = 0x80, // Device to host, standard, device
            .request = @intFromEnum(RequestType.get_descriptor),
            .value = (@as(u16, @intFromEnum(DescriptorType.device)) << 8) | 0,
            .index = 0,
            .length = @sizeOf(DeviceDescriptor),
        };
        
        var buffer: [@sizeOf(DeviceDescriptor)]u8 = undefined;
        try self.controlTransfer(&setup, &buffer);
        
        self.device_descriptor = @as(*const DeviceDescriptor, @ptrCast(@alignCast(&buffer))).*;
        
        // Check if this is a gaming/input device
        self.analyzeDeviceType();
    }
    
    pub fn setConfiguration(self: *Self, config_value: u8) !void {
        var setup = SetupPacket{
            .request_type = 0x00, // Host to device, standard, device
            .request = @intFromEnum(RequestType.set_configuration),
            .value = config_value,
            .index = 0,
            .length = 0,
        };
        
        try self.controlTransfer(&setup, &[_]u8{});
        self.current_configuration = config_value;
        self.state = .configured;
    }
    
    pub fn controlTransfer(self: *Self, setup: *SetupPacket, buffer: []u8) !void {
        var urb = URB{
            .device = self,
            .endpoint = 0, // Control endpoint
            .transfer_type = .control,
            .direction = if (setup.request_type & 0x80 != 0) .in else .out,
            .buffer = buffer,
            .low_latency = self.low_latency_mode,
            .gaming_device = self.is_gaming_device,
            .submit_time = @intCast(std.time.nanoTimestamp()),
        };
        
        try self.hcd.submitControlTransfer(self, setup, &urb);
        
        // Update statistics
        self.updateTransferStats(&urb);
    }
    
    pub fn submitTransfer(self: *Self, urb: *URB) !void {
        urb.submit_time = @intCast(std.time.nanoTimestamp());
        urb.gaming_device = self.is_gaming_device;
        urb.low_latency = self.low_latency_mode;
        
        switch (urb.transfer_type) {
            .control => try self.hcd.submitControlTransfer(self, null, urb),
            .interrupt => try self.hcd.submitInterruptTransfer(self, urb),
            .bulk => try self.hcd.submitBulkTransfer(self, urb),
            .isochronous => try self.hcd.submitIsochronousTransfer(self, urb),
        }
        
        self.updateTransferStats(urb);
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.low_latency_mode = true;
        
        // Set higher polling rate for input devices
        if (self.is_input_device) {
            self.polling_rate_hz = 1000; // 1000 Hz for gaming mice/keyboards
        }
        
        // Notify HCD about gaming mode
        self.hcd.setDeviceGamingMode(self, true);
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.low_latency_mode = false;
        self.polling_rate_hz = 125; // Standard polling rate
        self.hcd.setDeviceGamingMode(self, false);
    }
    
    fn analyzeDeviceType(self: *Self) void {
        // Check if this is an input device
        if (self.device_descriptor.device_class == @intFromEnum(USBClass.hid)) {
            self.is_input_device = true;
            
            // Check for gaming peripherals by vendor/product ID
            const gaming_vendors = [_]u16{
                0x046D, // Logitech
                0x1532, // Razer
                0x0B05, // ASUS
                0x1B1C, // Corsair
                0x3842, // EVGA
                0x0D8C, // C-Media
                0x1038, // SteelSeries
                0x045E, // Microsoft
                0x0955, // NVIDIA
                0x28DE, // Valve
            };
            
            for (gaming_vendors) |vendor| {
                if (self.device_descriptor.vendor_id == vendor) {
                    self.is_gaming_device = true;
                    break;
                }
            }
        }
        
        // Check for gaming controllers by class
        if (self.device_descriptor.device_class == @intFromEnum(USBClass.vendor_specific) or
            self.device_descriptor.device_class == @intFromEnum(USBClass.hid))
        {
            // Many gaming controllers use vendor-specific or HID classes
            // Additional heuristics could be added here
        }
    }
    
    fn updateTransferStats(self: *Self, urb: *URB) void {
        _ = self.total_transfers.fetchAdd(1, .release);
        
        if (urb.status == .completed) {
            _ = self.successful_transfers.fetchAdd(1, .release);
            
            // Update average latency (exponential moving average)
            const latency = urb.getLatency();
            const current_avg = self.avg_latency_ns.load(.acquire);
            const new_avg = if (current_avg == 0) latency else (current_avg * 7 + latency) / 8;
            self.avg_latency_ns.store(new_avg, .release);
        } else {
            _ = self.failed_transfers.fetchAdd(1, .release);
        }
    }
    
    pub fn getPerformanceMetrics(self: *Self) DevicePerformanceMetrics {
        const total = self.total_transfers.load(.acquire);
        const successful = self.successful_transfers.load(.acquire);
        const failed = self.failed_transfers.load(.acquire);
        
        return DevicePerformanceMetrics{
            .total_transfers = total,
            .successful_transfers = successful,
            .failed_transfers = failed,
            .success_rate = if (total > 0) @as(f32, @floatFromInt(successful)) / @as(f32, @floatFromInt(total)) else 0.0,
            .avg_latency_ns = self.avg_latency_ns.load(.acquire),
            .is_gaming_device = self.is_gaming_device,
            .low_latency_mode = self.low_latency_mode,
            .polling_rate_hz = self.polling_rate_hz,
        };
    }
};

/// USB configuration
pub const Configuration = struct {
    descriptor: ConfigurationDescriptor,
    interfaces: std.ArrayList(Interface),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, descriptor: ConfigurationDescriptor) Self {
        return Self{
            .descriptor = descriptor,
            .interfaces = std.ArrayList(Interface).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.interfaces.items) |*interface| {
            interface.deinit();
        }
        self.interfaces.deinit();
    }
    
    pub fn addInterface(self: *Self, interface: Interface) !void {
        try self.interfaces.append(interface);
    }
};

/// USB interface
pub const Interface = struct {
    descriptor: InterfaceDescriptor,
    endpoints: std.ArrayList(Endpoint),
    driver: ?*USBDriver = null,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, descriptor: InterfaceDescriptor) Self {
        return Self{
            .descriptor = descriptor,
            .endpoints = std.ArrayList(Endpoint).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.endpoints.deinit();
    }
    
    pub fn addEndpoint(self: *Self, endpoint: Endpoint) !void {
        try self.endpoints.append(endpoint);
    }
};

/// USB endpoint
pub const Endpoint = struct {
    descriptor: EndpointDescriptor,
    active: bool = false,
    
    const Self = @This();
    
    pub fn init(descriptor: EndpointDescriptor) Self {
        return Self{
            .descriptor = descriptor,
        };
    }
};

/// USB hub structure
pub const USBHub = struct {
    device: USBDevice,
    num_ports: u8,
    ports: []HubPort,
    
    // Hub status
    power_switching: bool = false,
    compound_device: bool = false,
    over_current_protection: bool = false,
    
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device: USBDevice, num_ports: u8) !Self {
        const ports = try allocator.alloc(HubPort, num_ports);
        
        for (ports, 0..) |*port, i| {
            port.* = HubPort.init(@intCast(i + 1));
        }
        
        return Self{
            .device = device,
            .num_ports = num_ports,
            .ports = ports,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.ports);
    }
    
    pub fn portStatusChange(self: *Self, port_number: u8) !void {
        if (port_number == 0 or port_number > self.num_ports) return;
        
        const port = &self.ports[port_number - 1];
        
        // TODO: Handle port status change
        // - Device connect/disconnect
        // - Port enable/disable
        // - Over-current conditions
        // - Port reset completion
        
        _ = port;
    }
};

/// Hub port structure
pub const HubPort = struct {
    number: u8,
    connected: bool = false,
    enabled: bool = false,
    suspended: bool = false,
    reset: bool = false,
    power: bool = false,
    over_current: bool = false,
    device: ?*USBDevice = null,
    
    const Self = @This();
    
    pub fn init(number: u8) Self {
        return Self{
            .number = number,
        };
    }
};

/// USB driver interface
pub const USBDriver = struct {
    name: []const u8,
    probe: *const fn (*USBDevice, *Interface) !void,
    disconnect: *const fn (*USBDevice, *Interface) void,
    
    // Gaming optimization callbacks
    enable_gaming_mode: ?*const fn (*USBDevice, *Interface) void = null,
    disable_gaming_mode: ?*const fn (*USBDevice, *Interface) void = null,
    
    // Supported devices (vendor/product ID pairs)
    supported_devices: []const DeviceID,
    
    const DeviceID = struct {
        vendor_id: u16,
        product_id: u16,
        class: ?USBClass = null,
        subclass: ?u8 = null,
        protocol: ?u8 = null,
    };
};

/// Host Controller Driver (HCD) interface
pub const HostControllerDriver = struct {
    name: []const u8,
    
    // Transfer submission functions
    submitControlTransfer: *const fn (*HostControllerDriver, *USBDevice, ?*SetupPacket, *URB) !void,
    submitInterruptTransfer: *const fn (*HostControllerDriver, *USBDevice, *URB) !void,
    submitBulkTransfer: *const fn (*HostControllerDriver, *USBDevice, *URB) !void,
    submitIsochronousTransfer: *const fn (*HostControllerDriver, *USBDevice, *URB) !void,
    
    // Gaming optimization
    setDeviceGamingMode: *const fn (*HostControllerDriver, *USBDevice, bool) void,
    setPriorityQueue: *const fn (*HostControllerDriver, bool) void,
    
    // Device management
    resetPort: *const fn (*HostControllerDriver, u8) !void,
    enablePort: *const fn (*HostControllerDriver, u8) !void,
    disablePort: *const fn (*HostControllerDriver, u8) void,
    
    // Root hub
    root_hub: ?*USBHub = null,
    
    // Gaming mode state
    gaming_mode_enabled: bool = false,
    priority_queue_enabled: bool = false,
    low_latency_enabled: bool = false,
    
    private_data: ?*anyopaque = null,
};

/// Device performance metrics
pub const DevicePerformanceMetrics = struct {
    total_transfers: u64,
    successful_transfers: u64,
    failed_transfers: u32,
    success_rate: f32,
    avg_latency_ns: u64,
    is_gaming_device: bool,
    low_latency_mode: bool,
    polling_rate_hz: u32,
};

/// USB subsystem manager
pub const USBSubsystem = struct {
    allocator: std.mem.Allocator,
    host_controllers: std.ArrayList(*HostControllerDriver),
    devices: std.ArrayList(*USBDevice),
    drivers: std.ArrayList(*USBDriver),
    hubs: std.ArrayList(*USBHub),
    
    // Gaming mode state
    gaming_mode_enabled: bool = false,
    
    // Device enumeration
    next_address: u8 = 1,
    
    mutex: sync.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .host_controllers = std.ArrayList(*HostControllerDriver).init(allocator),
            .devices = std.ArrayList(*USBDevice).init(allocator),
            .drivers = std.ArrayList(*USBDriver).init(allocator),
            .hubs = std.ArrayList(*USBHub).init(allocator),
            .next_address = 1,
            .mutex = sync.Mutex.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up devices
        for (self.devices.items) |device| {
            device.deinit();
            self.allocator.destroy(device);
        }
        self.devices.deinit();
        
        // Clean up hubs
        for (self.hubs.items) |hub| {
            hub.deinit();
            self.allocator.destroy(hub);
        }
        self.hubs.deinit();
        
        self.host_controllers.deinit();
        self.drivers.deinit();
    }
    
    pub fn registerHostController(self: *Self, hcd: *HostControllerDriver) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.host_controllers.append(hcd);
        
        // Enable gaming mode if globally enabled
        if (self.gaming_mode_enabled) {
            hcd.setPriorityQueue(hcd, true);
        }
    }
    
    pub fn registerDriver(self: *Self, driver: *USBDriver) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.drivers.append(driver);
        
        // Try to bind to existing devices
        for (self.devices.items) |device| {
            if (self.matchDevice(device, driver)) {
                for (device.configurations.items) |*config| {
                    for (config.interfaces.items) |*interface| {
                        if (interface.driver == null) {
                            driver.probe(device, interface) catch continue;
                            interface.driver = driver;
                        }
                    }
                }
            }
        }
    }
    
    pub fn deviceConnected(self: *Self, hcd: *HostControllerDriver, port: u8, speed: USBSpeed) !*USBDevice {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Allocate new device address
        const address = self.next_address;
        self.next_address += 1;
        
        // Create device
        const device = try self.allocator.create(USBDevice);
        device.* = USBDevice.init(self.allocator, hcd, address, speed);
        
        try self.devices.append(device);
        
        // Enumerate device
        try self.enumerateDevice(device);
        
        return device;
    }
    
    pub fn deviceDisconnected(self: *Self, device: *USBDevice) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Disconnect all interfaces
        for (device.configurations.items) |*config| {
            for (config.interfaces.items) |*interface| {
                if (interface.driver) |driver| {
                    driver.disconnect(device, interface);
                    interface.driver = null;
                }
            }
        }
        
        // Remove from device list
        for (self.devices.items, 0..) |d, i| {
            if (d == device) {
                _ = self.devices.swapRemove(i);
                break;
            }
        }
        
        device.deinit();
        self.allocator.destroy(device);
    }
    
    pub fn enableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = true;
        
        // Enable gaming mode on all host controllers
        for (self.host_controllers.items) |hcd| {
            hcd.setPriorityQueue(hcd, true);
            hcd.gaming_mode_enabled = true;
            hcd.low_latency_enabled = true;
        }
        
        // Enable gaming mode on gaming devices
        for (self.devices.items) |device| {
            if (device.is_gaming_device or device.is_input_device) {
                device.enableGamingMode();
                
                // Notify drivers
                for (device.configurations.items) |*config| {
                    for (config.interfaces.items) |*interface| {
                        if (interface.driver) |driver| {
                            if (driver.enable_gaming_mode) |enable_fn| {
                                enable_fn(device, interface);
                            }
                        }
                    }
                }
            }
        }
    }
    
    pub fn disableGamingMode(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.gaming_mode_enabled = false;
        
        // Disable gaming mode on host controllers
        for (self.host_controllers.items) |hcd| {
            hcd.setPriorityQueue(hcd, false);
            hcd.gaming_mode_enabled = false;
            hcd.low_latency_enabled = false;
        }
        
        // Disable gaming mode on devices
        for (self.devices.items) |device| {
            device.disableGamingMode();
            
            // Notify drivers
            for (device.configurations.items) |*config| {
                for (config.interfaces.items) |*interface| {
                    if (interface.driver) |driver| {
                        if (driver.disable_gaming_mode) |disable_fn| {
                            disable_fn(device, interface);
                        }
                    }
                }
            }
        }
    }
    
    fn enumerateDevice(self: *Self, device: *USBDevice) !void {
        // Set device address
        var setup = SetupPacket{
            .request_type = 0x00,
            .request = @intFromEnum(RequestType.set_address),
            .value = device.address,
            .index = 0,
            .length = 0,
        };
        
        try device.controlTransfer(&setup, &[_]u8{});
        device.state = .address;
        
        // Get device descriptor
        try device.getDeviceDescriptor();
        
        // TODO: Get configuration descriptors and set configuration
        
        // Try to bind drivers
        for (self.drivers.items) |driver| {
            if (self.matchDevice(device, driver)) {
                // TODO: Bind driver to appropriate interfaces
                break;
            }
        }
    }
    
    fn matchDevice(self: *Self, device: *USBDevice, driver: *USBDriver) bool {
        _ = self;
        
        for (driver.supported_devices) |supported| {
            if (supported.vendor_id == device.device_descriptor.vendor_id and
                supported.product_id == device.device_descriptor.product_id)
            {
                return true;
            }
            
            if (supported.class) |class| {
                if (class == @enumFromInt(device.device_descriptor.device_class)) {
                    return true;
                }
            }
        }
        
        return false;
    }
    
    pub fn getPerformanceReport(self: *Self) USBPerformanceReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var report = USBPerformanceReport{
            .total_devices = @intCast(self.devices.items.len),
            .gaming_devices = 0,
            .input_devices = 0,
            .total_transfers = 0,
            .successful_transfers = 0,
            .failed_transfers = 0,
            .avg_latency_ns = 0,
            .gaming_mode_enabled = self.gaming_mode_enabled,
        };
        
        var total_latency: u64 = 0;
        var device_count: u32 = 0;
        
        for (self.devices.items) |device| {
            const metrics = device.getPerformanceMetrics();
            
            if (device.is_gaming_device) report.gaming_devices += 1;
            if (device.is_input_device) report.input_devices += 1;
            
            report.total_transfers += metrics.total_transfers;
            report.successful_transfers += metrics.successful_transfers;
            report.failed_transfers += metrics.failed_transfers;
            
            if (metrics.avg_latency_ns > 0) {
                total_latency += metrics.avg_latency_ns;
                device_count += 1;
            }
        }
        
        if (device_count > 0) {
            report.avg_latency_ns = total_latency / device_count;
        }
        
        return report;
    }
};

/// USB performance report
pub const USBPerformanceReport = struct {
    total_devices: u32,
    gaming_devices: u32,
    input_devices: u32,
    total_transfers: u64,
    successful_transfers: u64,
    failed_transfers: u32,
    avg_latency_ns: u64,
    gaming_mode_enabled: bool,
};

// Global USB subsystem
var global_usb_subsystem: ?*USBSubsystem = null;

/// Initialize the USB subsystem
pub fn initUSBSubsystem(allocator: std.mem.Allocator) !void {
    const usb = try allocator.create(USBSubsystem);
    usb.* = USBSubsystem.init(allocator);
    global_usb_subsystem = usb;
}

/// Get the global USB subsystem
pub fn getUSBSubsystem() *USBSubsystem {
    return global_usb_subsystem orelse @panic("USB subsystem not initialized");
}

// Tests
test "USB device creation and enumeration" {
    const allocator = std.testing.allocator;
    
    var usb = USBSubsystem.init(allocator);
    defer usb.deinit();
    
    // Mock HCD
    var hcd = HostControllerDriver{
        .name = "test_hcd",
        .submitControlTransfer = undefined,
        .submitInterruptTransfer = undefined,
        .submitBulkTransfer = undefined,
        .submitIsochronousTransfer = undefined,
        .setDeviceGamingMode = undefined,
        .setPriorityQueue = undefined,
        .resetPort = undefined,
        .enablePort = undefined,
        .disablePort = undefined,
    };
    
    try usb.registerHostController(&hcd);
    try std.testing.expect(usb.host_controllers.items.len == 1);
}

test "gaming mode functionality" {
    const allocator = std.testing.allocator;
    
    var usb = USBSubsystem.init(allocator);
    defer usb.deinit();
    
    try std.testing.expect(!usb.gaming_mode_enabled);
    
    usb.enableGamingMode();
    try std.testing.expect(usb.gaming_mode_enabled);
    
    usb.disableGamingMode();
    try std.testing.expect(!usb.gaming_mode_enabled);
}

test "USB descriptor parsing" {
    const device_desc = DeviceDescriptor{
        .length = 18,
        .descriptor_type = @intFromEnum(DescriptorType.device),
        .usb_version = 0x0200, // USB 2.0
        .device_class = @intFromEnum(USBClass.hid),
        .device_subclass = 0,
        .device_protocol = 0,
        .max_packet_size0 = 64,
        .vendor_id = 0x046D, // Logitech
        .product_id = 0xC077,
        .device_version = 0x0100,
        .manufacturer = 1,
        .product = 2,
        .serial_number = 0,
        .num_configurations = 1,
    };
    
    try std.testing.expect(device_desc.device_class == @intFromEnum(USBClass.hid));
    try std.testing.expect(device_desc.vendor_id == 0x046D);
}

test "endpoint descriptor analysis" {
    const endpoint_desc = EndpointDescriptor{
        .length = 7,
        .descriptor_type = @intFromEnum(DescriptorType.endpoint),
        .endpoint_address = 0x81, // IN endpoint 1
        .attributes = 0x03, // Interrupt transfer
        .max_packet_size = 8,
        .interval = 10,
    };
    
    try std.testing.expect(endpoint_desc.getDirection() == .in);
    try std.testing.expect(endpoint_desc.getNumber() == 1);
    try std.testing.expect(endpoint_desc.getTransferType() == .interrupt);
    try std.testing.expect(endpoint_desc.getMaxPacketSize() == 8);
}