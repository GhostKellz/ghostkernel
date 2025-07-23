//! ELF Dynamic Linking Support for Ghost Kernel
//! Implements dynamic linker functionality for loading shared libraries

const std = @import("std");
const elf = @import("elf.zig");
const vfs = @import("vfs.zig");
const memory = @import("../mm/memory.zig");
const paging = @import("../arch/x86_64/paging.zig");
const process = @import("../kernel/process.zig");

/// Dynamic linker state
pub const DynamicLinker = struct {
    allocator: std.mem.Allocator,
    process: *process.Process,
    loaded_objects: std.ArrayList(*SharedObject),
    symbol_cache: std.StringHashMap(SymbolEntry),
    tls_offset: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, proc: *process.Process) Self {
        return Self{
            .allocator = allocator,
            .process = proc,
            .loaded_objects = std.ArrayList(*SharedObject).init(allocator),
            .symbol_cache = std.StringHashMap(SymbolEntry).init(allocator),
            .tls_offset = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.loaded_objects.items) |obj| {
            obj.deinit();
            self.allocator.destroy(obj);
        }
        self.loaded_objects.deinit();
        self.symbol_cache.deinit();
    }
    
    /// Load the main executable and all its dependencies
    pub fn loadExecutable(self: *Self, exe_data: []const u8) !void {
        // Load main executable
        const main_obj = try self.loadObject(exe_data, null, true);
        try self.loaded_objects.append(main_obj);
        
        // Process dependencies
        try self.loadDependencies(main_obj);
        
        // Perform relocations for all objects
        try self.relocateAll();
        
        // Initialize all objects
        try self.initializeAll();
        
        // Set entry point
        self.process.entry_point = main_obj.entry_point;
    }
    
    /// Load a shared object
    fn loadObject(self: *Self, data: []const u8, parent: ?*SharedObject, is_main: bool) !*SharedObject {
        var loader = try elf.ELFLoader.init(self.allocator, data);
        defer loader.deinit();
        
        const obj = try self.allocator.create(SharedObject);
        obj.* = SharedObject{
            .allocator = self.allocator,
            .data = data,
            .header = loader.header,
            .program_headers = try self.allocator.dupe(elf.ProgramHeader, loader.program_headers),
            .dynamic_section = null,
            .base_address = if (is_main) 0 else try self.allocateLoadAddress(&loader),
            .entry_point = loader.entry_point,
            .parent = parent,
            .dependencies = std.ArrayList(*SharedObject).init(self.allocator),
            .symbols = std.StringHashMap(Symbol).init(self.allocator),
            .got = null,
            .plt = null,
            .init_func = null,
            .fini_func = null,
            .init_array = null,
            .fini_array = null,
        };
        
        // Load segments
        try self.loadSegments(obj, &loader);
        
        // Process dynamic section
        try self.processDynamicSection(obj);
        
        // Load symbol table
        try self.loadSymbols(obj);
        
        return obj;
    }
    
    /// Allocate base address for shared object
    fn allocateLoadAddress(self: *Self, loader: *elf.ELFLoader) !u64 {
        _ = self;
        
        // Calculate required size
        var min_addr: u64 = std.math.maxInt(u64);
        var max_addr: u64 = 0;
        
        for (loader.program_headers) |ph| {
            if (ph.p_type == elf.ELF.PT_LOAD) {
                min_addr = @min(min_addr, ph.p_vaddr);
                max_addr = @max(max_addr, ph.p_vaddr + ph.p_memsz);
            }
        }
        
        const size = max_addr - min_addr;
        
        // Allocate in userspace (simplified - should use proper mmap)
        // Start at 0x40000000 and increment
        const base: u64 = 0x40000000 + (self.loaded_objects.items.len * 0x1000000);
        
        return base;
    }
    
    /// Load segments into memory
    fn loadSegments(self: *Self, obj: *SharedObject, loader: *elf.ELFLoader) !void {
        for (loader.program_headers) |ph| {
            if (ph.p_type == elf.ELF.PT_LOAD) {
                try self.loadSegment(obj, ph);
            } else if (ph.p_type == elf.ELF.PT_DYNAMIC) {
                obj.dynamic_offset = ph.p_vaddr;
                obj.dynamic_size = ph.p_memsz;
            } else if (ph.p_type == elf.ELF.PT_TLS) {
                obj.tls_size = ph.p_memsz;
                obj.tls_align = ph.p_align;
            }
        }
    }
    
    /// Load a single segment
    fn loadSegment(self: *Self, obj: *SharedObject, ph: elf.ProgramHeader) !void {
        const vaddr = obj.base_address + ph.p_vaddr;
        const size = ph.p_memsz;
        const file_size = ph.p_filesz;
        
        // Align to page boundaries
        const page_start = vaddr & ~@as(u64, 0xFFF);
        const page_end = (vaddr + size + 0xFFF) & ~@as(u64, 0xFFF);
        const pages_needed = (page_end - page_start) / 4096;
        
        // Determine permissions
        var prot_flags: u32 = 0;
        if (ph.p_flags & elf.ELF.PF_R != 0) prot_flags |= paging.PAGE_PRESENT;
        if (ph.p_flags & elf.ELF.PF_W != 0) prot_flags |= paging.PAGE_WRITABLE;
        if (ph.p_flags & elf.ELF.PF_X == 0) prot_flags |= paging.PAGE_NX;
        
        // Allocate and map pages
        const phys_addr = try memory.allocPages(pages_needed);
        if (phys_addr == null) {
            return elf.ELFError.MemoryAllocationFailed;
        }
        
        try self.process.address_space.?.mapRange(
            page_start,
            phys_addr.?,
            pages_needed * 4096,
            prot_flags
        );
        
        // Copy file data
        if (file_size > 0) {
            const file_data = obj.data[ph.p_offset..ph.p_offset + file_size];
            const target_ptr = @as([*]u8, @ptrFromInt(vaddr));
            @memcpy(target_ptr[0..file_size], file_data);
        }
        
        // Zero-fill BSS
        if (size > file_size) {
            const zero_start = @as([*]u8, @ptrFromInt(vaddr + file_size));
            @memset(zero_start[0..size - file_size], 0);
        }
    }
    
    /// Process dynamic section
    fn processDynamicSection(self: *Self, obj: *SharedObject) !void {
        _ = self;
        
        if (obj.dynamic_offset == null) return;
        
        const dyn_addr = obj.base_address + obj.dynamic_offset.?;
        const dyn_entries = @as([*]const elf.DynamicEntry, @ptrFromInt(dyn_addr));
        
        var i: usize = 0;
        while (dyn_entries[i].d_tag != elf.ELF.DT_NULL) : (i += 1) {
            const entry = dyn_entries[i];
            
            switch (entry.d_tag) {
                elf.ELF.DT_NEEDED => {
                    // Library dependency - will process later
                },
                elf.ELF.DT_STRTAB => {
                    obj.strtab = @as([*]const u8, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_SYMTAB => {
                    obj.symtab = @as([*]const elf.Symbol, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_HASH => {
                    obj.hash_table = @as([*]const u32, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_PLTGOT => {
                    obj.got = @as([*]u64, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_PLTRELSZ => {
                    obj.plt_rel_size = entry.d_val;
                },
                elf.ELF.DT_JMPREL => {
                    obj.plt_rel = @as([*]const elf.Rela, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_RELA => {
                    obj.rela = @as([*]const elf.Rela, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_RELASZ => {
                    obj.rela_size = entry.d_val;
                },
                elf.ELF.DT_INIT => {
                    obj.init_func = @as(*const fn () void, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_FINI => {
                    obj.fini_func = @as(*const fn () void, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_INIT_ARRAY => {
                    obj.init_array = @as([*]const fn () void, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_INIT_ARRAYSZ => {
                    obj.init_array_size = entry.d_val / @sizeOf(fn () void);
                },
                elf.ELF.DT_FINI_ARRAY => {
                    obj.fini_array = @as([*]const fn () void, @ptrFromInt(obj.base_address + entry.d_val));
                },
                elf.ELF.DT_FINI_ARRAYSZ => {
                    obj.fini_array_size = entry.d_val / @sizeOf(fn () void);
                },
                else => {},
            }
        }
        
        obj.dynamic_section = dyn_entries[0..i];
    }
    
    /// Load symbol table
    fn loadSymbols(self: *Self, obj: *SharedObject) !void {
        _ = self;
        
        if (obj.symtab == null or obj.strtab == null) return;
        
        // Get number of symbols from hash table
        const nbucket = obj.hash_table.?[0];
        const nchain = obj.hash_table.?[1];
        const nsyms = nbucket + nchain;
        
        // Load symbols
        for (0..nsyms) |i| {
            const sym = obj.symtab.?[i];
            if (sym.st_name == 0) continue;
            
            const name = std.mem.sliceTo(obj.strtab.? + sym.st_name, 0);
            
            try obj.symbols.put(try obj.allocator.dupe(u8, name), Symbol{
                .name = name,
                .value = obj.base_address + sym.st_value,
                .size = sym.st_size,
                .type = @truncate(sym.st_info & 0xF),
                .binding = @truncate(sym.st_info >> 4),
                .section = sym.st_shndx,
            });
        }
    }
    
    /// Load dependencies
    fn loadDependencies(self: *Self, obj: *SharedObject) !void {
        if (obj.dynamic_section == null) return;
        
        for (obj.dynamic_section.?) |entry| {
            if (entry.d_tag == elf.ELF.DT_NEEDED) {
                const lib_name = std.mem.sliceTo(obj.strtab.? + entry.d_val, 0);
                
                // Check if already loaded
                var already_loaded = false;
                for (self.loaded_objects.items) |loaded| {
                    if (loaded.name) |name| {
                        if (std.mem.eql(u8, name, lib_name)) {
                            already_loaded = true;
                            try obj.dependencies.append(loaded);
                            break;
                        }
                    }
                }
                
                if (!already_loaded) {
                    // Load the library
                    const lib_data = try self.loadLibrary(lib_name);
                    const lib_obj = try self.loadObject(lib_data, obj, false);
                    lib_obj.name = try self.allocator.dupe(u8, lib_name);
                    
                    try self.loaded_objects.append(lib_obj);
                    try obj.dependencies.append(lib_obj);
                    
                    // Recursively load its dependencies
                    try self.loadDependencies(lib_obj);
                }
            }
        }
    }
    
    /// Load a shared library by name
    fn loadLibrary(self: *Self, name: []const u8) ![]const u8 {
        _ = self;
        
        // Search paths (simplified)
        const search_paths = [_][]const u8{
            "/lib",
            "/usr/lib",
            "/usr/local/lib",
        };
        
        for (search_paths) |path| {
            var path_buf: [256]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, name });
            
            // Try to open the file
            const file_vfs = vfs.getVFS();
            if (file_vfs.open(full_path, .{ .read = true })) |file| {
                defer file.put();
                
                // Read entire file (simplified)
                const size = file.inode.size;
                const data = try self.allocator.alloc(u8, size);
                _ = try file.read(data);
                
                return data;
            } else |_| {
                continue;
            }
        }
        
        return elf.ELFError.FileNotFound;
    }
    
    /// Perform relocations for all objects
    fn relocateAll(self: *Self) !void {
        // First pass: GOT relocations
        for (self.loaded_objects.items) |obj| {
            try self.relocateObject(obj, false);
        }
        
        // Second pass: PLT relocations (lazy binding)
        for (self.loaded_objects.items) |obj| {
            try self.relocateObject(obj, true);
        }
    }
    
    /// Relocate a single object
    fn relocateObject(self: *Self, obj: *SharedObject, plt_only: bool) !void {
        // Process RELA relocations
        if (!plt_only and obj.rela != null and obj.rela_size != null) {
            const count = obj.rela_size.? / @sizeOf(elf.Rela);
            for (0..count) |i| {
                try self.processRelocation(obj, &obj.rela.?[i]);
            }
        }
        
        // Process PLT relocations
        if (plt_only and obj.plt_rel != null and obj.plt_rel_size != null) {
            const count = obj.plt_rel_size.? / @sizeOf(elf.Rela);
            for (0..count) |i| {
                try self.processRelocation(obj, &obj.plt_rel.?[i]);
            }
        }
    }
    
    /// Process a single relocation
    fn processRelocation(self: *Self, obj: *SharedObject, rela: *const elf.Rela) !void {
        const r_type = @as(u32, @truncate(rela.r_info & 0xFFFFFFFF));
        const r_sym = @as(u32, @truncate(rela.r_info >> 32));
        
        const target_addr = obj.base_address + rela.r_offset;
        const target = @as(*u64, @ptrFromInt(target_addr));
        
        switch (r_type) {
            elf.R_X86_64_NONE => {},
            elf.R_X86_64_64 => {
                // S + A
                const sym_value = try self.resolveSymbol(obj, r_sym);
                target.* = sym_value + @as(u64, @bitCast(rela.r_addend));
            },
            elf.R_X86_64_PC32 => {
                // S + A - P
                const sym_value = try self.resolveSymbol(obj, r_sym);
                const result = sym_value + @as(u64, @bitCast(rela.r_addend)) - target_addr;
                @as(*u32, @ptrCast(target)).* = @truncate(result);
            },
            elf.R_X86_64_GLOB_DAT => {
                // S
                target.* = try self.resolveSymbol(obj, r_sym);
            },
            elf.R_X86_64_JUMP_SLOT => {
                // S
                target.* = try self.resolveSymbol(obj, r_sym);
            },
            elf.R_X86_64_RELATIVE => {
                // B + A
                target.* = obj.base_address + @as(u64, @bitCast(rela.r_addend));
            },
            else => return elf.ELFError.NotSupported,
        }
    }
    
    /// Resolve a symbol
    fn resolveSymbol(self: *Self, obj: *SharedObject, sym_index: u32) !u64 {
        if (sym_index == 0) return 0;
        
        const sym = &obj.symtab.?[sym_index];
        const name = std.mem.sliceTo(obj.strtab.? + sym.st_name, 0);
        
        // Check cache first
        if (self.symbol_cache.get(name)) |cached| {
            return cached.address;
        }
        
        // Local symbol
        if (sym.st_shndx != elf.SHN_UNDEF) {
            const addr = obj.base_address + sym.st_value;
            try self.symbol_cache.put(try self.allocator.dupe(u8, name), SymbolEntry{
                .address = addr,
                .object = obj,
            });
            return addr;
        }
        
        // Search in dependencies
        for (obj.dependencies.items) |dep| {
            if (dep.symbols.get(name)) |found_sym| {
                const addr = found_sym.value;
                try self.symbol_cache.put(try self.allocator.dupe(u8, name), SymbolEntry{
                    .address = addr,
                    .object = dep,
                });
                return addr;
            }
        }
        
        // Search in all loaded objects
        for (self.loaded_objects.items) |loaded| {
            if (loaded.symbols.get(name)) |found_sym| {
                const addr = found_sym.value;
                try self.symbol_cache.put(try self.allocator.dupe(u8, name), SymbolEntry{
                    .address = addr,
                    .object = loaded,
                });
                return addr;
            }
        }
        
        return elf.ELFError.NotSupported;
    }
    
    /// Initialize all objects
    fn initializeAll(self: *Self) !void {
        _ = self;
        
        // Initialize in dependency order
        for (self.loaded_objects.items) |obj| {
            // Call init function
            if (obj.init_func) |init| {
                init();
            }
            
            // Call init array functions
            if (obj.init_array) |array| {
                for (0..obj.init_array_size.?) |i| {
                    array[i]();
                }
            }
        }
    }
};

/// Shared object representation
const SharedObject = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    data: []const u8,
    header: elf.ELFHeader,
    program_headers: []elf.ProgramHeader,
    dynamic_section: ?[]const elf.DynamicEntry,
    base_address: u64,
    entry_point: u64,
    parent: ?*SharedObject,
    dependencies: std.ArrayList(*SharedObject),
    symbols: std.StringHashMap(Symbol),
    
    // Dynamic section data
    dynamic_offset: ?u64 = null,
    dynamic_size: ?u64 = null,
    strtab: ?[*]const u8 = null,
    symtab: ?[*]const elf.Symbol = null,
    hash_table: ?[*]const u32 = null,
    got: ?[*]u64 = null,
    plt: ?[*]const u8 = null,
    rela: ?[*]const elf.Rela = null,
    rela_size: ?u64 = null,
    plt_rel: ?[*]const elf.Rela = null,
    plt_rel_size: ?u64 = null,
    
    // Initialization
    init_func: ?*const fn () void = null,
    fini_func: ?*const fn () void = null,
    init_array: ?[*]const fn () void = null,
    init_array_size: ?u64 = null,
    fini_array: ?[*]const fn () void = null,
    fini_array_size: ?u64 = null,
    
    // TLS
    tls_size: ?u64 = null,
    tls_align: ?u64 = null,
    
    pub fn deinit(self: *SharedObject) void {
        if (self.name) |n| self.allocator.free(n);
        self.allocator.free(self.program_headers);
        self.dependencies.deinit();
        
        var iter = self.symbols.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.symbols.deinit();
    }
};

/// Symbol representation
const Symbol = struct {
    name: []const u8,
    value: u64,
    size: u64,
    type: u8,
    binding: u8,
    section: u16,
};

/// Symbol cache entry
const SymbolEntry = struct {
    address: u64,
    object: *SharedObject,
};

// All ELF structures and constants are imported from elf.zig