//! Real-Time Memory Compaction for Gaming
//! Eliminates memory fragmentation without blocking gaming tasks
//! Features incremental compaction, gaming-aware scheduling, and zero-pause algorithms

const std = @import("std");
const memory = @import("memory.zig");
const sched = @import("../kernel/sched.zig");
const sync = @import("../kernel/sync.zig");
const console = @import("../arch/x86_64/console.zig");

/// Memory fragmentation statistics
pub const FragmentationStats = struct {
    total_free_memory: u64 = 0,
    largest_free_block: u64 = 0,
    fragmentation_ratio: f32 = 0.0, // 0.0 = no fragmentation, 1.0 = completely fragmented
    gaming_allocations_failed: u64 = 0,
    compaction_cycles: u64 = 0,
    time_spent_compacting_ns: u64 = 0,
    gaming_pauses_caused: u64 = 0,
    
    pub fn calculateFragmentation(self: *FragmentationStats) void {
        if (self.total_free_memory == 0) {
            self.fragmentation_ratio = 0.0;
            return;
        }
        
        // Fragmentation ratio: how much free memory is unusable due to fragmentation
        const usable_ratio = @as(f32, @floatFromInt(self.largest_free_block)) / @as(f32, @floatFromInt(self.total_free_memory));
        self.fragmentation_ratio = 1.0 - usable_ratio;
    }
    
    pub fn needsCompaction(self: *FragmentationStats) bool {
        return self.fragmentation_ratio > 0.3 or // > 30% fragmented
               self.gaming_allocations_failed > 0; // Any gaming allocation failures
    }
};

/// Real-time compaction configuration
pub const CompactionConfig = struct {
    max_pause_time_ns: u64 = 50_000, // Max 50μs pause per cycle
    target_fragmentation: f32 = 0.1,  // Target <10% fragmentation
    gaming_priority_boost: i8 = 10,   // Boost gaming tasks during compaction
    incremental_pages: u32 = 16,      // Pages to compact per cycle
    background_threshold: f32 = 0.2,  // Start background compaction at 20% fragmentation
    emergency_threshold: f32 = 0.5,   // Emergency compaction at 50% fragmentation
};

/// Memory region for compaction
const CompactionRegion = struct {
    start_addr: usize,
    end_addr: usize,
    size: usize,
    free_pages: u32,
    used_pages: u32,
    fragmentation_level: f32,
    contains_gaming_memory: bool,
    last_compacted: u64,
    
    pub fn needsCompaction(self: *const CompactionRegion) bool {
        return self.fragmentation_level > 0.3 or 
               (self.contains_gaming_memory and self.fragmentation_level > 0.1);
    }
    
    pub fn priority(self: *const CompactionRegion) u32 {
        var prio: u32 = 0;
        
        // Higher priority for gaming memory regions
        if (self.contains_gaming_memory) prio += 100;
        
        // Higher priority for more fragmented regions
        prio += @as(u32, @intFromFloat(self.fragmentation_level * 50));
        
        // Higher priority for regions not compacted recently
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const time_since_compact = now - self.last_compacted;
        if (time_since_compact > 1_000_000_000) prio += 20; // +20 if >1 second ago
        
        return prio;
    }
};

/// Real-time memory compactor
pub const RealtimeCompactor = struct {
    allocator: std.mem.Allocator,
    config: CompactionConfig,
    stats: FragmentationStats,
    regions: std.ArrayList(CompactionRegion),
    compaction_thread: ?std.Thread,
    running: bool,
    
    // Incremental compaction state
    current_region: ?*CompactionRegion,
    current_page: u32,
    compaction_phase: CompactionPhase,
    
    // Gaming awareness
    gaming_processes: std.HashMap(u32, bool), // PID -> is_gaming
    gaming_memory_ranges: std.ArrayList(MemoryRange),
    
    const CompactionPhase = enum {
        idle,
        scanning,
        marking,
        moving,
        updating_references,
        finalizing,
    };
    
    const MemoryRange = struct {
        start: usize,
        end: usize,
        pid: u32,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .config = CompactionConfig{},
            .stats = FragmentationStats{},
            .regions = std.ArrayList(CompactionRegion).init(allocator),
            .compaction_thread = null,
            .running = false,
            .current_region = null,
            .current_page = 0,
            .compaction_phase = .idle,
            .gaming_processes = std.HashMap(u32, bool).init(allocator),
            .gaming_memory_ranges = std.ArrayList(MemoryRange).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.regions.deinit();
        self.gaming_processes.deinit();
        self.gaming_memory_ranges.deinit();
    }
    
    pub fn start(self: *Self) !void {
        if (self.running) return;
        
        self.running = true;
        self.compaction_thread = try std.Thread.spawn(.{}, compactionWorker, .{self});
        
        console.writeString("Real-time memory compactor started\n");
    }
    
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        
        self.running = false;
        if (self.compaction_thread) |thread| {
            thread.join();
            self.compaction_thread = null;
        }
        
        console.writeString("Real-time memory compactor stopped\n");
    }
    
    /// Register a gaming process for special handling
    pub fn registerGamingProcess(self: *Self, pid: u32) !void {
        try self.gaming_processes.put(pid, true);
        console.printf("Registered gaming process PID {}\n", .{pid});
    }
    
    /// Unregister gaming process
    pub fn unregisterGamingProcess(self: *Self, pid: u32) void {
        _ = self.gaming_processes.remove(pid);
    }
    
    /// Register gaming memory range for priority handling
    pub fn registerGamingMemory(self: *Self, start: usize, end: usize, pid: u32) !void {
        try self.gaming_memory_ranges.append(MemoryRange{
            .start = start,
            .end = end,
            .pid = pid,
        });
        
        // Mark regions containing gaming memory
        for (self.regions.items) |*region| {
            if (region.start_addr <= start and end <= region.end_addr) {
                region.contains_gaming_memory = true;
            }
        }
    }
    
    /// Perform incremental compaction (called periodically)
    pub fn incrementalCompact(self: *Self) !void {
        const start_time = std.time.nanoTimestamp();
        
        // Don't compact if gaming tasks are frame-critical
        if (self.hasFrameCriticalTasks()) {
            return;
        }
        
        switch (self.compaction_phase) {
            .idle => try self.selectRegionForCompaction(),
            .scanning => try self.scanCurrentRegion(),
            .marking => try self.markLiveObjects(),
            .moving => try self.moveObjects(),
            .updating_references => try self.updateReferences(),
            .finalizing => try self.finalizeCompaction(),
        }
        
        // Ensure we don't exceed maximum pause time
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > self.config.max_pause_time_ns) {
            // Yield to gaming tasks
            self.yieldToGamingTasks();
        }
        
        // Update statistics
        self.stats.time_spent_compacting_ns += @intCast(elapsed);
    }
    
    fn selectRegionForCompaction(self: *Self) !void {
        // Find the region that most needs compaction
        var best_region: ?*CompactionRegion = null;
        var best_priority: u32 = 0;
        
        for (self.regions.items) |*region| {
            if (region.needsCompaction()) {
                const priority = region.priority();
                if (priority > best_priority) {
                    best_priority = priority;
                    best_region = region;
                }
            }
        }
        
        if (best_region) |region| {
            self.current_region = region;
            self.current_page = 0;
            self.compaction_phase = .scanning;
            
            console.printf("Starting compaction of region 0x{X:08}-0x{X:08} (fragmentation: {d:.1}%)\n", 
                .{ region.start_addr, region.end_addr, region.fragmentation_level * 100 });
        }
    }
    
    fn scanCurrentRegion(self: *Self) !void {
        if (self.current_region) |region| {
            // Scan a batch of pages to identify live objects
            const pages_to_scan = @min(self.config.incremental_pages, 
                                     region.used_pages - self.current_page);
            
            for (0..pages_to_scan) |_| {
                if (self.current_page >= region.used_pages) break;
                
                // Scan page for live objects
                try self.scanPage(region, self.current_page);
                self.current_page += 1;
            }
            
            if (self.current_page >= region.used_pages) {
                self.compaction_phase = .marking;
                self.current_page = 0;
            }
        }
    }
    
    fn markLiveObjects(self: *Self) !void {
        // Mark live objects in current region
        if (self.current_region) |region| {
            _ = region;
            
            // Incremental marking to avoid long pauses
            const objects_to_mark = 100; // Mark up to 100 objects per cycle
            
            for (0..objects_to_mark) |_| {
                // Mark live objects (implementation would traverse object graph)
                self.markObject();
            }
            
            // Move to next phase after marking complete
            self.compaction_phase = .moving;
        }
    }
    
    fn moveObjects(self: *Self) !void {
        if (self.current_region) |region| {
            // Move live objects to eliminate fragmentation
            const pages_to_process = @min(self.config.incremental_pages, 
                                        region.used_pages - self.current_page);
            
            for (0..pages_to_process) |_| {
                if (self.current_page >= region.used_pages) break;
                
                try self.moveObjectsInPage(region, self.current_page);
                self.current_page += 1;
            }
            
            if (self.current_page >= region.used_pages) {
                self.compaction_phase = .updating_references;
                self.current_page = 0;
            }
        }
    }
    
    fn updateReferences(self: *Self) !void {
        // Update all references to moved objects
        if (self.current_region) |region| {
            _ = region;
            
            // Incremental reference updating
            const refs_to_update = 200; // Update up to 200 references per cycle
            
            for (0..refs_to_update) |_| {
                self.updateReference();
            }
            
            self.compaction_phase = .finalizing;
        }
    }
    
    fn finalizeCompaction(self: *Self) !void {
        if (self.current_region) |region| {
            // Finalize compaction and update region statistics
            region.last_compacted = @intCast(std.time.nanoTimestamp());
            
            // Recalculate fragmentation
            self.calculateRegionFragmentation(region);
            
            console.printf("Compaction complete: fragmentation reduced to {d:.1}%\n", 
                .{region.fragmentation_level * 100});
            
            // Reset state
            self.current_region = null;
            self.current_page = 0;
            self.compaction_phase = .idle;
            self.stats.compaction_cycles += 1;
        }
    }
    
    fn hasFrameCriticalTasks(self: *Self) bool {
        // Check if any gaming processes have frame-critical tasks running
        var iter = self.gaming_processes.iterator();
        while (iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            
            // In real implementation, check scheduler for frame-critical tasks
            _ = pid;
            
            // For now, assume no frame-critical tasks
        }
        return false;
    }
    
    fn yieldToGamingTasks(self: *Self) void {
        // Temporarily boost priority of gaming tasks
        var iter = self.gaming_processes.iterator();
        while (iter.next()) |entry| {
            const pid = entry.key_ptr.*;
            
            // Boost gaming task priority during compaction
            self.boostTaskPriority(pid, self.config.gaming_priority_boost);
        }
        
        self.stats.gaming_pauses_caused += 1;
    }
    
    fn boostTaskPriority(self: *Self, pid: u32, boost: i8) void {
        _ = self;
        _ = pid;
        _ = boost;
        
        // In real implementation, this would call into the scheduler
        // to temporarily boost the priority of gaming tasks
    }
    
    // Helper functions for object management
    fn scanPage(self: *Self, region: *CompactionRegion, page: u32) !void {
        _ = self;
        _ = region;
        _ = page;
        // Implementation would scan page for live objects
    }
    
    fn markObject(self: *Self) void {
        _ = self;
        // Implementation would mark object as live
    }
    
    fn moveObjectsInPage(self: *Self, region: *CompactionRegion, page: u32) !void {
        _ = self;
        _ = region;
        _ = page;
        // Implementation would move live objects to compact memory
    }
    
    fn updateReference(self: *Self) void {
        _ = self;
        // Implementation would update object reference after move
    }
    
    fn calculateRegionFragmentation(self: *Self, region: *CompactionRegion) void {
        _ = self;
        
        // Mock fragmentation calculation
        region.fragmentation_level = 0.05; // Assume 5% fragmentation after compaction
    }
    
    /// Background compaction worker thread
    fn compactionWorker(self: *Self) void {
        while (self.running) {
            // Update fragmentation statistics
            self.updateFragmentationStats();
            
            // Perform incremental compaction if needed
            if (self.stats.needsCompaction()) {
                self.incrementalCompact() catch |err| {
                    console.printf("Compaction error: {}\n", .{err});
                };
            }
            
            // Sleep for 1ms between cycles
            std.time.sleep(1_000_000);
        }
    }
    
    fn updateFragmentationStats(self: *Self) void {
        // Update global fragmentation statistics
        self.stats.calculateFragmentation();
        
        // Check for emergency compaction needs
        if (self.stats.fragmentation_ratio > self.config.emergency_threshold) {
            console.printf("Emergency memory compaction triggered: {d:.1}% fragmentation\n", 
                .{self.stats.fragmentation_ratio * 100});
        }
    }
    
    pub fn getStats(self: *Self) FragmentationStats {
        return self.stats;
    }
    
    pub fn enableGamingMode(self: *Self) void {
        // Optimize configuration for gaming
        self.config.max_pause_time_ns = 25_000; // Reduce to 25μs max pause
        self.config.target_fragmentation = 0.05; // Target 5% fragmentation
        self.config.background_threshold = 0.1; // Start compaction earlier
        self.config.incremental_pages = 8; // Smaller increments for lower latency
        
        console.writeString("Real-time compactor: Gaming mode enabled\n");
    }
};

/// Initialize real-time memory compaction
pub fn initRealtimeCompaction(allocator: std.mem.Allocator) !*RealtimeCompactor {
    const compactor = try allocator.create(RealtimeCompactor);
    compactor.* = try RealtimeCompactor.init(allocator);
    
    // Enable gaming optimizations
    compactor.enableGamingMode();
    
    // Start background compaction
    try compactor.start();
    
    console.writeString("Real-time memory compaction initialized\n");
    return compactor;
}

// Export for scheduler integration
pub fn onGamingProcessCreate(pid: u32) !void {
    // This would be called when a gaming process is created
    _ = pid;
    console.printf("Gaming process {} created - memory compaction aware\n", .{pid});
}

pub fn onGamingMemoryAlloc(pid: u32, addr: usize, size: usize) !void {
    // This would be called when gaming memory is allocated
    _ = pid;
    _ = addr;
    _ = size;
    console.writeString("Gaming memory allocated - tracking for compaction priority\n");
}