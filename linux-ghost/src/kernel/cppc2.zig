// CPPC2 (Collaborative Processor Performance Control) Version 2
// Zen 4 and modern Intel processors support for fine-grained performance control

const std = @import("std");
const msr = @import("msr.zig");
const acpi = @import("acpi.zig");

pub const CPPCCapabilities = struct {
    highest_performance: u32,
    nominal_performance: u32,
    lowest_nonlinear_performance: u32,
    lowest_performance: u32,
    guaranteed_performance: u32,
    autonomous_selection_enable: bool,
    autonomous_activity_window: u32,
    energy_performance_preference: u8,
    reference_performance: u32,
    supports_cppc2: bool,
};

pub const EPPMode = enum(u8) {
    performance = 0x00,        // Maximum performance
    balanced_performance = 0x80, // Balanced towards performance
    balanced_power = 0xC0,     // Balanced towards power
    power_save = 0xFF,         // Maximum power saving
};

pub const CPPC2Driver = struct {
    capabilities: CPPCCapabilities,
    current_performance: u32,
    desired_performance: u32,
    energy_performance_preference: EPPMode,
    autonomous_mode: bool,
    
    // MSR definitions for AMD Zen 4
    const AMD_CPPC_CAP1 = 0xC00102B0;
    const AMD_CPPC_CAP2 = 0xC00102B1; 
    const AMD_CPPC_REQ = 0xC00102B3;
    const AMD_CPPC_STATUS = 0xC00102B4;
    const AMD_EPP_REQ = 0xC00102B5;
    
    // Intel MSR definitions
    const INTEL_HWP_CAPABILITIES = 0x771;
    const INTEL_HWP_REQUEST = 0x774;
    const INTEL_HWP_STATUS = 0x777;
    
    const Self = @This();
    
    pub fn init() !Self {
        var driver = Self{
            .capabilities = undefined,
            .current_performance = 0,
            .desired_performance = 0,
            .energy_performance_preference = .balanced_performance,
            .autonomous_mode = false,
        };
        
        try driver.detectCapabilities();
        return driver;
    }
    
    fn detectCapabilities(self: *Self) !void {
        const cpu_info = try getCPUInfo();
        
        if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            try self.detectAMDCPPC();
        } else if (std.mem.indexOf(u8, cpu_info.vendor, "GenuineIntel") != null) {
            try self.detectIntelHWP();
        } else {
            return error.UnsupportedCPU;
        }
    }
    
    fn detectAMDCPPC(self: *Self) !void {
        // Check if CPPC is supported via CPUID
        const cpuid_result = asm volatile (
            "cpuid"
            : [eax] "={eax}" (-> u32),
              [ebx] "={ebx}" (-> u32),
              [ecx] "={ecx}" (-> u32),
              [edx] "={edx}" (-> u32)
            : [eax] "{eax}" (@as(u32, 0x80000008))
        );
        
        if ((cpuid_result[1] & (1 << 27)) == 0) {
            return error.CPPCNotSupported;
        }
        
        // Read capabilities from MSRs
        const cap1 = try msr.read(AMD_CPPC_CAP1);
        const cap2 = try msr.read(AMD_CPPC_CAP2);
        
        self.capabilities = CPPCCapabilities{
            .highest_performance = @truncate(cap1 & 0xFF),
            .nominal_performance = @truncate((cap1 >> 8) & 0xFF),
            .lowest_nonlinear_performance = @truncate((cap1 >> 16) & 0xFF),
            .lowest_performance = @truncate((cap1 >> 24) & 0xFF),
            .guaranteed_performance = @truncate(cap2 & 0xFF),
            .autonomous_selection_enable = (cap2 & (1 << 8)) != 0,
            .autonomous_activity_window = @truncate((cap2 >> 10) & 0x3FF),
            .energy_performance_preference = @truncate((cap2 >> 24) & 0xFF),
            .reference_performance = @truncate((cap2 >> 32) & 0xFF),
            .supports_cppc2 = true,
        };
    }
    
    fn detectIntelHWP(self: *Self) !void {
        // Check HWP support via CPUID
        const cpuid_result = asm volatile (
            "cpuid"
            : [eax] "={eax}" (-> u32),
              [ebx] "={ebx}" (-> u32),
              [ecx] "={ecx}" (-> u32),
              [edx] "={edx}" (-> u32)
            : [eax] "{eax}" (@as(u32, 0x06))
        );
        
        if ((cpuid_result[0] & (1 << 7)) == 0) {
            return error.HWPNotSupported;
        }
        
        // Read capabilities from MSR
        const cap = try msr.read(INTEL_HWP_CAPABILITIES);
        
        self.capabilities = CPPCCapabilities{
            .highest_performance = @truncate(cap & 0xFF),
            .guaranteed_performance = @truncate((cap >> 8) & 0xFF),
            .lowest_nonlinear_performance = @truncate((cap >> 16) & 0xFF),
            .lowest_performance = @truncate((cap >> 24) & 0xFF),
            .nominal_performance = @truncate((cap >> 8) & 0xFF),
            .autonomous_selection_enable = (cpuid_result[0] & (1 << 8)) != 0,
            .autonomous_activity_window = 0,
            .energy_performance_preference = 0x80, // Default balanced
            .reference_performance = @truncate((cap >> 8) & 0xFF),
            .supports_cppc2 = true,
        };
    }
    
    pub fn setDesiredPerformance(self: *Self, performance: u32) !void {
        if (performance > self.capabilities.highest_performance) {
            return error.PerformanceOutOfRange;
        }
        
        self.desired_performance = performance;
        
        const cpu_info = try getCPUInfo();
        if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            try self.setAMDPerformance(performance);
        } else {
            try self.setIntelPerformance(performance);
        }
    }
    
    fn setAMDPerformance(self: *Self, performance: u32) !void {
        // Build CPPC request
        var request: u64 = 0;
        request |= performance; // Desired performance
        request |= (@as(u64, performance) << 16); // Minimum performance
        request |= (@as(u64, self.capabilities.highest_performance) << 32); // Maximum performance
        request |= (@as(u64, @intFromEnum(self.energy_performance_preference)) << 48); // EPP
        
        try msr.write(AMD_CPPC_REQ, request);
    }
    
    fn setIntelPerformance(self: *Self, performance: u32) !void {
        // Build HWP request
        var request: u64 = 0;
        request |= performance; // Desired performance
        request |= (@as(u64, performance) << 8); // Minimum performance
        request |= (@as(u64, self.capabilities.highest_performance) << 16); // Maximum performance
        request |= (@as(u64, @intFromEnum(self.energy_performance_preference)) << 24); // EPP
        
        try msr.write(INTEL_HWP_REQUEST, request);
    }
    
    pub fn setEnergyPerformancePreference(self: *Self, epp: EPPMode) !void {
        self.energy_performance_preference = epp;
        
        const cpu_info = try getCPUInfo();
        if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            try msr.write(AMD_EPP_REQ, @intFromEnum(epp));
        }
        
        // Re-apply current performance settings with new EPP
        try self.setDesiredPerformance(self.desired_performance);
    }
    
    pub fn enableAutonomousMode(self: *Self, window_us: u32) !void {
        if (!self.capabilities.autonomous_selection_enable) {
            return error.AutonomousModeNotSupported;
        }
        
        self.autonomous_mode = true;
        
        // Set autonomous activity window
        const cpu_info = try getCPUInfo();
        if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            var request = try msr.read(AMD_CPPC_REQ);
            request |= (@as(u64, window_us) << 32);
            request |= (1 << 40); // Enable autonomous selection
            try msr.write(AMD_CPPC_REQ, request);
        }
    }
    
    pub fn getCurrentPerformance(self: *Self) !u32 {
        const cpu_info = try getCPUInfo();
        if (std.mem.indexOf(u8, cpu_info.vendor, "AuthenticAMD") != null) {
            const status = try msr.read(AMD_CPPC_STATUS);
            return @truncate(status & 0xFF);
        } else {
            const status = try msr.read(INTEL_HWP_STATUS);
            return @truncate(status & 0xFF);
        }
    }
    
    pub fn setGamingMode(self: *Self, enable: bool) !void {
        if (enable) {
            // Gaming mode: max performance, low latency
            try self.setEnergyPerformancePreference(.performance);
            try self.setDesiredPerformance(self.capabilities.highest_performance);
            
            if (self.capabilities.autonomous_selection_enable) {
                try self.enableAutonomousMode(1000); // 1ms window for low latency
            }
        } else {
            // Normal mode: balanced
            try self.setEnergyPerformancePreference(.balanced_performance);
            try self.setDesiredPerformance(self.capabilities.nominal_performance);
        }
    }
    
    pub fn adjustForWorkload(self: *Self, workload_type: WorkloadType) !void {
        switch (workload_type) {
            .gaming => try self.setGamingMode(true),
            .productivity => {
                try self.setEnergyPerformancePreference(.balanced_performance);
                try self.setDesiredPerformance(self.capabilities.nominal_performance);
            },
            .background => {
                try self.setEnergyPerformancePreference(.power_save);
                try self.setDesiredPerformance(self.capabilities.lowest_nonlinear_performance);
            },
            .compute => {
                try self.setEnergyPerformancePreference(.performance);
                try self.setDesiredPerformance(self.capabilities.highest_performance);
            },
        }
    }
};

pub const WorkloadType = enum {
    gaming,
    productivity,
    background,
    compute,
};

// Placeholder for CPU info detection
fn getCPUInfo() !struct { vendor: []const u8 } {
    // This would read from CPUID
    return .{ .vendor = "AuthenticAMD" };
}