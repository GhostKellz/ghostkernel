# Linux Ghost Integration Guide

## GhostNV Repository Structure Issues

The GhostNV dependency is missing key files that the build system expects:

### Missing Files:
1. `zig/ghostnv.zig` - Main module entry point
2. `zig-nvidia/tools/ghostvibrance.zig` - GhostVibrance tool
3. `zig-nvidia/tools/test-nvenc.zig` - NVENC test tool

### Current Status:
✅ **build.zig** - Fixed unused variables  
✅ **build.zig.zon** - Compatible with Zig 0.15  
❌ **Missing module files** - Core integration files not present  
❌ **Missing tool files** - CLI tools not implemented  

### Required GhostNV Repository Structure:
```
ghostnv/
├── build.zig (✅ Fixed)
├── build.zig.zon (✅ Fixed)
├── zig/
│   └── ghostnv.zig (❌ Missing - create this)
├── zig-nvidia/
│   └── tools/
│       ├── ghostvibrance.zig (❌ Missing - create this)
│       └── test-nvenc.zig (❌ Missing - create this)
└── src/
    └── main.zig (exists)
```

### Create Missing Files:

#### `zig/ghostnv.zig` - Main module:
```zig
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const GhostNVDriver = struct {
    initialized: bool = false,
    gaming_mode: bool = false,
    vrr_enabled: bool = false,
    vibrance_level: u8 = 50,
    
    pub fn init() !GhostNVDriver {
        return GhostNVDriver{
            .initialized = true,
        };
    }
    
    pub fn deinit(self: *GhostNVDriver) void {
        self.initialized = false;
    }
    
    pub fn enableGaming(self: *GhostNVDriver) !void {
        if (!self.initialized) return error.NotInitialized;
        self.gaming_mode = true;
        // TODO: Implement gaming optimizations
    }
    
    pub fn setVibrance(self: *GhostNVDriver, level: u8) !void {
        if (!self.initialized) return error.NotInitialized;
        self.vibrance_level = level;
        // TODO: Implement digital vibrance control
    }
    
    pub fn enableVRR(self: *GhostNVDriver, enable: bool) !void {
        if (!self.initialized) return error.NotInitialized;
        self.vrr_enabled = enable;
        // TODO: Implement VRR control
    }
    
    pub fn enableGSync(self: *GhostNVDriver, enable: bool) !void {
        if (!self.initialized) return error.NotInitialized;
        _ = enable;
        // TODO: Implement G-Sync control
    }
};

// Export for kernel integration
pub const ghostnv_driver = GhostNVDriver;
```

#### `zig-nvidia/tools/ghostvibrance.zig` - Digital vibrance tool:
```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: ghostvibrance <level>\n");
        std.debug.print("  level: 0-100 (50 is default)\n");
        return;
    }

    const level = std.fmt.parseInt(u8, args[1], 10) catch {
        std.debug.print("Error: Invalid vibrance level\n");
        return;
    };

    if (level > 100) {
        std.debug.print("Error: Vibrance level must be 0-100\n");
        return;
    }

    std.debug.print("Setting digital vibrance to {}%\n", .{level});
    // TODO: Implement actual vibrance control
}
```

#### `zig-nvidia/tools/test-nvenc.zig` - NVENC test tool:
```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("GhostNV NVENC Test\n");
    std.debug.print("==================\n");
    
    // TODO: Implement NVENC functionality tests
    std.debug.print("Testing NVENC initialization...\n");
    std.debug.print("Testing H.264 encoding...\n");
    std.debug.print("Testing H.265 encoding...\n");
    std.debug.print("Testing AV1 encoding...\n");
    
    std.debug.print("All tests passed!\n");
}
```

### Next Steps:
1. Create the missing files in the GhostNV repository
2. Test compilation with `zig build`
3. Test kernel integration with `zig build -Dgpu=true -Dnvidia=true`
4. Implement actual driver functionality (not just stubs)

### Linux Ghost Kernel Integration:
Once the missing files are created, the kernel should be able to:
- Import the `ghostnv` module
- Build with GPU support enabled
- Access driver functions for gaming optimizations
- Use GhostVibrance and NVENC tools