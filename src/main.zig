const std = @import("std");
const linux_ghost = @import("linux_ghost");

pub fn main() !void {
    try linux_ghost.printBanner();
    
    const version = linux_ghost.getVersion();
    const version_str = try version.toString(std.heap.page_allocator);
    defer std.heap.page_allocator.free(version_str);
    
    std.debug.print("Ghost Kernel Version: {s}\n", .{version_str});
    std.debug.print("Pure Zig Linux 6.15.5 Port\n");
    std.debug.print("\nAvailable commands:\n");
    std.debug.print("  zig build                    # Build Ghost Kernel (default)\n");
    std.debug.print("  zig build ghost              # Build Ghost Kernel\n");
    std.debug.print("  zig build run                # Run Ghost Kernel in QEMU\n");
    std.debug.print("  zig build test               # Run kernel tests\n");
    std.debug.print("  zig build info               # Show this information\n");
    std.debug.print("  zig build gbuild             # Run kernel builder utility\n");
    std.debug.print("\nFeatures:\n");
    std.debug.print("  • Pure Zig implementation (memory safe)\n");
    std.debug.print("  • BORE-EEVDF scheduler (gaming optimized)\n");
    std.debug.print("  • Linux 6.15.5 compatibility\n");
    std.debug.print("  • AMD Zen 4 optimizations\n");
    std.debug.print("  • High-performance gaming focus\n");
    std.debug.print("\nFor more information, see README.md\n");
}
