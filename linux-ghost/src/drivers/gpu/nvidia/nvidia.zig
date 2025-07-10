// GhostNV NVIDIA Driver - Kernel Integration
// This integrates the ghostnv driver from github.com/ghostkellz/ghostnv directly into the kernel

const std = @import("std");
const config = @import("config");

// TODO: These will interface with your ghostnv repo source
const ghostnv_core = @import("core/ghostnv_core.zig");
const ghostnv_hal = @import("hal/ghostnv_hal.zig");
const ghostnv_cuda = @import("cuda/ghostnv_cuda.zig");
const ghostnv_nvenc = @import("nvenc/ghostnv_nvenc.zig");
const ghostnv_vibrance = @import("vibrance/ghostnv_vibrance.zig");
const ghostnv_kernel = @import("kernel/ghostnv_kernel.zig");

pub const GhostNVDriver = struct {
    allocator: std.mem.Allocator,
    core: ghostnv_core.GhostNVCore,
    hal: ghostnv_hal.GhostNVHAL,
    cuda: ?ghostnv_cuda.GhostNVCUDA,
    nvenc: ?ghostnv_nvenc.GhostNVNVENC,
    vibrance: ?ghostnv_vibrance.GhostNVVibrance,
    kernel_integration: ghostnv_kernel.GhostNVKernel,
    
    pub fn init(allocator: std.mem.Allocator) !GhostNVDriver {
        var driver = GhostNVDriver{
            .allocator = allocator,
            .core = try ghostnv_core.GhostNVCore.init(allocator),
            .hal = try ghostnv_hal.GhostNVHAL.init(allocator),
            .cuda = null,
            .nvenc = null,
            .vibrance = null,
            .kernel_integration = try ghostnv_kernel.GhostNVKernel.init(allocator),
        };
        
        // Initialize CUDA if enabled
        if (config.CONFIG_GHOSTNV_CUDA) {
            driver.cuda = try ghostnv_cuda.GhostNVCUDA.init(allocator);
        }
        
        // Initialize NVENC if enabled
        if (config.CONFIG_GHOSTNV_NVENC) {
            driver.nvenc = try ghostnv_nvenc.GhostNVNVENC.init(allocator);
        }
        
        // Initialize Vibrance if enabled
        if (config.CONFIG_GHOSTNV_VIBRANCE) {
            driver.vibrance = try ghostnv_vibrance.GhostNVVibrance.init(allocator);
        }
        
        return driver;
    }
    
    pub fn deinit(self: *GhostNVDriver) void {
        self.core.deinit();
        self.hal.deinit();
        self.kernel_integration.deinit();
        
        if (self.cuda) |*cuda| cuda.deinit();
        if (self.nvenc) |*nvenc| nvenc.deinit();
        if (self.vibrance) |*vibrance| vibrance.deinit();
    }
    
    pub fn detectGPUs(self: *GhostNVDriver) !void {
        return self.core.detectGPUs();
    }
    
    pub fn initializeGPU(self: *GhostNVDriver, device_id: u32) !void {
        return self.core.initializeGPU(device_id);
    }
    
    // Gaming performance optimizations
    pub fn enableGamingMode(self: *GhostNVDriver) !void {
        if (config.CONFIG_GHOSTNV_GAMING) {
            return self.core.enableGamingMode();
        }
    }
    
    // Digital vibrance control
    pub fn setVibrance(self: *GhostNVDriver, level: i8) !void {
        if (self.vibrance) |*vibrance| {
            return vibrance.setLevel(level);
        }
    }
    
    // CUDA runtime
    pub fn launchCUDAKernel(self: *GhostNVDriver, kernel: []const u8, params: []const u8) !void {
        if (self.cuda) |*cuda| {
            return cuda.launchKernel(kernel, params);
        }
    }
    
    // NVENC encoding
    pub fn encodeFrame(self: *GhostNVDriver, frame_data: []const u8) ![]u8 {
        if (self.nvenc) |*nvenc| {
            return nvenc.encodeFrame(frame_data);
        }
        return error.NVENCNotAvailable;
    }
};