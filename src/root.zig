//! Ghost Kernel Library - Pure Zig Linux 6.15.5 Port
const std = @import("std");

pub const Version = struct {
    major: u32 = 6,
    minor: u32 = 15,
    patch: u32 = 5,
    ghost: []const u8 = "1.0.0-zig",
    
    pub fn toString(self: Version, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{}.{}.{}-ghost-{s}", .{
            self.major, self.minor, self.patch, self.ghost
        });
    }
};

pub const BuildConfig = struct {
    optimize: bool = true,
    debug: bool = false,
    cpu_arch: CPUArch = .znver4,
    bore_scheduler: bool = true,
    gaming_optimizations: bool = true,
    memory_safety: bool = true,
    
    pub const CPUArch = enum {
        znver4,     // AMD Zen 4 (default)
        znver3,     // AMD Zen 3
        skylake,    // Intel Skylake
        generic,    // Generic x86_64
        
        pub fn toString(self: CPUArch) []const u8 {
            return switch (self) {
                .znver4 => "znver4",
                .znver3 => "znver3",
                .skylake => "skylake", 
                .generic => "x86-64",
            };
        }
    };
    
    pub fn init() BuildConfig {
        return BuildConfig{};
    }
};

pub fn getVersion() Version {
    return Version{};
}

pub fn printBanner() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\
        \\  _____ _               _      _  __                    _ 
        \\ |  ___| |             | |    | |/ /                   | |
        \\ | |__ | |__   __ _ ___| |_   | ' / ___ _ __ _ __   ___| |
        \\ |  __|| '_ \ / _` / __| __|  |  < / _ \ '__| '_ \ / _ \ |
        \\ | |___| | | | (_| \__ \ |_   | . \  __/ |  | | | |  __/ |
        \\ \____/|_| |_|\__,_|___/\__|  |_|\_\___|_|  |_| |_|\___|_|
        \\
        \\🚀 Ghost Kernel - Pure Zig Linux 6.15.5 Port
        \\================================================
        \\
        \\Memory-safe, high-performance kernel for gaming
        \\Built with Zig for ultimate safety and speed
        \\
        \\
    );
}

pub const Features = struct {
    pub const BORE_EEVDF = "BORE-Enhanced EEVDF scheduler for gaming";
    pub const MEMORY_SAFETY = "Compile-time memory safety guarantees";
    pub const GAMING_OPT = "Low-latency optimizations for gaming";
    pub const ZEN4_OPT = "AMD Zen 4 CPU-specific optimizations";
    pub const LINUX_COMPAT = "Linux 6.15.5 system call compatibility";
};

test "version string generation" {
    const version = getVersion();
    const version_str = try version.toString(std.testing.allocator);
    defer std.testing.allocator.free(version_str);
    
    try std.testing.expect(std.mem.indexOf(u8, version_str, "6.15.5-ghost") != null);
    try std.testing.expect(std.mem.indexOf(u8, version_str, "zig") != null);
}

test "build config creation" {
    const config = BuildConfig.init();
    try std.testing.expect(config.bore_scheduler);
    try std.testing.expect(config.memory_safety);
    try std.testing.expect(config.gaming_optimizations);
}
