# GhostNV as a Dependency

This guide covers how to integrate GhostNV as a dependency in your Zig kernel project, particularly for **GhostKernel** integration.

## Adding GhostNV as a Dependency

### Method 1: Using Zig Package Manager

Add to your project's `build.zig.zon`:

```zig
.{
    .name = "ghostkernel",
    .version = "1.0.0",
    .dependencies = .{
        .ghostnv = .{
            .url = "https://github.com/ghostkellz/ghostnv",
            // Hash will be automatically computed by zig fetch
        },
    },
}
```

Then fetch the dependency:
```bash
zig fetch --save https://github.com/ghostkellz/ghostnv
```

### Method 2: Git Submodule

```bash
git submodule add https://github.com/ghostkellz/ghostnv.git deps/ghostnv
git submodule update --init --recursive
```

## Integration in Your Kernel's build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add GhostNV dependency
    const ghostnv_dep = b.dependency("ghostnv", .{
        .target = target,
        .optimize = optimize,
    });
    
    const ghostnv_mod = ghostnv_dep.module("ghostnv");

    // Your kernel executable
    const kernel_exe = b.addExecutable(.{
        .name = "ghostkernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ghostnv", .module = ghostnv_mod },
            },
        }),
    });

    b.installArtifact(kernel_exe);
}
```

## Using GhostNV in Your Kernel Code

### Basic Integration

```zig
const std = @import("std");
const ghostnv = @import("ghostnv");

// Initialize the NVIDIA driver integration
pub fn init_nvidia_driver(allocator: std.mem.Allocator, kernel_ctx: *anyopaque) !void {
    // Initialize GhostNV driver for kernel integration
    const driver = try ghostnv.init_for_ghostkernel(allocator, kernel_ctx);
    defer driver.deinit();
    
    // The driver is now integrated with your kernel
    std.log.info("GhostNV driver initialized successfully");
}
```

### Advanced Kernel Integration

```zig
const std = @import("std");
const ghostnv = @import("ghostnv");

pub const KernelNvidiaManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    ghostnv_driver: *ghostnv.GhostKernelIntegration,
    
    pub fn init(allocator: std.mem.Allocator, kernel_ctx: *anyopaque) !Self {
        const driver = try ghostnv.init_for_ghostkernel(allocator, kernel_ctx);
        
        return Self{
            .allocator = allocator,
            .ghostnv_driver = driver,
        };
    }
    
    pub fn deinit(self: *Self) void {
        try ghostnv.kernel.GhostKernelAPI.ghostnv_shutdown(self.ghostnv_driver);
    }
    
    pub fn handle_interrupt(self: *Self, vector: u32) void {
        self.ghostnv_driver.handleInterrupt(vector);
    }
    
    pub fn suspend(self: *Self) !void {
        try self.ghostnv_driver.suspendDriver();
    }
    
    pub fn resume(self: *Self) !void {
        try self.ghostnv_driver.resumeDriver();
    }
    
    pub fn get_stats(self: *Self) ghostnv.kernel.DriverStats {
        return self.ghostnv_driver.getDriverStats();
    }
};
```

### Device Management

```zig
const std = @import("std");
const ghostnv = @import("ghostnv");

pub fn manage_gpu_devices(nvidia_manager: *KernelNvidiaManager) !void {
    // Create device nodes for GPU access
    const device_node = try nvidia_manager.ghostnv_driver.createDeviceNode(0);
    defer nvidia_manager.ghostnv_driver.destroyDeviceNode(device_node);
    
    // Device is now available for userspace applications
    std.log.info("GPU device node created: /dev/nvidia0");
}
```

## Available Modules and APIs

### Core Modules
- `ghostnv.kernel` - Kernel integration layer
- `ghostnv.driver` - Low-level driver interface
- `ghostnv.display` - Display engine management
- `ghostnv.video` - Video encoding/decoding (NVENC/NVDEC)
- `ghostnv.audio` - RTX Voice audio processing
- `ghostnv.cuda` - CUDA compute runtime
- `ghostnv.memory` - GPU memory management
- `ghostnv.command` - Command processing

### Key Types
- `GhostKernelIntegration` - Main driver integration struct
- `GhostKernelAPI` - High-level API functions
- `NvidiaKernelModule` - Low-level kernel module interface
- `DriverStats` - Performance and usage statistics

### Key Functions
- `ghostnv.init_for_ghostkernel()` - Initialize for kernel integration
- `GhostKernelAPI.ghostnv_init()` - Low-level initialization
- `GhostKernelAPI.ghostnv_shutdown()` - Clean shutdown
- `GhostKernelAPI.ghostnv_suspend()` - System suspend support
- `GhostKernelAPI.ghostnv_resume()` - System resume support

## Hardware Support

### Recommended GPUs
- **RTX 40 Series** (Ada Lovelace) - Full Pure Zig driver support
- **RTX 30 Series** (Ampere) - Hybrid mode recommended
- **RTX 20 Series** (Turing) - Legacy compatibility mode

### Architecture Detection
The driver automatically detects GPU architecture and selects optimal configuration:

```zig
// Driver automatically chooses best mode based on detected hardware
const driver = try ghostnv.init_for_ghostkernel(allocator, kernel_ctx);

// Get detected configuration
const stats = driver.getDriverStats();
std.log.info("GPU utilization: {d}%", .{stats.gpu_utilization});
```

## Performance Considerations

### Memory Management
- GhostNV handles GPU memory allocation automatically
- Integrates with your kernel's memory subsystem
- Supports IOMMU and DMA operations

### Interrupt Handling
- Routes GPU interrupts to appropriate subsystems
- Supports MSI/MSI-X interrupt modes
- Low-latency interrupt processing

### Power Management
- Automatic GPU power state management
- Suspend/resume support for system power management
- Thermal management integration

## Troubleshooting

### Build Issues
```bash
# If dependency fetch fails
zig fetch --save https://github.com/ghostkellz/ghostnv

# Clean build cache
rm -rf .zig-cache zig-out/

# Rebuild with debug info
zig build -Doptimize=Debug
```

### Runtime Issues
```zig
// Enable debug logging in your kernel
const ghostnv = @import("ghostnv");

// Check driver status
const stats = driver.getDriverStats();
if (stats.gpu_utilization == 0) {
    std.log.warn("GPU may not be properly initialized");
}
```

### Dependency Conflicts
- Ensure no conflicting NVIDIA drivers are loaded
- Check that kernel headers match your running kernel
- Verify Zig compiler version compatibility (requires 0.15.0+)

## License and Legal

GhostNV is GPL-compatible for kernel integration. When using as a dependency:

- Your kernel can use any compatible license
- Binary redistribution follows GPL requirements
- Commercial use is permitted under GPL terms

## Support and Updates

- **Repository**: https://github.com/ghostkellz/ghostnv
- **Issues**: Report integration issues on GitHub
- **Updates**: Dependency will auto-update via Zig package manager
- **Documentation**: See README.md and INSTALL.md for detailed setup

This dependency integration provides your kernel with full NVIDIA GPU support, including display, compute, video processing, and audio acceleration capabilities.