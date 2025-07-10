const std = @import("std");
const ghostnv = @import("ghostnv");

pub const GhostNVSyscalls = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }
    
    pub fn handleSyscall(self: *Self, syscall_num: u64, args: []u64) !u64 {
        _ = self;
        _ = syscall_num;
        _ = args;
        return 0;
    }
};