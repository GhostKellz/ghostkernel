//! x86_64 Virtual Memory and Paging
//! 4-level page tables (PML4, PDPT, PD, PT)

const std = @import("std");
const console = @import("console.zig");
const memory = @import("../../mm/memory.zig");

/// Page table entry flags
pub const PageFlags = packed struct {
    present: bool = false,         // Page is present in memory
    writable: bool = false,        // Page is writable
    user: bool = false,            // Page is accessible from userspace
    write_through: bool = false,   // Write-through caching
    cache_disable: bool = false,   // Disable caching
    accessed: bool = false,        // Page has been accessed
    dirty: bool = false,           // Page has been written to
    huge_page: bool = false,       // 2MB/1GB huge page
    global: bool = false,          // Page is global (not flushed on CR3 reload)
    available1: u3 = 0,            // Available for OS use
    physical_addr: u40 = 0,        // Physical address (bits 12-51)
    available2: u11 = 0,           // Available for OS use
    no_execute: bool = false,      // No-execute bit
    
    const Self = @This();
    
    pub fn fromPhysAddr(phys_addr: u64) Self {
        return Self{
            .physical_addr = @truncate(phys_addr >> 12),
        };
    }
    
    pub fn toPhysAddr(self: Self) u64 {
        return @as(u64, self.physical_addr) << 12;
    }
    
    pub fn toEntry(self: Self) u64 {
        return @bitCast(self);
    }
    
    pub fn fromEntry(entry: u64) Self {
        return @bitCast(entry);
    }
};

/// Page table (all levels use same structure)
pub const PageTable = struct {
    entries: [512]u64 align(4096),
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .entries = [_]u64{0} ** 512,
        };
    }
    
    pub fn getEntry(self: *Self, index: usize) PageFlags {
        return PageFlags.fromEntry(self.entries[index]);
    }
    
    pub fn setEntry(self: *Self, index: usize, flags: PageFlags) void {
        self.entries[index] = flags.toEntry();
    }
    
    pub fn mapPage(self: *Self, index: usize, phys_addr: u64, flags: PageFlags) void {
        var entry = flags;
        entry.physical_addr = @truncate(phys_addr >> 12);
        entry.present = true;
        self.entries[index] = entry.toEntry();
    }
    
    pub fn unmapPage(self: *Self, index: usize) void {
        self.entries[index] = 0;
    }
    
    pub fn getNextLevel(self: *Self, index: usize) ?*PageTable {
        const entry = self.getEntry(index);
        if (!entry.present) return null;
        
        const phys_addr = entry.toPhysAddr();
        const virt_addr = physToVirt(phys_addr);
        return @ptrFromInt(virt_addr);
    }
    
    pub fn getOrCreateNextLevel(self: *Self, index: usize, allocator: *memory.PageFrame) !*PageTable {
        if (self.getNextLevel(index)) |table| {
            return table;
        }
        
        // Allocate new page table
        const page = allocator; // TODO: Proper page allocation
        const phys_addr = page.getPhysAddr();
        const virt_addr = physToVirt(phys_addr);
        
        // Initialize new table
        const new_table: *PageTable = @ptrFromInt(virt_addr);
        new_table.* = PageTable.init();
        
        // Map in parent table
        var flags = PageFlags{};
        flags.present = true;
        flags.writable = true;
        self.mapPage(index, phys_addr, flags);
        
        return new_table;
    }
};

/// Virtual address structure
pub const VirtualAddress = packed struct {
    offset: u12,        // Byte offset within page
    pt_index: u9,       // Page table index
    pd_index: u9,       // Page directory index
    pdpt_index: u9,     // PDPT index
    pml4_index: u9,     // PML4 index
    sign_extend: u16,   // Sign extension (must match bit 47)
    
    const Self = @This();
    
    pub fn fromAddr(addr: u64) Self {
        return @bitCast(addr);
    }
    
    pub fn toAddr(self: Self) u64 {
        return @bitCast(self);
    }
};

/// Address space (per-process page tables)
pub const AddressSpace = struct {
    pml4: *PageTable,
    pml4_phys: u64,
    
    const Self = @This();
    
    pub fn init() !Self {
        // TODO: Allocate PML4 table
        const pml4_page = memory.allocPagesGlobal(0) orelse return error.OutOfMemory;
        const pml4_phys = pml4_page.getPhysAddr();
        const pml4_virt = physToVirt(pml4_phys);
        
        const pml4: *PageTable = @ptrFromInt(pml4_virt);
        pml4.* = PageTable.init();
        
        // Map kernel space (upper half)
        // TODO: Copy kernel mappings
        
        return Self{
            .pml4 = pml4,
            .pml4_phys = pml4_phys,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // TODO: Free all page tables recursively
        _ = self;
    }
    
    pub fn mapPage(self: *Self, virt_addr: u64, phys_addr: u64, flags: PageFlags) !void {
        const vaddr = VirtualAddress.fromAddr(virt_addr);
        
        // Walk page tables, creating as needed
        const pdpt = try self.pml4.getOrCreateNextLevel(vaddr.pml4_index, undefined);
        const pd = try pdpt.getOrCreateNextLevel(vaddr.pdpt_index, undefined);
        const pt = try pd.getOrCreateNextLevel(vaddr.pd_index, undefined);
        
        // Map the page
        pt.mapPage(vaddr.pt_index, phys_addr, flags);
        
        // Flush TLB for this address
        flushTLB(virt_addr);
    }
    
    pub fn unmapPage(self: *Self, virt_addr: u64) void {
        const vaddr = VirtualAddress.fromAddr(virt_addr);
        
        // Walk page tables
        const pdpt = self.pml4.getNextLevel(vaddr.pml4_index) orelse return;
        const pd = pdpt.getNextLevel(vaddr.pdpt_index) orelse return;
        const pt = pd.getNextLevel(vaddr.pd_index) orelse return;
        
        // Unmap the page
        pt.unmapPage(vaddr.pt_index);
        
        // Flush TLB
        flushTLB(virt_addr);
    }
    
    pub fn translate(self: *Self, virt_addr: u64) ?u64 {
        const vaddr = VirtualAddress.fromAddr(virt_addr);
        
        // Walk page tables
        const pdpt = self.pml4.getNextLevel(vaddr.pml4_index) orelse return null;
        const pd = pdpt.getNextLevel(vaddr.pdpt_index) orelse return null;
        
        // Check for 2MB huge page
        const pd_entry = pd.getEntry(vaddr.pd_index);
        if (pd_entry.huge_page) {
            const base = pd_entry.toPhysAddr();
            const offset = virt_addr & 0x1FFFFF; // 2MB mask
            return base + offset;
        }
        
        const pt = pd.getNextLevel(vaddr.pd_index) orelse return null;
        const pt_entry = pt.getEntry(vaddr.pt_index);
        
        if (!pt_entry.present) return null;
        
        return pt_entry.toPhysAddr() + vaddr.offset;
    }
    
    pub fn switchTo(self: *Self) void {
        setCR3(self.pml4_phys);
    }
};

/// Kernel address space
var kernel_address_space: AddressSpace = undefined;
var kernel_pml4: PageTable align(4096) = PageTable.init();

/// Initialize paging
pub fn init() !void {
    console.writeString("Initializing paging subsystem...\n");
    
    // Set up kernel address space
    kernel_address_space = AddressSpace{
        .pml4 = &kernel_pml4,
        .pml4_phys = virtToPhys(@intFromPtr(&kernel_pml4)),
    };
    
    // Identity map first 4GB for early boot
    var addr: u64 = 0;
    while (addr < 4 * 1024 * 1024 * 1024) : (addr += memory.PAGE_SIZE) {
        var flags = PageFlags{};
        flags.present = true;
        flags.writable = true;
        flags.global = true;
        
        try kernel_address_space.mapPage(addr, addr, flags);
        try kernel_address_space.mapPage(physToVirt(addr), addr, flags);
    }
    
    // Enable paging features
    enableNXBit();
    enableWriteProtect();
    
    // Switch to kernel address space
    kernel_address_space.switchTo();
    
    console.writeString("Paging initialized\n");
}

/// Physical to virtual address translation (kernel direct map)
pub fn physToVirt(phys_addr: u64) u64 {
    return phys_addr + 0xffff_8800_0000_0000;
}

/// Virtual to physical address translation (kernel direct map)
pub fn virtToPhys(virt_addr: u64) u64 {
    if (virt_addr >= 0xffff_8800_0000_0000) {
        return virt_addr - 0xffff_8800_0000_0000;
    }
    // For low addresses, assume identity mapped
    return virt_addr;
}

/// Set CR3 register (page table base)
fn setCR3(phys_addr: u64) void {
    asm volatile ("movq %[addr], %%cr3"
        :
        : [addr] "r" (phys_addr),
        : "memory"
    );
}

/// Get current CR3 value
pub fn getCR3() u64 {
    return asm volatile ("movq %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );
}

/// Flush TLB for specific address
fn flushTLB(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

/// Enable NX bit support
fn enableNXBit() void {
    // Set EFER.NXE (bit 11)
    const efer = readMSR(0xC0000080);
    writeMSR(0xC0000080, efer | (1 << 11));
}

/// Enable write protect (kernel can't write to read-only pages)
fn enableWriteProtect() void {
    const cr0 = asm volatile ("movq %%cr0, %[cr0]"
        : [cr0] "=r" (-> u64),
    );
    asm volatile ("movq %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0 | (1 << 16)),
        : "memory"
    );
}

/// Read MSR
fn readMSR(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write MSR
fn writeMSR(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [_] "{eax}" (low),
          [_] "{edx}" (high),
          [_] "{ecx}" (msr),
    );
}