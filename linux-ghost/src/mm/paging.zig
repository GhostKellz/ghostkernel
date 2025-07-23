// Re-export arch-specific paging implementation
const arch_paging = @import("../arch/x86_64/paging.zig");

pub const AddressSpace = arch_paging.AddressSpace;
pub const PageFlags = arch_paging.PageFlags;
pub const PAGE_PRESENT = arch_paging.PAGE_PRESENT;
pub const PAGE_WRITABLE = arch_paging.PAGE_WRITABLE;
pub const PAGE_USER = arch_paging.PAGE_USER;
pub const PAGE_NX = arch_paging.PAGE_NX;
pub const init = arch_paging.init;
pub const physToVirt = arch_paging.physToVirt;
pub const virtToPhys = arch_paging.virtToPhys;
pub const getCR3 = arch_paging.getCR3;