//! ELF (Executable and Linkable Format) loader for Ghost Kernel
//! Pure Zig implementation of Linux ELF loader for running userspace binaries

const std = @import("std");
const memory = @import("../mm/memory.zig");
const paging = @import("../mm/paging.zig");
const process = @import("../kernel/process.zig");

/// ELF File Header (64-bit)
const ELFHeader = extern struct {
    e_ident: [16]u8,        // ELF identification
    e_type: u16,            // Object file type
    e_machine: u16,         // Machine architecture
    e_version: u32,         // Object file version
    e_entry: u64,           // Entry point virtual address
    e_phoff: u64,           // Program header table file offset
    e_shoff: u64,           // Section header table file offset
    e_flags: u32,           // Processor-specific flags
    e_ehsize: u16,          // ELF header size in bytes
    e_phentsize: u16,       // Program header table entry size
    e_phnum: u16,           // Program header table entry count
    e_shentsize: u16,       // Section header table entry size
    e_shnum: u16,           // Section header table entry count
    e_shstrndx: u16,        // Section header string table index
};

/// Program Header (64-bit)
const ProgramHeader = extern struct {
    p_type: u32,            // Segment type
    p_flags: u32,           // Segment flags
    p_offset: u64,          // Segment file offset
    p_vaddr: u64,           // Segment virtual address
    p_paddr: u64,           // Segment physical address
    p_filesz: u64,          // Segment size in file
    p_memsz: u64,           // Segment size in memory
    p_align: u64,           // Segment alignment
};

/// Section Header (64-bit)
const SectionHeader = extern struct {
    sh_name: u32,           // Section name (string table offset)
    sh_type: u32,           // Section type
    sh_flags: u64,          // Section flags
    sh_addr: u64,           // Section virtual addr at execution
    sh_offset: u64,         // Section file offset
    sh_size: u64,           // Section size in bytes
    sh_link: u32,           // Link to another section
    sh_info: u32,           // Additional section information
    sh_addralign: u64,      // Section alignment
    sh_entsize: u64,        // Entry size if section holds table
};

/// Dynamic Section Entry
const DynamicEntry = extern struct {
    d_tag: u64,             // Dynamic entry type
    d_val: u64,             // Value or address
};

/// ELF Constants
pub const ELF = struct {
    // ELF identification
    pub const MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
    pub const CLASS64 = 2;
    pub const DATA_LSB = 1;
    pub const VERSION_CURRENT = 1;
    pub const OSABI_SYSV = 0;
    
    // Object file types
    pub const ET_NONE = 0;
    pub const ET_REL = 1;
    pub const ET_EXEC = 2;
    pub const ET_DYN = 3;
    pub const ET_CORE = 4;
    
    // Machine architectures
    pub const EM_X86_64 = 62;
    
    // Program header types
    pub const PT_NULL = 0;
    pub const PT_LOAD = 1;
    pub const PT_DYNAMIC = 2;
    pub const PT_INTERP = 3;
    pub const PT_NOTE = 4;
    pub const PT_SHLIB = 5;
    pub const PT_PHDR = 6;
    pub const PT_TLS = 7;
    pub const PT_GNU_EH_FRAME = 0x6474e550;
    pub const PT_GNU_STACK = 0x6474e551;
    pub const PT_GNU_RELRO = 0x6474e552;
    
    // Program header flags
    pub const PF_X = 1;        // Execute
    pub const PF_W = 2;        // Write
    pub const PF_R = 4;        // Read
    
    // Section types
    pub const SHT_NULL = 0;
    pub const SHT_PROGBITS = 1;
    pub const SHT_SYMTAB = 2;
    pub const SHT_STRTAB = 3;
    pub const SHT_RELA = 4;
    pub const SHT_HASH = 5;
    pub const SHT_DYNAMIC = 6;
    pub const SHT_NOTE = 7;
    pub const SHT_NOBITS = 8;
    pub const SHT_REL = 9;
    pub const SHT_SHLIB = 10;
    pub const SHT_DYNSYM = 11;
    
    // Dynamic tags
    pub const DT_NULL = 0;
    pub const DT_NEEDED = 1;
    pub const DT_PLTRELSZ = 2;
    pub const DT_PLTGOT = 3;
    pub const DT_HASH = 4;
    pub const DT_STRTAB = 5;
    pub const DT_SYMTAB = 6;
    pub const DT_RELA = 7;
    pub const DT_RELASZ = 8;
    pub const DT_RELAENT = 9;
    pub const DT_STRSZ = 10;
    pub const DT_SYMENT = 11;
    pub const DT_INIT = 12;
    pub const DT_FINI = 13;
    pub const DT_SONAME = 14;
    pub const DT_RPATH = 15;
    pub const DT_SYMBOLIC = 16;
    pub const DT_REL = 17;
    pub const DT_RELSZ = 18;
    pub const DT_RELENT = 19;
    pub const DT_PLTREL = 20;
    pub const DT_DEBUG = 21;
    pub const DT_TEXTREL = 22;
    pub const DT_JMPREL = 23;
    pub const DT_BIND_NOW = 24;
    pub const DT_INIT_ARRAY = 25;
    pub const DT_FINI_ARRAY = 26;
    pub const DT_INIT_ARRAYSZ = 27;
    pub const DT_FINI_ARRAYSZ = 28;
    pub const DT_RUNPATH = 29;
    pub const DT_FLAGS = 30;
    pub const DT_ENCODING = 32;
};

/// ELF loader errors
pub const ELFError = error{
    InvalidMagic,
    UnsupportedClass,
    UnsupportedEndianness,
    UnsupportedVersion,
    UnsupportedArchitecture,
    UnsupportedType,
    InvalidProgramHeader,
    InvalidSectionHeader,
    MemoryAllocationFailed,
    MemoryMappingFailed,
    InvalidEntryPoint,
    DynamicLinkingNotSupported,
    InvalidInterpreter,
    FileReadError,
    PermissionDenied,
};

/// ELF Loader context
pub const ELFLoader = struct {
    allocator: std.mem.Allocator,
    header: ELFHeader,
    program_headers: []ProgramHeader,
    section_headers: []SectionHeader,
    data: []const u8,
    entry_point: u64,
    load_base: u64,
    
    const Self = @This();
    
    /// Initialize ELF loader with binary data
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < @sizeOf(ELFHeader)) {
            return ELFError.FileReadError;
        }
        
        const header = @as(*const ELFHeader, @ptrCast(@alignCast(data.ptr))).*;
        
        // Validate ELF header
        try validateHeader(header);
        
        // Load program headers
        const ph_offset = header.e_phoff;
        const ph_size = @as(u64, header.e_phentsize) * header.e_phnum;
        
        if (ph_offset + ph_size > data.len) {
            return ELFError.InvalidProgramHeader;
        }
        
        const ph_data = data[ph_offset..ph_offset + ph_size];
        const program_headers = try allocator.alloc(ProgramHeader, header.e_phnum);
        
        for (0..header.e_phnum) |i| {
            const ph_start = i * header.e_phentsize;
            const ph_ptr = @as(*const ProgramHeader, @ptrCast(@alignCast(ph_data[ph_start..].ptr)));
            program_headers[i] = ph_ptr.*;
        }
        
        // Load section headers (if present)
        var section_headers: []SectionHeader = &[_]SectionHeader{};
        if (header.e_shoff != 0 and header.e_shnum > 0) {
            const sh_offset = header.e_shoff;
            const sh_size = @as(u64, header.e_shentsize) * header.e_shnum;
            
            if (sh_offset + sh_size <= data.len) {
                section_headers = try allocator.alloc(SectionHeader, header.e_shnum);
                const sh_data = data[sh_offset..sh_offset + sh_size];
                
                for (0..header.e_shnum) |i| {
                    const sh_start = i * header.e_shentsize;
                    const sh_ptr = @as(*const SectionHeader, @ptrCast(@alignCast(sh_data[sh_start..].ptr)));
                    section_headers[i] = sh_ptr.*;
                }
            }
        }
        
        return Self{
            .allocator = allocator,
            .header = header,
            .program_headers = program_headers,
            .section_headers = section_headers,
            .data = data,
            .entry_point = header.e_entry,
            .load_base = 0,
        };
    }
    
    /// Clean up ELF loader resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.program_headers);
        if (self.section_headers.len > 0) {
            self.allocator.free(self.section_headers);
        }
    }
    
    /// Load ELF binary into process address space
    pub fn loadIntoProcess(self: *Self, proc: *process.Process) !void {
        // Check if this is a dynamically linked executable
        const is_dynamic = self.header.e_type == ELF.ET_DYN;
        const has_interpreter = self.hasInterpreter();
        
        if (has_interpreter) {
            // For now, we don't support dynamic linking
            return ELFError.DynamicLinkingNotSupported;
        }
        
        // Calculate load base address
        self.load_base = if (is_dynamic) 0x400000 else 0; // Standard base for PIE
        
        // Load all LOAD segments
        for (self.program_headers) |ph| {
            if (ph.p_type == ELF.PT_LOAD) {
                try self.loadSegment(proc, ph);
            }
        }
        
        // Set entry point
        proc.entry_point = self.entry_point + self.load_base;
        
        // Initialize stack
        try self.setupStack(proc);
    }
    
    /// Load a single ELF segment
    fn loadSegment(self: *Self, proc: *process.Process, ph: ProgramHeader) !void {
        const vaddr = ph.p_vaddr + self.load_base;
        const size = ph.p_memsz;
        const file_size = ph.p_filesz;
        
        // Align to page boundaries
        const page_start = vaddr & ~@as(u64, 0xFFF);
        const page_end = (vaddr + size + 0xFFF) & ~@as(u64, 0xFFF);
        const pages_needed = (page_end - page_start) / 4096;
        
        // Determine permissions
        var prot_flags: u32 = 0;
        if (ph.p_flags & ELF.PF_R != 0) prot_flags |= paging.PAGE_PRESENT;
        if (ph.p_flags & ELF.PF_W != 0) prot_flags |= paging.PAGE_WRITABLE;
        if (ph.p_flags & ELF.PF_X == 0) prot_flags |= paging.PAGE_NX;
        
        // Allocate physical pages
        const phys_addr = try memory.allocPages(pages_needed);
        if (phys_addr == null) {
            return ELFError.MemoryAllocationFailed;
        }
        
        // Map pages into process address space
        try proc.address_space.?.mapRange(
            page_start,
            phys_addr.?,
            pages_needed * 4096,
            prot_flags
        );
        
        // Copy file data to memory
        if (file_size > 0) {
            const file_data = self.data[ph.p_offset..ph.p_offset + file_size];
            const target_ptr = @as([*]u8, @ptrFromInt(vaddr));
            @memcpy(target_ptr[0..file_size], file_data);
        }
        
        // Zero-fill remaining memory (BSS section)
        if (size > file_size) {
            const zero_start = @as([*]u8, @ptrFromInt(vaddr + file_size));
            @memset(zero_start[0..size - file_size], 0);
        }
    }
    
    /// Set up initial process stack
    fn setupStack(self: *Self, proc: *process.Process) !void {
        const stack_size = 8 * 1024 * 1024; // 8MB stack
        const stack_top = 0x7fffffffe000;
        const stack_bottom = stack_top - stack_size;
        
        // Allocate physical pages for stack
        const pages_needed = stack_size / 4096;
        const phys_addr = try memory.allocPages(pages_needed);
        if (phys_addr == null) {
            return ELFError.MemoryAllocationFailed;
        }
        
        // Map stack into process address space
        try proc.address_space.?.mapRange(
            stack_bottom,
            phys_addr.?,
            stack_size,
            paging.PAGE_PRESENT | paging.PAGE_WRITABLE | paging.PAGE_NX
        );
        
        // Set stack pointer
        proc.stack_pointer = stack_top;
        proc.kernel_stack = @as(?*anyopaque, @ptrFromInt(stack_bottom));
    }
    
    /// Check if ELF has interpreter (dynamic linker)
    fn hasInterpreter(self: *Self) bool {
        for (self.program_headers) |ph| {
            if (ph.p_type == ELF.PT_INTERP) {
                return true;
            }
        }
        return false;
    }
    
    /// Get interpreter path
    pub fn getInterpreter(self: *Self) ?[]const u8 {
        for (self.program_headers) |ph| {
            if (ph.p_type == ELF.PT_INTERP) {
                const interp_data = self.data[ph.p_offset..ph.p_offset + ph.p_filesz];
                // Remove null terminator
                const len = if (interp_data[interp_data.len - 1] == 0) 
                    interp_data.len - 1 else interp_data.len;
                return interp_data[0..len];
            }
        }
        return null;
    }
    
    /// Validate ELF header
    fn validateHeader(header: ELFHeader) !void {
        // Check ELF magic
        if (!std.mem.eql(u8, header.e_ident[0..4], &ELF.MAGIC)) {
            return ELFError.InvalidMagic;
        }
        
        // Check 64-bit
        if (header.e_ident[4] != ELF.CLASS64) {
            return ELFError.UnsupportedClass;
        }
        
        // Check little endian
        if (header.e_ident[5] != ELF.DATA_LSB) {
            return ELFError.UnsupportedEndianness;
        }
        
        // Check version
        if (header.e_ident[6] != ELF.VERSION_CURRENT) {
            return ELFError.UnsupportedVersion;
        }
        
        // Check architecture
        if (header.e_machine != ELF.EM_X86_64) {
            return ELFError.UnsupportedArchitecture;
        }
        
        // Check type (executable or shared object)
        if (header.e_type != ELF.ET_EXEC and header.e_type != ELF.ET_DYN) {
            return ELFError.UnsupportedType;
        }
        
        // Check entry point
        if (header.e_entry == 0) {
            return ELFError.InvalidEntryPoint;
        }
    }
};

/// High-level function to execute ELF binary
pub fn execELF(allocator: std.mem.Allocator, binary_data: []const u8, argv: [][]const u8, envp: [][]const u8) !*process.Process {
    var loader = try ELFLoader.init(allocator, binary_data);
    defer loader.deinit();
    
    // Create new process
    var new_process = try process.Process.create(allocator);
    
    // Load ELF into process
    try loader.loadIntoProcess(new_process);
    
    // Set up command line arguments and environment
    try setupArguments(new_process, argv, envp);
    
    return new_process;
}

/// Set up command line arguments and environment variables
fn setupArguments(proc: *process.Process, argv: [][]const u8, envp: [][]const u8) !void {
    // This would set up argc, argv, and envp on the stack
    // For now, we'll implement a basic version
    
    const stack_ptr = proc.stack_pointer;
    var sp = stack_ptr;
    
    // Reserve space for arguments (simplified)
    sp -= 8; // argc
    sp -= argv.len * 8; // argv pointers
    sp -= 8; // null terminator
    sp -= envp.len * 8; // envp pointers
    sp -= 8; // null terminator
    
    // Write argc
    const argc_ptr = @as(*u64, @ptrFromInt(sp));
    argc_ptr.* = argv.len;
    
    proc.stack_pointer = sp;
}

// Tests
test "ELF header validation" {
    const allocator = std.testing.allocator;
    
    // Create a minimal valid ELF header
    var elf_data = [_]u8{0} ** 1024;
    const header = @as(*ELFHeader, @ptrCast(@alignCast(&elf_data[0])));
    
    // Set ELF magic
    header.e_ident[0..4].* = ELF.MAGIC;
    header.e_ident[4] = ELF.CLASS64;
    header.e_ident[5] = ELF.DATA_LSB;
    header.e_ident[6] = ELF.VERSION_CURRENT;
    header.e_machine = ELF.EM_X86_64;
    header.e_type = ELF.ET_EXEC;
    header.e_entry = 0x400000;
    header.e_ehsize = @sizeOf(ELFHeader);
    
    var loader = try ELFLoader.init(allocator, &elf_data);
    defer loader.deinit();
    
    try std.testing.expect(loader.entry_point == 0x400000);
}

test "invalid ELF magic" {
    const allocator = std.testing.allocator;
    var elf_data = [_]u8{0} ** 64;
    
    const result = ELFLoader.init(allocator, &elf_data);
    try std.testing.expectError(ELFError.InvalidMagic, result);
}