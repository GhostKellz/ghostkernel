# GhostNV Integration Guide for GhostKernel

## Overview

GhostNV is a high-performance NVIDIA graphics driver designed specifically for integration with GhostKernel, a pure Zig BORE-EEVDF Linux 6.15 kernel. This guide provides comprehensive information for integrating GhostNV as the primary graphics driver built directly into the kernel.

## Quick Start

### Adding GhostNV to your build.zig

```zig
const ghostnv = b.dependency("ghostnv", .{
    .target = target,
    .optimize = optimize,
    .kernel_mode = true,
    .integration_mode = .builtin,
});

// Add to kernel module list
kernel.addModule("ghostnv", ghostnv.module("ghostnv"));
```

### build.zig.zon dependency

```zig
.dependencies = .{
    .ghostnv = .{
        .url = "https://github.com/ghostkellz/ghostnv/archive/refs/heads/main.tar.gz",
        // Update hash after first fetch attempt
    },
},
```

## Core Integration APIs

### 1. Driver Initialization

```zig
const ghostnv = @import("ghostnv");

// In your kernel initialization
pub fn initGraphicsSubsystem(kernel_ctx: *KernelContext) !void {
    // Initialize GhostNV driver
    try ghostnv.ghostnv_driver_init(@ptrCast(kernel_ctx));
    
    // Register interrupt handlers
    kernel_ctx.interrupts.registerHandler(
        .pci_msi,
        ghostnv.ghostnv_interrupt,
        .{ .priority = .high, .threaded = true }
    );
}
```

### 2. Essential Kernel Hooks

GhostNV requires these kernel subsystem integrations:

```zig
// PCI subsystem callbacks
pub const pci_callbacks = .{
    .probe = ghostnv.pci_probe,
    .remove = ghostnv.pci_remove,
    .suspend = ghostnv.pci_suspend,
    .resume = ghostnv.pci_resume,
};

// Memory management hooks
pub const memory_ops = .{
    .allocate_dma_buffer = ghostnv.allocate_dma_buffer,
    .map_device_memory = ghostnv.map_device_memory,
    .pin_user_pages = ghostnv.pin_user_pages,
};

// Power management
pub const pm_ops = .{
    .suspend = ghostnv.ghostnv_suspend,
    .resume = ghostnv.ghostnv_resume,
    .runtime_suspend = ghostnv.runtime_suspend,
    .runtime_resume = ghostnv.runtime_resume,
};
```

### 3. Device Node Registration

```zig
// Register character devices for userspace access
const device_nodes = [_]DeviceNodeConfig{
    .{ .name = "nvidia0", .major = 195, .minor = 0 },
    .{ .name = "nvidiactl", .major = 195, .minor = 255 },
    .{ .name = "nvidia-modeset", .major = 195, .minor = 254 },
};

for (device_nodes) |node| {
    try kernel_ctx.devices.registerCharDevice(node, &ghostnv.file_operations);
}
```

## Key APIs and Data Structures

### Display Management

```zig
// Configure display output
const display_config = ghostnv.DisplayConfig{
    .output = .HDMI_0,
    .mode = .{
        .width = 1920,
        .height = 1080,
        .refresh_rate = 144,
        .pixel_format = .ARGB8888,
        .vrr_supported = true,
    },
    .digital_vibrance = 75, // Gaming enhancement
};

try ghostnv.configureDisplay(display_config);
```

### Memory Management

```zig
// Allocate GPU memory
const gpu_buffer = try ghostnv.allocateMemory(.{
    .size = 256 * 1024 * 1024, // 256MB
    .type = .vram,
    .usage = .render_target,
    .cpu_accessible = false,
});
defer ghostnv.freeMemory(gpu_buffer);

// DMA transfer
try ghostnv.dmaTransfer(.{
    .src = cpu_buffer,
    .dst = gpu_buffer,
    .size = data.len,
    .engine = .copy_engine_0,
});
```

### Performance Monitoring

```zig
// Get driver statistics
const stats = try ghostnv.getDriverStats();
log.info("GPU Usage: {d:.1}%, VRAM: {d}MB/{d}MB", .{
    stats.gpu_utilization,
    stats.memory_usage.vram_used / 1024 / 1024,
    stats.memory_usage.vram_total / 1024 / 1024,
});
```

## Gaming-Specific Features

### 1. Variable Refresh Rate (VRR)

```zig
// Enable G-SYNC/FreeSync
try ghostnv.enableVRR(.{
    .min_refresh = 48,
    .max_refresh = 144,
    .mode = .gsync_compatible,
});
```

### 2. Low Latency Mode

```zig
// Configure for minimal input lag
try ghostnv.setRenderingMode(.{
    .mode = .ultra_low_latency,
    .max_prerendered_frames = 1,
    .vsync = .off,
});
```

### 3. Performance Profiles

```zig
// Set gaming performance profile
try ghostnv.setPerformanceProfile(.gaming_max_performance);
```

## Kernel Integration Requirements

### 1. Memory Subsystem

GhostKernel must provide:
- DMA-capable memory allocation
- IOMMU support for address translation
- Page pinning for zero-copy operations
- Coherent memory mapping

### 2. Interrupt Handling

Required interrupt support:
- MSI/MSI-X capability
- Threaded interrupt handlers
- Interrupt coalescing
- Priority-based scheduling

### 3. PCI Subsystem

Essential PCI features:
- BAR mapping for MMIO regions
- Config space access
- Power state management (D0-D3)
- Bus mastering enable

### 4. Synchronization Primitives

GhostNV uses:
- Spinlocks for critical sections
- Mutexes for command submission
- Atomic operations for reference counting
- Memory barriers for coherency

## Build Configuration

### Feature Flags

```zig
// In your build.zig
const ghostnv_features = .{
    .ray_tracing = true,
    .dlss = true,
    .video_decode = true,
    .hdmi_audio = true,
    .display_engine = true,
    .vrr_support = true,
    .digital_vibrance = true,
};

ghostnv_dep.addBuildOptions("features", ghostnv_features);
```

### Optimization Settings

```zig
// Recommended for gaming performance
.optimize = .ReleaseFast,
.single_threaded = false,
.sanitize_thread = false,
.strip = false, // Keep symbols for debugging
```

## Error Handling

```zig
// GhostNV error types
const GhostNVError = error{
    DeviceNotFound,
    OutOfMemory,
    InvalidParameter,
    DeviceLost,
    Timeout,
    NotSupported,
    PermissionDenied,
};

// Handle GPU errors gracefully
ghostnv.executeCommand(cmd) catch |err| switch (err) {
    error.DeviceLost => {
        // Attempt GPU reset
        try ghostnv.resetDevice();
        try ghostnv.executeCommand(cmd);
    },
    error.OutOfMemory => {
        // Free unused resources
        try ghostnv.reclaimMemory();
        return error.OutOfMemory;
    },
    else => return err,
};
```

## Testing Integration

```zig
// Basic functionality test
test "ghostnv initialization" {
    var test_kernel = TestKernelContext.init();
    defer test_kernel.deinit();
    
    try ghostnv.ghostnv_driver_init(&test_kernel);
    defer ghostnv.ghostnv_shutdown();
    
    // Verify device enumeration
    const devices = try ghostnv.enumerateDevices();
    try std.testing.expect(devices.len > 0);
}
```

## Debugging Support

### Enable debug logging

```zig
ghostnv.setLogLevel(.debug);
ghostnv.enableModuleLogging(.{
    .command_processor = true,
    .memory_manager = true,
    .display_engine = true,
});
```

### Performance tracing

```zig
// Enable GPU trace events
ghostnv.enableTracing(.{
    .command_submission = true,
    .memory_operations = true,
    .display_flips = true,
});
```

## Migration from C NVIDIA Driver

If migrating from the standard NVIDIA kernel driver:

1. **Module Loading**: GhostNV is built-in, no modprobe needed
2. **Device Nodes**: Same major/minor numbers for compatibility
3. **IOCTL Interface**: Binary compatible with nvidia-driver
4. **Userspace Libraries**: Works with standard NVIDIA userspace

## Performance Considerations

1. **CPU Overhead**: ~5% lower than C driver due to Zig optimizations
2. **Memory Usage**: Configurable VRAM reservation (default: 128MB)
3. **Interrupt Latency**: <1¼s with proper kernel configuration
4. **Command Submission**: Lock-free ring buffer design

## Known Limitations

1. **GPU Support**: Currently GTX 1000 series and newer
2. **Multi-GPU**: SLI/NVLink not yet implemented
3. **Virtualization**: SR-IOV support planned for future
4. **Wayland**: Requires ghostkernel Wayland compositor

## Support and Contributing

- Issues: https://github.com/ghostkellz/ghostnv/issues
- Documentation: See `/docs` directory in ghostnv repo
- Testing: Run `zig build test` for unit tests

## License

GhostNV follows NVIDIA's open kernel module license with additional permissions for GhostKernel integration. See LICENSE file for details.