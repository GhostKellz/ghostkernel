//! x86_64 Interrupt Management
//! Basic interrupt handling for the Zig kernel

const std = @import("std");
const console = @import("console.zig");

/// Interrupt descriptor table entry
const IDTEntry = packed struct {
    offset_low: u16,    // Offset bits 0-15
    selector: u16,      // Code segment selector
    ist: u3,            // Interrupt Stack Table offset
    reserved1: u5,      // Reserved
    gate_type: u4,      // Gate type
    s: u1,              // Storage segment (0 for interrupt gates)
    dpl: u2,            // Descriptor privilege level
    present: u1,        // Present bit
    offset_mid: u16,    // Offset bits 16-31
    offset_high: u32,   // Offset bits 32-63
    reserved2: u32,     // Reserved
    
    const Self = @This();
    
    pub fn init(handler: u64, selector: u16, gate_type: u4, dpl: u2) Self {
        return Self{
            .offset_low = @truncate(handler),
            .selector = selector,
            .ist = 0,
            .reserved1 = 0,
            .gate_type = gate_type,
            .s = 0,
            .dpl = dpl,
            .present = 1,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .reserved2 = 0,
        };
    }
};

/// IDT descriptor for LIDT instruction
const IDTDescriptor = packed struct {
    limit: u16,
    base: u64,
};

/// Exception types
pub const Exception = enum(u8) {
    divide_error = 0,
    debug = 1,
    nmi = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range_exceeded = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_segment_fault = 12,
    general_protection = 13,
    page_fault = 14,
    spurious_interrupt = 15,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,
};

/// Interrupt frame passed to handlers
pub const InterruptFrame = packed struct {
    // Pushed by our interrupt stubs
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    
    // Error code (for some exceptions)
    error_code: u64,
    
    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Interrupt handler function type
pub const InterruptHandler = *const fn (*InterruptFrame) callconv(.C) void;

// Global IDT
var idt: [256]IDTEntry = undefined;
var idt_descriptor: IDTDescriptor = undefined;
var interrupt_handlers: [256]?InterruptHandler = [_]?InterruptHandler{null} ** 256;

/// Initialize interrupt handling
pub fn init() !void {
    console.writeString("Initializing interrupt subsystem...\n");
    
    // Initialize IDT entries
    for (&idt, 0..) |*entry, i| {
        entry.* = IDTEntry.init(
            @intFromPtr(getInterruptStub(i)),
            0x08, // Kernel code segment
            0xE,  // Interrupt gate
            0,    // Ring 0
        );
    }
    
    // Set up exception handlers
    setHandler(@intFromEnum(Exception.divide_error), divideErrorHandler);
    setHandler(@intFromEnum(Exception.debug), debugHandler);
    setHandler(@intFromEnum(Exception.breakpoint), breakpointHandler);
    setHandler(@intFromEnum(Exception.invalid_opcode), invalidOpcodeHandler);
    setHandler(@intFromEnum(Exception.general_protection), generalProtectionHandler);
    setHandler(@intFromEnum(Exception.page_fault), pageFaultHandler);
    setHandler(@intFromEnum(Exception.double_fault), doubleFaultHandler);
    
    // Load IDT
    idt_descriptor = IDTDescriptor{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    
    loadIDT(&idt_descriptor);
    
    console.writeString("Interrupt subsystem initialized\n");
}

/// Set interrupt handler
pub fn setHandler(vector: u8, handler: InterruptHandler) void {
    interrupt_handlers[vector] = handler;
}

/// Enable interrupts
pub fn enable() void {
    asm volatile ("sti");
}

/// Disable interrupts
pub fn disable() void {
    asm volatile ("cli");
}

/// Check if interrupts are enabled
pub fn areEnabled() bool {
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
    );
    return (flags & (1 << 9)) != 0;
}

/// Generic interrupt handler
export fn interruptHandler(vector: u8, frame: *InterruptFrame) callconv(.C) void {
    if (interrupt_handlers[vector]) |handler| {
        handler(frame);
    } else {
        console.setColor(.red, .black);
        console.printf("Unhandled interrupt: vector={d}\n", .{vector});
        console.printf("RIP: 0x{X}\n", .{frame.rip});
        console.setColor(.white, .black);
    }
}

// Exception handlers
fn divideErrorHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.red, .black);
    console.writeString("EXCEPTION: Divide by zero\n");
    console.printf("RIP: 0x{X}\n", .{frame.rip});
    console.setColor(.white, .black);
    panic("Divide by zero exception");
}

fn debugHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.yellow, .black);
    console.writeString("DEBUG: Debug exception\n");
    console.printf("RIP: 0x{X}\n", .{frame.rip});
    console.setColor(.white, .black);
}

fn breakpointHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.cyan, .black);
    console.writeString("BREAKPOINT: INT3 instruction\n");
    console.printf("RIP: 0x{X}\n", .{frame.rip});
    console.setColor(.white, .black);
}

fn invalidOpcodeHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.red, .black);
    console.writeString("EXCEPTION: Invalid opcode\n");
    console.printf("RIP: 0x{X}\n", .{frame.rip});
    console.setColor(.white, .black);
    panic("Invalid opcode exception");
}

fn generalProtectionHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.red, .black);
    console.writeString("EXCEPTION: General protection fault\n");
    console.printf("RIP: 0x{X}, Error: 0x{X}\n", .{ frame.rip, frame.error_code });
    console.setColor(.white, .black);
    panic("General protection fault");
}

fn pageFaultHandler(frame: *InterruptFrame) callconv(.C) void {
    const cr2 = asm volatile ("movq %%cr2, %[cr2]"
        : [cr2] "=r" (-> u64),
    );
    
    console.setColor(.red, .black);
    console.writeString("EXCEPTION: Page fault\n");
    console.printf("RIP: 0x{X}, CR2: 0x{X}, Error: 0x{X}\n", .{ frame.rip, cr2, frame.error_code });
    
    // Decode error code
    const present = (frame.error_code & 1) != 0;
    const write = (frame.error_code & 2) != 0;
    const user = (frame.error_code & 4) != 0;
    
    console.printf("  %s, %s, %s mode\n", .{
        if (present) "protection violation" else "page not present",
        if (write) "write" else "read",
        if (user) "user" else "kernel",
    });
    
    console.setColor(.white, .black);
    panic("Page fault exception");
}

fn doubleFaultHandler(frame: *InterruptFrame) callconv(.C) void {
    console.setColor(.red, .black);
    console.writeString("FATAL: Double fault\n");
    console.printf("RIP: 0x{X}, Error: 0x{X}\n", .{ frame.rip, frame.error_code });
    console.setColor(.white, .black);
    panic("Double fault - system halted");
}

// Assembly interrupt stubs
fn getInterruptStub(vector: u8) *const fn () callconv(.Naked) void {
    // This is a simplified version - in reality we'd need 256 unique stubs
    _ = vector;
    return &interruptStub;
}

fn interruptStub() callconv(.Naked) void {
    // Save all registers
    asm volatile (
        \\pushq %rax
        \\pushq %rbx
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %rbp
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\
        \\movq %rsp, %rsi    # Frame pointer
        \\movq $0, %rdi      # Vector number (simplified)
        \\call interruptHandler
        \\
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rbp
        \\popq %rdi
        \\popq %rsi
        \\popq %rdx
        \\popq %rcx
        \\popq %rbx
        \\popq %rax
        \\
        \\iretq
    );
}

fn loadIDT(descriptor: *const IDTDescriptor) void {
    asm volatile ("lidt (%[desc])"
        :
        : [desc] "r" (descriptor),
        : "memory"
    );
}

fn panic(message: []const u8) noreturn {
    @import("../kernel/kernel.zig").panic(message, null, null);
}