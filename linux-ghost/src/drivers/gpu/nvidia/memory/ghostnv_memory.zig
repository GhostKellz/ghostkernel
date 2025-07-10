const std = @import("std");
const ghostnv = @import("ghostnv");

pub const GhostNVMemory = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    gpu_memory_base: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }
    
    pub fn allocateGpuMemory(self: *Self, size: usize) !u64 {
        _ = self;
        _ = size;
        return 0;
    }
    
    pub fn freeGpuMemory(self: *Self, addr: u64, size: usize) void {
        _ = self;
        _ = addr;
        _ = size;
    }
};