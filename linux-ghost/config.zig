const std = @import("std");

pub const KernelConfig = struct {
    // Kernel variant
    variant: Variant,
    
    // Scheduler configuration
    scheduler: Scheduler = .bore_eevdf,
    sched_ext_support: bool = true,
    
    // Compiler optimization
    compiler: Compiler = .llvm,
    lto_mode: LTOMode = .thin,
    optimization_level: u8 = 3,
    cc_harder: bool = true,
    
    // CPU architecture
    cpu_arch: CPUArch = .znver4,
    march_native: bool = false,
    x86_64_v3: bool = true,
    x86_64_v4: bool = true,
    
    // Performance tuning
    hz_ticks: HzTicks = .@"1000",
    preempt_mode: PreemptMode = .full,
    tcp_congestion: TCPCongestion = .bbr3,
    hugepages: HugePages = .always,
    
    // Gaming optimizations
    fsync_support: bool = true,
    nvidia_open_support: bool = true,
    low_latency_patches: bool = true,
    
    // Build options
    debug_info: bool = false,
    module_compression: bool = true,
    initramfs_compression: InitramfsCompression = .zstd,
    
    pub const Variant = enum {
        ghost,          // Bore-EEVDF + gaming patches
        ghost_cachy,    // BORE + CachyOS sauce
        
        pub fn toString(self: Variant) []const u8 {
            return switch (self) {
                .ghost => "ghost",
                .ghost_cachy => "ghost-cachy",
            };
        }
    };
    
    pub const Scheduler = enum {
        bore_eevdf,     // Default for linux-ghost
        bore,           // CachyOS style BORE
        eevdf,          // Upstream EEVDF
        cfs,            // Legacy CFS
        
        pub fn patchFile(self: Scheduler) []const u8 {
            return switch (self) {
                .bore_eevdf => "0001-bore-eevdf.patch",
                .bore => "0001-bore-cachy.patch", 
                .eevdf => null, // Upstream default
                .cfs => "0001-revert-eevdf.patch",
            };
        }
    };
    
    pub const Compiler = enum {
        llvm,   // Clang/LLVM (recommended for LTO)
        gcc,    // GCC (fallback)
        
        pub fn toString(self: Compiler) []const u8 {
            return switch (self) {
                .llvm => "clang",
                .gcc => "gcc",
            };
        }
    };
    
    pub const LTOMode = enum {
        none,
        thin,   // Recommended: fast compilation, good performance
        full,   // Slow compilation, maximum performance
        
        pub fn toString(self: LTOMode) []const u8 {
            return switch (self) {
                .none => "none",
                .thin => "thin", 
                .full => "full",
            };
        }
    };
    
    pub const CPUArch = enum {
        znver4,     // AMD Zen 4 (default)
        znver3,     // AMD Zen 3
        znver2,     // AMD Zen 2  
        znver1,     // AMD Zen 1
        raptorlake, // Intel Raptor Lake (13th gen)
        alderlake,  // Intel Alder Lake (12th gen)
        skylake,    // Intel Skylake
        generic,    // Generic x86_64
        native,     // Detect at build time
        
        pub fn toString(self: CPUArch) []const u8 {
            return switch (self) {
                .znver4 => "znver4",
                .znver3 => "znver3", 
                .znver2 => "znver2",
                .znver1 => "znver1",
                .raptorlake => "raptorlake",
                .alderlake => "alderlake",
                .skylake => "skylake",
                .generic => "x86-64",
                .native => "native",
            };
        }
        
        pub fn configOption(self: CPUArch) []const u8 {
            return switch (self) {
                .znver4 => "MZEN4",
                .znver3 => "MZEN3",
                .znver2 => "MZEN2", 
                .znver1 => "MZEN",
                .raptorlake => "MRAPTORLAKE",
                .alderlake => "MALDERLAKE",
                .skylake => "MSKYLAKE",
                .generic => "GENERIC_CPU",
                .native => "MNATIVE_INTEL", // Will be detected
            };
        }
    };
    
    pub const HzTicks = enum {
        @"100",
        @"250", 
        @"300",
        @"500",
        @"1000",    // Gaming default
        
        pub fn value(self: HzTicks) u16 {
            return switch (self) {
                .@"100" => 100,
                .@"250" => 250,
                .@"300" => 300, 
                .@"500" => 500,
                .@"1000" => 1000,
            };
        }
    };
    
    pub const PreemptMode = enum {
        none,       // No preemption
        voluntary,  // Voluntary preemption
        server,     // Server workloads
        full,       // Full preemption (gaming)
        rt,         // Real-time preemption
        
        pub fn configValue(self: PreemptMode) []const u8 {
            return switch (self) {
                .none => "PREEMPT_NONE",
                .voluntary => "PREEMPT_VOLUNTARY",
                .server => "PREEMPT",
                .full => "PREEMPT",
                .rt => "PREEMPT_RT",
            };
        }
    };
    
    pub const TCPCongestion = enum {
        bbr3,       // Latest BBR (gaming)
        bbr2,       // BBR v2
        bbr,        // Original BBR
        cubic,      // Default cubic
        
        pub fn toString(self: TCPCongestion) []const u8 {
            return switch (self) {
                .bbr3 => "bbr3",
                .bbr2 => "bbr2", 
                .bbr => "bbr",
                .cubic => "cubic",
            };
        }
    };
    
    pub const HugePages = enum {
        always,     // Always use hugepages
        madvise,    // Use on madvise()
        never,      // Never use hugepages
        
        pub fn toString(self: HugePages) []const u8 {
            return switch (self) {
                .always => "always",
                .madvise => "madvise",
                .never => "never",
            };
        }
    };
    
    pub const InitramfsCompression = enum {
        zstd,       // Fast compression
        lz4,        // Faster decompression
        xz,         // Better compression
        gzip,       // Legacy
        
        pub fn toString(self: InitramfsCompression) []const u8 {
            return switch (self) {
                .zstd => "zstd",
                .lz4 => "lz4",
                .xz => "xz", 
                .gzip => "gzip",
            };
        }
    };
    
    pub fn initGhost() KernelConfig {
        return KernelConfig{
            .variant = .ghost,
            .scheduler = .bore_eevdf,
        };
    }
    
    pub fn initGhostCachy() KernelConfig {
        return KernelConfig{
            .variant = .ghost_cachy,
            .scheduler = .bore,
        };
    }
    
    pub fn toCFlags(self: KernelConfig, allocator: std.mem.Allocator) ![]const u8 {
        var flags = std.ArrayList(u8).init(allocator);
        defer flags.deinit();
        
        const writer = flags.writer();
        
        try writer.print("-march={s} ", .{self.cpu_arch.toString()});
        try writer.print("-O{d} ", .{self.optimization_level});
        
        if (self.cc_harder) {
            try writer.writeAll("-O3 ");
        }
        
        if (self.x86_64_v3) {
            try writer.writeAll("-msse4.2 -mavx -mavx2 ");
        }
        
        if (self.x86_64_v4) {
            try writer.writeAll("-mavx512f -mavx512bw -mavx512cd -mavx512dq -mavx512vl ");
        }
        
        return flags.toOwnedSlice();
    }
}