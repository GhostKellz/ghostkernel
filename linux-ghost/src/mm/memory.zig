//! Linux ZGhost Memory Management
//! Pure Zig implementation with memory safety guarantees

const std = @import("std");
const console = @import("../arch/x86_64/console.zig");

/// Page size constants
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const PAGE_MASK: usize = PAGE_SIZE - 1;

/// Virtual memory layout constants
pub const KERNEL_VIRT_BASE: u64 = 0xFFFF800000000000; // Kernel virtual base address

/// Memory zone types
pub const ZoneType = enum {
    dma,        // DMA-able memory (0-16MB)
    normal,     // Normal memory (16MB-896MB)
    highmem,    // High memory (>896MB)
};

/// Page frame descriptor
pub const PageFrame = struct {
    pfn: u64,           // Page frame number
    flags: PageFlags,   // Page flags
    ref_count: u32,     // Reference count
    zone: ZoneType,     // Memory zone
    order: u8,          // Buddy allocator order
    
    // Linked list for free pages
    next: ?*PageFrame,
    prev: ?*PageFrame,
    
    const Self = @This();
    
    pub fn init(pfn: u64, zone: ZoneType) Self {
        return Self{
            .pfn = pfn,
            .flags = PageFlags{},
            .ref_count = 0,
            .zone = zone,
            .order = 0,
            .next = null,
            .prev = null,
        };
    }
    
    pub fn getPhysAddr(self: Self) u64 {
        return self.pfn << PAGE_SHIFT;
    }
    
    pub fn getVirtAddr(self: Self) u64 {
        return self.getPhysAddr() + KERNEL_VIRT_BASE;
    }
    
    pub fn isAllocated(self: Self) bool {
        return self.ref_count > 0;
    }
    
    pub fn isFree(self: Self) bool {
        return self.ref_count == 0;
    }
};

/// Page flags
pub const PageFlags = packed struct {
    locked: bool = false,
    has_error: bool = false,
    referenced: bool = false,
    uptodate: bool = false,
    dirty: bool = false,
    lru: bool = false,
    active: bool = false,
    slab: bool = false,
    writeback: bool = false,
    reclaim: bool = false,
    buddy: bool = false,
    mmap: bool = false,
    anon: bool = false,
    swapbacked: bool = false,
    unevictable: bool = false,
    mlocked: bool = false,
    _reserved: u48 = 0,
};

/// Memory zone descriptor
pub const Zone = struct {
    zone_type: ZoneType,
    start_pfn: u64,
    end_pfn: u64,
    present_pages: u64,
    managed_pages: u64,
    
    // Buddy allocator free lists (order 0-10)
    free_lists: [11]?*PageFrame,
    nr_free: [11]u64,
    
    // Zone statistics
    nr_alloc: u64,
    nr_free_pages: u64,
    watermarks: Watermarks,
    
    const Self = @This();
    
    pub const Watermarks = struct {
        min: u64,
        low: u64,
        high: u64,
    };
    
    pub fn init(zone_type: ZoneType, start_pfn: u64, end_pfn: u64) Self {
        return Self{
            .zone_type = zone_type,
            .start_pfn = start_pfn,
            .end_pfn = end_pfn,
            .present_pages = end_pfn - start_pfn,
            .managed_pages = end_pfn - start_pfn,
            .free_lists = [_]?*PageFrame{null} ** 11,
            .nr_free = [_]u64{0} ** 11,
            .nr_alloc = 0,
            .nr_free_pages = end_pfn - start_pfn,
            .watermarks = Watermarks{
                .min = (end_pfn - start_pfn) / 128,  // 0.78%
                .low = (end_pfn - start_pfn) / 64,   // 1.56%
                .high = (end_pfn - start_pfn) / 32,  // 3.125%
            },
        };
    }
    
    /// Allocate pages using buddy allocator
    pub fn allocPages(self: *Self, order: u8) ?*PageFrame {
        if (order > 10) return null;
        
        // Try to find free pages of requested order
        if (self.free_lists[order]) |page| {
            self.removeFreePageAtOrder(page, order);
            page.order = order;
            page.ref_count = 1;
            page.flags.buddy = false;
            
            self.nr_alloc += @as(u64, 1) << @as(u6, @intCast(order));
            self.nr_free_pages -= @as(u64, 1) << @as(u6, @intCast(order));
            
            return page;
        }
        
        // Split larger pages
        var split_order = order + 1;
        while (split_order <= 10) : (split_order += 1) {
            if (self.free_lists[split_order]) |large_page| {
                return self.splitPage(large_page, split_order, order);
            }
        }
        
        return null; // Out of memory
    }
    
    /// Free pages back to buddy allocator
    pub fn freePages(self: *Self, page: *PageFrame) void {
        const order = page.order;
        page.ref_count = 0;
        page.flags.buddy = true;
        
        self.nr_alloc -= @as(u64, 1) << order;
        self.nr_free_pages += @as(u64, 1) << order;
        
        // Try to merge with buddy
        self.mergeWithBuddy(page, order);
    }
    
    // Internal methods
    fn removeFreePageAtOrder(self: *Self, page: *PageFrame, order: u8) void {
        if (page.prev) |prev| {
            prev.next = page.next;
        } else {
            self.free_lists[order] = page.next;
        }
        
        if (page.next) |next| {
            next.prev = page.prev;
        }
        
        page.next = null;
        page.prev = null;
        self.nr_free[order] -= 1;
    }
    
    fn addFreePageAtOrder(self: *Self, page: *PageFrame, order: u8) void {
        page.next = self.free_lists[order];
        page.prev = null;
        
        if (self.free_lists[order]) |head| {
            head.prev = page;
        }
        
        self.free_lists[order] = page;
        self.nr_free[order] += 1;
    }
    
    fn splitPage(self: *Self, page: *PageFrame, from_order: u8, to_order: u8) ?*PageFrame {
        // Remove from current order
        self.removeFreePageAtOrder(page, from_order);
        
        var current_order = from_order;
        while (current_order > to_order) : (current_order -= 1) {
            // Create buddy page
            const buddy_pfn = page.pfn + (@as(u64, 1) << @as(u6, @intCast(current_order - 1)));
            const buddy = getBuddyPage(buddy_pfn) orelse return null;
            
            buddy.* = PageFrame.init(buddy_pfn, page.zone);
            buddy.order = current_order - 1;
            buddy.flags.buddy = true;
            
            // Add buddy to free list
            self.addFreePageAtOrder(buddy, current_order - 1);
        }
        
        page.order = to_order;
        page.ref_count = 1;
        page.flags.buddy = false;
        
        self.nr_alloc += @as(u64, 1) << @as(u6, @truncate(to_order));
        self.nr_free_pages -= @as(u64, 1) << @as(u6, @truncate(to_order));
        
        return page;
    }
    
    fn mergeWithBuddy(self: *Self, page: *PageFrame, order: u8) void {
        var current_page = page;
        var current_order = order;
        
        while (current_order < 10) {
            const buddy_pfn = getBuddyPfn(current_page.pfn, current_order);
            const buddy = getBuddyPage(buddy_pfn) orelse break;
            
            // Check if buddy is free and same order
            if (!buddy.flags.buddy or buddy.order != current_order) break;
            
            // Remove buddy from free list
            self.removeFreePageAtOrder(buddy, current_order);
            
            // Determine which page becomes the merged page
            if (current_page.pfn > buddy.pfn) {
                current_page = buddy;
            }
            
            current_order += 1;
        }
        
        // Add merged page to appropriate free list
        current_page.order = current_order;
        current_page.flags.buddy = true;
        self.addFreePageAtOrder(current_page, current_order);
    }
};

/// Virtual Memory Area
pub const VMA = struct {
    start: u64,
    end: u64,
    flags: VMAFlags,
    file: ?*anyopaque, // File pointer (would be *File in real implementation)
    offset: u64,
    
    // Linked list
    next: ?*VMA,
    prev: ?*VMA,
    
    pub const VMAFlags = packed struct {
        read: bool = false,
        write: bool = false,
        exec: bool = false,
        shared: bool = false,
        growsdown: bool = false,
        denywrite: bool = false,
        executable: bool = false,
        locked: bool = false,
        _reserved: u56 = 0,
    };
};

/// Memory management info (per-process)
pub const MemoryDescriptor = struct {
    vmas: ?*VMA,
    mmap_base: u64,
    start_code: u64,
    end_code: u64,
    start_data: u64,
    end_data: u64,
    start_brk: u64,
    brk: u64,
    start_stack: u64,
    
    // Memory statistics
    total_vm: u64,      // Total virtual memory
    locked_vm: u64,     // Locked virtual memory
    shared_vm: u64,     // Shared virtual memory
    exec_vm: u64,       // Executable virtual memory
    stack_vm: u64,      // Stack virtual memory
    
    // Reference count
    ref_count: u32,
};

// File placeholder
const File = struct {};

// Memory layout constants  
const USER_VIRT_MAX: u64 = 0x0000_7fff_ffff_f000;

// Global memory management state
var zones: [3]Zone = undefined;
var total_pages: u64 = 0;
var total_free_pages: u64 = 0;
var memory_initialized = false;

/// Initialize memory management
pub fn init() !void {
    console.writeString("Initializing memory management...\n");
    
    // TODO: Get actual memory map from bootloader
    const total_memory: u64 = 1024 * 1024 * 1024; // 1GB for testing
    total_pages = total_memory / PAGE_SIZE;
    
    // Initialize memory zones
    zones[0] = Zone.init(.dma, 0, 4096);           // 0-16MB
    zones[1] = Zone.init(.normal, 4096, 229376);   // 16MB-896MB  
    zones[2] = Zone.init(.highmem, 229376, total_pages); // >896MB
    
    // Initialize free page lists
    for (&zones) |*zone| {
        initZoneFreePages(zone);
    }
    
    total_free_pages = total_pages;
    memory_initialized = true;
    
    console.writeString("Memory management initialized\n");
    console.writeString("  Total pages: ");
    printNumber(total_pages);
    console.writeString("\n");
}

/// Memory management tick (periodic maintenance)
pub fn tick() void {
    if (!memory_initialized) return;
    
    // TODO: Page reclaim, writeback, etc.
}

/// Allocate contiguous physical pages
pub fn allocPagesGlobal(order: u8) ?*PageFrame {
    if (!memory_initialized) return null;
    
    // Try normal zone first, then DMA, then highmem
    const zone_order = [_]usize{ 1, 0, 2 };
    
    for (zone_order) |zone_idx| {
        if (zones[zone_idx].allocPages(order)) |page| {
            return page;
        }
    }
    
    return null; // Out of memory
}

/// Free physical pages
pub fn freePagesGlobal(page: *PageFrame) void {
    if (!memory_initialized) return;
    
    const zone_idx: usize = switch (page.zone) {
        .dma => 0,
        .normal => 1, 
        .highmem => 2,
    };
    
    zones[zone_idx].freePages(page);
}

/// Get memory statistics
pub fn getMemoryStats() MemoryStats {
    if (!memory_initialized) {
        return MemoryStats{};
    }
    
    var free_pages: u64 = 0;
    var allocated_pages: u64 = 0;
    
    for (zones) |zone| {
        free_pages += zone.nr_free_pages;
        allocated_pages += zone.nr_alloc;
    }
    
    return MemoryStats{
        .total_pages = total_pages,
        .free_pages = free_pages,
        .allocated_pages = allocated_pages,
        .cached_pages = 0, // TODO
        .buffer_pages = 0, // TODO
    };
}

pub const MemoryStats = struct {
    total_pages: u64 = 0,
    free_pages: u64 = 0,
    allocated_pages: u64 = 0,
    cached_pages: u64 = 0,
    buffer_pages: u64 = 0,
};

// Helper functions
fn initZoneFreePages(zone: *Zone) void {
    // Initialize all pages as free in order 0
    var pfn = zone.start_pfn;
    while (pfn < zone.end_pfn) : (pfn += 1) {
        const page = getBuddyPage(pfn) orelse continue;
        page.* = PageFrame.init(pfn, zone.zone_type);
        page.flags.buddy = true;
        zone.addFreePageAtOrder(page, 0);
    }
}

fn getBuddyPfn(pfn: u64, order: u8) u64 {
    return pfn ^ (@as(u64, 1) << order);
}

fn getBuddyPage(pfn: u64) ?*PageFrame {
    // TODO: Implement proper page frame array
    _ = pfn;
    return null;
}

fn printNumber(num: u64) void {
    var buffer: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buffer, "{d}", .{num}) catch "?";
    console.writeString(str);
}

// Global kernel allocator (simple page allocator wrapper)
var kernel_allocator_instance: ?std.mem.Allocator = null;

/// Get the kernel allocator
pub fn getKernelAllocator() std.mem.Allocator {
    // For now, return a simple page allocator
    // In a real implementation, this would be a proper slab allocator
    if (kernel_allocator_instance) |allocator| {
        return allocator;
    }
    
    // Create a simple allocator that uses our page allocator
    const vtable = std.mem.Allocator.VTable{
        .alloc = kernelAlloc,
        .resize = kernelResize,
        .free = kernelFree,
        .remap = kernelRemap,
    };
    
    kernel_allocator_instance = std.mem.Allocator{
        .ptr = undefined,
        .vtable = &vtable,
    };
    
    return kernel_allocator_instance.?;
}

fn kernelAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ptr_align;
    _ = ret_addr;
    
    // Calculate pages needed
    const pages_needed = (len + PAGE_SIZE - 1) / PAGE_SIZE;
    const order = std.math.log2_int(u64, std.math.ceilPowerOfTwo(u64, pages_needed) catch return null);
    
    // Allocate pages
    const page = allocPagesGlobal(@intCast(order)) orelse return null;
    
    // Convert to virtual address
    const virt_addr = page.getVirtAddr();
    return @as([*]u8, @ptrFromInt(virt_addr));
}

fn kernelResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    
    // For simplicity, we don't support resize
    _ = buf;
    _ = new_len;
    return false;
}

fn kernelRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_size;
    _ = ret_addr;
    
    // For simplicity, we don't support remap
    return null;
}

fn kernelFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    
    // Convert virtual address back to page frame
    // This is simplified - real implementation would track allocations
    _ = buf;
    // freePagesGlobal(page);
}