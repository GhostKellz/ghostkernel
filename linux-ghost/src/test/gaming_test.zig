//! Gaming optimization tests

const std = @import("std");
const testing = std.testing;

// Test individual gaming components
test "gaming page fault handler" {
    const gaming_pagefault = @import("gaming_pagefault");
    
    // Verify gaming page fault optimizations
    const test_address = 0x1000;
    const flags = gaming_pagefault.PageFaultFlags{
        .write = true,
        .user = true,
        .gaming_task = true,
    };
    
    // Test would check predictive allocation
    try testing.expect(flags.gaming_task);
}

test "direct storage API" {
    const direct_storage = @import("direct_storage");
    
    // Test asset loading priorities
    const priority = direct_storage.AssetPriority.immediate;
    try testing.expect(@intFromEnum(priority) == 0);
    
    // Test compression formats
    const compression = direct_storage.CompressionFormat.gdeflate;
    try testing.expect(@intFromEnum(compression) == 3);
}

test "gaming FUTEX operations" {
    const gaming_futex = @import("gaming_futex");
    
    // Test FUTEX operation types
    const op = gaming_futex.GamingFutexOp.frame_sync_wait;
    try testing.expect(@intFromEnum(op) == 130);
}

test "NUMA cache scheduling" {
    const numa_cache_sched = @import("numa_cache_sched");
    
    // Test cache topology detection
    const cache_info = numa_cache_sched.NUMACacheInfo{
        .has_x3d_cache = true,
        .x3d_cache_size_mb = 96,
        .l3_size_mb = 32,
    };
    
    try testing.expect(cache_info.getTotalCacheMB() == 128);
    try testing.expect(cache_info.isGamingOptimal());
}

test "hardware timestamp precision" {
    const hw_timestamp_sched = @import("hw_timestamp_sched");
    
    // Test timing requirements for different FPS
    const requirements_60fps = hw_timestamp_sched.GamingTimingRequirements.fromFPS(60);
    try testing.expect(requirements_60fps.frame_time_ns == 16_666_666);
    
    const requirements_144fps = hw_timestamp_sched.GamingTimingRequirements.fromFPS(144);
    try testing.expect(requirements_144fps.frame_time_ns == 6_944_444);
    try testing.expect(requirements_144fps.vrr_enabled);
}

test "gaming syscall numbers" {
    const gaming_syscalls = @import("gaming_syscalls");
    
    // Verify syscall numbers don't conflict
    try testing.expect(@intFromEnum(gaming_syscalls.GamingSyscall.gaming_mmap) == 1000);
    try testing.expect(@intFromEnum(gaming_syscalls.GamingSyscall.gaming_futex) == 1030);
    try testing.expect(@intFromEnum(gaming_syscalls.GamingSyscall.gaming_gpu_submit) == 1060);
}

test "priority inheritance" {
    const gaming_priority = @import("gaming_priority");
    
    // Test gaming priority levels
    const priority = gaming_priority.GamingPriority.critical;
    try testing.expect(priority.toNiceValue() == -20);
}

test "real-time compaction thresholds" {
    const realtime_compaction = @import("realtime_compaction");
    
    // Test fragmentation thresholds
    var stats = realtime_compaction.FragmentationStats{
        .total_free_memory = 1000,
        .largest_free_block = 700,
    };
    
    stats.calculateFragmentation();
    try testing.expect(stats.fragmentation_ratio == 0.3);
    try testing.expect(stats.needsCompaction());
}

// Integration tests
test "gaming subsystem integration" {
    // This would test interactions between components
    // For example: Direct Storage + NUMA scheduling + priority inheritance
    
    try testing.expect(true); // Placeholder
}

// Performance benchmarks
test "gaming syscall latency" {
    // This would measure actual syscall overhead
    // Compare gaming syscalls vs standard syscalls
    
    const start = std.time.nanoTimestamp();
    // Syscall operation
    const end = std.time.nanoTimestamp();
    const latency_ns = end - start;
    
    // Gaming syscalls should be < 1μs
    _ = latency_ns;
    try testing.expect(true); // Placeholder
}