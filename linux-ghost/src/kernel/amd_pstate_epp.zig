// AMD P-State EPP (Energy Performance Preference) driver
// Supports PBO (Precision Boost Overdrive) and thermal-aware boost limiting
// Optimized for Zen 4 and newer architectures

const std = @import("std");
const msr = @import("msr.zig");
const thermal = @import("thermal.zig");
const cppc2 = @import("cppc2.zig");

pub const PBOConfig = struct {
    enabled: bool,
    ppt_limit: u32,        // Package Power Tracking limit (watts)
    tdc_limit: u32,        // Thermal Design Current limit (amps)
    edc_limit: u32,        // Electrical Design Current limit (amps)
    scalar: u32,           // Frequency scalar multiplier
    max_boost_override: u32, // Maximum boost frequency override (MHz)
    
    // Thermal limits
    thermal_throttle_temp: u8,  // Temperature to start throttling (°C)
    thermal_shutdown_temp: u8,  // Temperature for emergency shutdown (°C)
    thermal_hysteresis: u8,     // Temperature hysteresis (°C)
};

pub const AMDPStateEPP = struct {
    cppc_driver: cppc2.CPPC2Driver,
    pbo_config: PBOConfig,
    current_boost_freq: u32,
    thermal_throttled: bool,
    boost_enabled: bool,
    
    // MSR definitions for AMD PBO
    const AMD_PBO_BASE = 0xC0010062;
    const AMD_PBO_LIMIT = 0xC0010063;
    const AMD_PBO_SCALAR = 0xC0010064;
    const AMD_BOOST_OVERRIDE = 0xC0010065;
    
    // Thermal monitoring MSRs
    const AMD_TCTL_TEMP = 0xC0010066;
    const AMD_TJMAX = 0xC0010067;
    
    // P-State MSRs
    const AMD_PSTATE_CTRL = 0xC0010062;
    const AMD_PSTATE_STATUS = 0xC0010063;
    const AMD_PSTATE_DEF_BASE = 0xC0010064; // P-State definitions start here
    
    const Self = @This();
    
    pub fn init() !Self {
        var driver = Self{
            .cppc_driver = try cppc2.CPPC2Driver.init(),
            .pbo_config = PBOConfig{
                .enabled = false,
                .ppt_limit = 230,  // Default for 7950X3D
                .tdc_limit = 160,  // Default TDC
                .edc_limit = 200,  // Default EDC
                .scalar = 10,      // 10x scalar (1000MHz boost)
                .max_boost_override = 200, // +200MHz override
                .thermal_throttle_temp = 85,
                .thermal_shutdown_temp = 90,
                .thermal_hysteresis = 5,
            },
            .current_boost_freq = 0,
            .thermal_throttled = false,
            .boost_enabled = false,
        };
        
        try driver.detectPBOCapabilities();
        return driver;
    }
    
    fn detectPBOCapabilities(self: *Self) !void {
        // Check if PBO is supported via CPUID
        const cpuid_result = asm volatile (
            "cpuid"
            : [eax] "={eax}" (-> u32),
              [ebx] "={ebx}" (-> u32),
              [ecx] "={ecx}" (-> u32),
              [edx] "={edx}" (-> u32)
            : [eax] "{eax}" (@as(u32, 0x80000007))
        );
        
        // Check for PBO support (bit 7 in EDX)
        if ((cpuid_result[3] & (1 << 7)) != 0) {
            std.log.info("PBO supported on this AMD processor", .{});
            
            // Read current PBO configuration
            const pbo_base = try msr.read(AMD_PBO_BASE);
            self.pbo_config.enabled = (pbo_base & 1) != 0;
            
            if (self.pbo_config.enabled) {
                const pbo_limit = try msr.read(AMD_PBO_LIMIT);
                self.pbo_config.ppt_limit = @truncate(pbo_limit & 0xFFFF);
                self.pbo_config.tdc_limit = @truncate((pbo_limit >> 16) & 0xFFFF);
                self.pbo_config.edc_limit = @truncate((pbo_limit >> 32) & 0xFFFF);
                
                const pbo_scalar = try msr.read(AMD_PBO_SCALAR);
                self.pbo_config.scalar = @truncate(pbo_scalar & 0xFFFF);
                
                const boost_override = try msr.read(AMD_BOOST_OVERRIDE);
                self.pbo_config.max_boost_override = @truncate(boost_override & 0xFFFF);
            }
        }
    }
    
    pub fn enablePBO(self: *Self, config: PBOConfig) !void {
        if (!self.pbo_config.enabled) {
            return error.PBONotSupported;
        }
        
        self.pbo_config = config;
        self.pbo_config.enabled = true;
        
        // Configure PBO limits
        var pbo_limit: u64 = 0;
        pbo_limit |= config.ppt_limit;
        pbo_limit |= (@as(u64, config.tdc_limit) << 16);
        pbo_limit |= (@as(u64, config.edc_limit) << 32);
        
        try msr.write(AMD_PBO_LIMIT, pbo_limit);
        
        // Set frequency scalar
        try msr.write(AMD_PBO_SCALAR, config.scalar);
        
        // Set boost override
        try msr.write(AMD_BOOST_OVERRIDE, config.max_boost_override);
        
        // Enable PBO
        var pbo_base = try msr.read(AMD_PBO_BASE);
        pbo_base |= 1; // Enable PBO
        try msr.write(AMD_PBO_BASE, pbo_base);
        
        self.boost_enabled = true;
        std.log.info("PBO enabled with PPT={}, TDC={}, EDC={}, Scalar={}x", .{
            config.ppt_limit, config.tdc_limit, config.edc_limit, config.scalar
        });
    }
    
    pub fn setThermalLimits(self: *Self, throttle_temp: u8, shutdown_temp: u8) !void {
        self.pbo_config.thermal_throttle_temp = throttle_temp;
        self.pbo_config.thermal_shutdown_temp = shutdown_temp;
        
        // Set thermal limits in MSRs
        try msr.write(AMD_TJMAX, shutdown_temp);
        
        std.log.info("Thermal limits set: throttle={}°C, shutdown={}°C", .{
            throttle_temp, shutdown_temp
        });
    }
    
    pub fn getCurrentTemperature(self: *Self) !u8 {
        const tctl = try msr.read(AMD_TCTL_TEMP);
        // TCTL temperature is in 0.125°C units
        return @truncate((tctl >> 21) & 0x7FF);
    }
    
    pub fn thermalAwareBoost(self: *Self) !void {
        if (!self.boost_enabled) return;
        
        const current_temp = try self.getCurrentTemperature();
        
        if (current_temp >= self.pbo_config.thermal_throttle_temp) {
            if (!self.thermal_throttled) {
                // Start thermal throttling
                self.thermal_throttled = true;
                
                // Reduce boost frequency based on temperature
                const temp_over = current_temp - self.pbo_config.thermal_throttle_temp;
                const reduction = @min(temp_over * 50, 1000); // 50MHz per degree, max 1GHz reduction
                
                const new_boost = if (self.pbo_config.max_boost_override > reduction) 
                    self.pbo_config.max_boost_override - reduction else 0;
                
                try msr.write(AMD_BOOST_OVERRIDE, new_boost);
                self.current_boost_freq = new_boost;
                
                std.log.warn("Thermal throttling: temp={}°C, reducing boost to {}MHz", .{
                    current_temp, new_boost
                });
            }
        } else if (current_temp < (self.pbo_config.thermal_throttle_temp - self.pbo_config.thermal_hysteresis)) {
            if (self.thermal_throttled) {
                // Stop thermal throttling
                self.thermal_throttled = false;
                
                // Restore full boost frequency
                try msr.write(AMD_BOOST_OVERRIDE, self.pbo_config.max_boost_override);
                self.current_boost_freq = self.pbo_config.max_boost_override;
                
                std.log.info("Thermal throttling ended: temp={}°C, restored boost to {}MHz", .{
                    current_temp, self.pbo_config.max_boost_override
                });
            }
        }
        
        // Emergency shutdown if temperature is too high
        if (current_temp >= self.pbo_config.thermal_shutdown_temp) {
            std.log.err("EMERGENCY: CPU temperature {}°C >= {}°C, initiating emergency shutdown!", .{
                current_temp, self.pbo_config.thermal_shutdown_temp
            });
            
            // Disable PBO immediately
            var pbo_base = try msr.read(AMD_PBO_BASE);
            pbo_base &= ~@as(u64, 1); // Disable PBO
            try msr.write(AMD_PBO_BASE, pbo_base);
            
            // Set minimum performance
            try self.cppc_driver.setDesiredPerformance(self.cppc_driver.capabilities.lowest_performance);
            
            // TODO: Trigger system thermal shutdown sequence
        }
    }
    
    pub fn setGamingProfile(self: *Self) !void {
        // Aggressive gaming profile with thermal safety
        const gaming_config = PBOConfig{
            .enabled = true,
            .ppt_limit = 280,  // Higher power limit for gaming
            .tdc_limit = 180,  // Higher current limit
            .edc_limit = 220,  // Higher electrical limit
            .scalar = 15,      // More aggressive scalar (1.5GHz boost)
            .max_boost_override = 300, // +300MHz override
            .thermal_throttle_temp = 80, // More aggressive thermal throttling
            .thermal_shutdown_temp = 85, // Lower shutdown temp for safety
            .thermal_hysteresis = 3,
        };
        
        try self.enablePBO(gaming_config);
        try self.cppc_driver.setGamingMode(true);
        
        std.log.info("Gaming profile enabled: aggressive PBO with thermal safety", .{});
    }
    
    pub fn setProductivityProfile(self: *Self) !void {
        // Balanced profile for productivity workloads
        const productivity_config = PBOConfig{
            .enabled = true,
            .ppt_limit = 230,  // Stock power limit
            .tdc_limit = 160,  // Stock current limit
            .edc_limit = 200,  // Stock electrical limit
            .scalar = 10,      // Conservative scalar
            .max_boost_override = 150, // +150MHz override
            .thermal_throttle_temp = 85, // Stock thermal throttling
            .thermal_shutdown_temp = 90, // Stock shutdown temp
            .thermal_hysteresis = 5,
        };
        
        try self.enablePBO(productivity_config);
        try self.cppc_driver.setEnergyPerformancePreference(.balanced_performance);
        
        std.log.info("Productivity profile enabled: balanced PBO", .{});
    }
    
    pub fn setEcoProfile(self: *Self) !void {
        // Eco profile for maximum efficiency
        const eco_config = PBOConfig{
            .enabled = true,
            .ppt_limit = 165,  // Reduced power limit (65W TDP equivalent)
            .tdc_limit = 120,  // Reduced current limit
            .edc_limit = 150,  // Reduced electrical limit
            .scalar = 5,       // Conservative scalar
            .max_boost_override = 0, // No boost override
            .thermal_throttle_temp = 80, // Earlier thermal throttling
            .thermal_shutdown_temp = 85, // Lower shutdown temp
            .thermal_hysteresis = 5,
        };
        
        try self.enablePBO(eco_config);
        try self.cppc_driver.setEnergyPerformancePreference(.power_save);
        
        std.log.info("Eco profile enabled: power-efficient PBO", .{});
    }
    
    pub fn getCCDFrequencies(self: *Self) ![2]u32 {
        // Read current frequencies for both CCDs
        var ccd_freqs: [2]u32 = undefined;
        
        // CCD0 frequency (standard cores)
        const ccd0_pstate = try msr.read(AMD_PSTATE_STATUS);
        ccd_freqs[0] = @truncate((ccd0_pstate & 0xFF) * 25); // 25MHz per step
        
        // CCD1 frequency (X3D cores if present)
        const ccd1_pstate = try msr.read(AMD_PSTATE_STATUS + 1);
        ccd_freqs[1] = @truncate((ccd1_pstate & 0xFF) * 25);
        
        return ccd_freqs;
    }
    
    pub fn setCCDFrequencies(self: *Self, ccd0_freq: u32, ccd1_freq: u32) !void {
        // Set per-CCD frequency limits
        const ccd0_pstate = ccd0_freq / 25; // Convert to P-State steps
        const ccd1_pstate = ccd1_freq / 25;
        
        // Write P-State controls
        try msr.write(AMD_PSTATE_CTRL, ccd0_pstate);
        try msr.write(AMD_PSTATE_CTRL + 1, ccd1_pstate);
        
        std.log.info("CCD frequencies set: CCD0={}MHz, CCD1={}MHz", .{
            ccd0_freq, ccd1_freq
        });
    }
    
    pub fn optimizeForWorkload(self: *Self, workload: cppc2.WorkloadType) !void {
        switch (workload) {
            .gaming => try self.setGamingProfile(),
            .productivity => try self.setProductivityProfile(),
            .background => try self.setEcoProfile(),
            .compute => try self.setGamingProfile(), // Use gaming profile for compute
        }
        
        // Apply thermal-aware boost after profile change
        try self.thermalAwareBoost();
    }
    
    pub fn startThermalMonitoring(self: *Self) !void {
        // This would be called periodically by the kernel scheduler
        // For now, just apply thermal-aware boost
        try self.thermalAwareBoost();
    }
    
    pub fn getStatus(self: *Self) !struct {
        temperature: u8,
        boost_freq: u32,
        thermal_throttled: bool,
        pbo_enabled: bool,
        ccd_freqs: [2]u32,
    } {
        return .{
            .temperature = try self.getCurrentTemperature(),
            .boost_freq = self.current_boost_freq,
            .thermal_throttled = self.thermal_throttled,
            .pbo_enabled = self.pbo_config.enabled,
            .ccd_freqs = try self.getCCDFrequencies(),
        };
    }
};