//! Process and Task Management
//! Handles process creation, context switching, and task lifecycle

const std = @import("std");
const sched = @import("sched.zig");
const memory = @import("../mm/memory.zig");
const paging = @import("../arch/x86_64/paging.zig");
const console = @import("../arch/x86_64/console.zig");

/// Process ID type
pub const Pid = u32;

/// Process states
pub const ProcessState = enum {
    embryo,     // Being created
    sleeping,   // Waiting for event
    runnable,   // Ready to run
    running,    // Currently executing
    zombie,     // Terminated, waiting for parent
    dead,       // Can be freed
};

/// CPU context for context switching
pub const Context = extern struct {
    // Callee-saved registers
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbx: u64,
    rbp: u64,
    rip: u64,   // Return address
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .r15 = 0,
            .r14 = 0,
            .r13 = 0,
            .r12 = 0,
            .rbx = 0,
            .rbp = 0,
            .rip = 0,
        };
    }
};

/// File descriptor
pub const FileDescriptor = struct {
    file: ?*File,
    offset: u64,
    flags: u32,
};

/// Process control block
pub const Process = struct {
    pid: Pid,
    ppid: Pid,                      // Parent PID
    state: ProcessState,
    exit_code: i32,
    
    // Memory management
    address_space: ?*paging.AddressSpace,
    mm: ?*memory.MemoryDescriptor,
    kernel_stack: ?*anyopaque,
    kernel_stack_size: usize,
    
    // CPU context
    context: Context,
    
    // Scheduling
    task: sched.Task,
    cpu_affinity: u64,              // CPU affinity mask
    
    // File descriptors
    files: [MAX_FDS]FileDescriptor,
    cwd: ?*Dentry,                  // Current working directory
    
    // Signal handling
    pending_signals: u64,
    signal_handlers: [64]SignalHandler,
    
    // Statistics
    start_time: u64,
    user_time: u64,
    kernel_time: u64,
    
    // Process tree
    parent: ?*Process,
    children: ?*Process,
    siblings: ?*Process,
    
    // Thread group
    thread_group: ?*Process,        // Thread group leader
    threads: ?*Process,             // Thread list
    
    const Self = @This();
    
    pub fn init(pid: Pid) Self {
        return Self{
            .pid = pid,
            .ppid = 0,
            .state = .embryo,
            .exit_code = 0,
            .address_space = null,
            .mm = null,
            .kernel_stack = null,
            .kernel_stack_size = KERNEL_STACK_SIZE,
            .context = Context.init(),
            .task = sched.Task.init(pid, 0),
            .cpu_affinity = 0xFFFF_FFFF_FFFF_FFFF, // All CPUs
            .files = [_]FileDescriptor{.{ .file = null, .offset = 0, .flags = 0 }} ** MAX_FDS,
            .cwd = null,
            .pending_signals = 0,
            .signal_handlers = [_]SignalHandler{.default} ** 64,
            .start_time = getTime(),
            .user_time = 0,
            .kernel_time = 0,
            .parent = null,
            .children = null,
            .siblings = null,
            .thread_group = null,
            .threads = null,
        };
    }
    
    pub fn allocateKernelStack(self: *Self) !void {
        const stack_pages = memory.allocPagesGlobal(KERNEL_STACK_ORDER) orelse return error.OutOfMemory;
        self.kernel_stack = @ptrFromInt(stack_pages.getVirtAddr());
        self.kernel_stack_size = KERNEL_STACK_SIZE;
        
        // Initialize stack with guard pattern
        const stack_bytes: [*]u8 = @ptrCast(self.kernel_stack);
        for (0..256) |i| {
            stack_bytes[i] = 0xDE; // Stack guard pattern
        }
    }
    
    pub fn freeKernelStack(self: *Self) void {
        if (self.kernel_stack) |stack| {
            const stack_addr = @intFromPtr(stack);
            const stack_phys = paging.virtToPhys(stack_addr);
            // TODO: Free pages
            _ = stack_phys;
            self.kernel_stack = null;
        }
    }
    
    pub fn setupAddressSpace(self: *Self) !void {
        self.address_space = try allocator.create(paging.AddressSpace);
        self.address_space.* = try paging.AddressSpace.init();
        
        self.mm = try allocator.create(memory.MemoryDescriptor);
        self.mm.* = memory.MemoryDescriptor{
            .vmas = null,
            .mmap_base = USER_MMAP_BASE,
            .start_code = 0,
            .end_code = 0,
            .start_data = 0,
            .end_data = 0,
            .start_brk = USER_HEAP_BASE,
            .brk = USER_HEAP_BASE,
            .start_stack = USER_STACK_TOP,
            .total_vm = 0,
            .locked_vm = 0,
            .shared_vm = 0,
            .exec_vm = 0,
            .stack_vm = 0,
            .ref_count = 1,
        };
    }
    
    pub fn switchTo(self: *Self) void {
        // Switch address space
        if (self.address_space) |as| {
            as.switchTo();
        }
        
        // Update current process
        current_process = self;
        
        // Switch CPU context
        contextSwitch(&self.context);
    }
    
    pub fn exit(self: *Self, code: i32) void {
        self.exit_code = code;
        self.state = .zombie;
        
        // Close all file descriptors
        for (&self.files) |*fd| {
            if (fd.file) |file| {
                _ = file; // TODO: Close file
                fd.file = null;
            }
        }
        
        // Free memory
        if (self.address_space) |as| {
            as.deinit();
            allocator.destroy(as);
            self.address_space = null;
        }
        
        // Reparent children to init
        // TODO: Implement
        
        // Wake up parent
        if (self.parent) |parent| {
            wakeup(parent);
        }
    }
    
    pub fn wait(self: *Self) !Pid {
        while (true) {
            // Check for zombie children
            var child = self.children;
            while (child) |c| {
                if (c.state == .zombie) {
                    const pid = c.pid;
                    const exit_code = c.exit_code;
                    
                    // Remove from children list
                    removeChild(self, c);
                    
                    // Free process
                    c.state = .dead;
                    freeProcess(c);
                    
                    return pid;
                }
                child = c.siblings;
            }
            
            // Sleep until child exits
            sleep(self);
        }
    }
};

// File and directory placeholders
const File = struct {};
const Dentry = struct {};
const SignalHandler = enum { default, ignore, custom };

// Constants
const MAX_FDS = 256;
const KERNEL_STACK_SIZE = 16 * 1024; // 16KB
const KERNEL_STACK_ORDER = 2; // 4 pages
const USER_MMAP_BASE: u64 = 0x0000_7000_0000_0000;
const USER_HEAP_BASE: u64 = 0x0000_6000_0000_0000;
const USER_STACK_TOP: u64 = 0x0000_7fff_ffff_0000;

// Global state
var next_pid: Pid = 1;
var current_process: ?*Process = null;
var process_list: ?*Process = null;
var allocator = std.heap.page_allocator; // TODO: Use kernel allocator

/// Initialize process subsystem
pub fn init() !void {
    console.writeString("Initializing process management...\n");
    
    // Create init process (PID 1)
    const init_proc = try createProcess();
    init_proc.ppid = 0;
    init_proc.state = .runnable;
    
    current_process = init_proc;
    
    console.writeString("Process management initialized\n");
}

/// Create a new process
pub fn createProcess() !*Process {
    const pid = getNextPid();
    
    const proc = try allocator.create(Process);
    proc.* = Process.init(pid);
    
    try proc.allocateKernelStack();
    try proc.setupAddressSpace();
    
    // Add to process list
    if (process_list) |list| {
        proc.siblings = list;
    }
    process_list = proc;
    
    return proc;
}

/// Fork current process
pub fn fork() !Pid {
    const parent = current_process orelse return error.NoCurrentProcess;
    
    const child = try createProcess();
    child.ppid = parent.pid;
    child.parent = parent;
    
    // Copy address space
    // TODO: Implement copy-on-write
    
    // Copy file descriptors
    child.files = parent.files;
    for (&child.files) |*fd| {
        if (fd.file) |file| {
            _ = file; // TODO: Increment reference count
        }
    }
    
    // Copy signal handlers
    child.signal_handlers = parent.signal_handlers;
    
    // Set up return values
    // Parent returns child PID, child returns 0
    child.context = parent.context;
    // TODO: Set return value register to 0 for child
    
    // Add to parent's children
    addChild(parent, child);
    
    // Make child runnable
    child.state = .runnable;
    
    return child.pid;
}

/// Execute a new program
pub fn exec(path: []const u8, argv: []const []const u8, envp: []const []const u8) !void {
    _ = path;
    _ = argv;
    _ = envp;
    
    const proc = current_process orelse return error.NoCurrentProcess;
    
    // TODO: Load executable
    // TODO: Set up new address space
    // TODO: Copy arguments and environment
    // TODO: Set up initial stack
    // TODO: Jump to entry point
    
    _ = proc;
}

/// Get next available PID
fn getNextPid() Pid {
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

/// Add child to parent's children list
fn addChild(parent: *Process, child: *Process) void {
    child.siblings = parent.children;
    parent.children = child;
}

/// Remove child from parent's children list
fn removeChild(parent: *Process, child: *Process) void {
    if (parent.children == child) {
        parent.children = child.siblings;
    } else {
        var prev = parent.children;
        while (prev) |p| {
            if (p.siblings == child) {
                p.siblings = child.siblings;
                break;
            }
            prev = p.siblings;
        }
    }
    child.siblings = null;
}

/// Free process resources
fn freeProcess(proc: *Process) void {
    proc.freeKernelStack();
    
    // Remove from process list
    if (process_list == proc) {
        process_list = proc.siblings;
    } else {
        var prev = process_list;
        while (prev) |p| {
            if (p.siblings == proc) {
                p.siblings = proc.siblings;
                break;
            }
            prev = p.siblings;
        }
    }
    
    allocator.destroy(proc);
}

/// Context switch assembly
extern fn contextSwitch(new_context: *Context) void;

/// Sleep process
fn sleep(proc: *Process) void {
    proc.state = .sleeping;
    sched.schedule();
}

/// Wake up process
fn wakeup(proc: *Process) void {
    if (proc.state == .sleeping) {
        proc.state = .runnable;
    }
}

/// Get current time
fn getTime() u64 {
    // TODO: Implement proper time keeping
    return 0;
}

/// Get current process
pub fn getCurrentProcess() ?*Process {
    return current_process;
}

/// Assembly context switch implementation
comptime {
    asm (
        \\.global contextSwitch
        \\contextSwitch:
        \\    // Save current context
        \\    pushq %r15
        \\    pushq %r14
        \\    pushq %r13
        \\    pushq %r12
        \\    pushq %rbx
        \\    pushq %rbp
        \\    
        \\    // Switch stacks
        \\    movq %rsp, current_context
        \\    movq %rdi, %rsp
        \\    
        \\    // Restore new context
        \\    popq %rbp
        \\    popq %rbx
        \\    popq %r12
        \\    popq %r13
        \\    popq %r14
        \\    popq %r15
        \\    
        \\    ret
        \\
        \\.data
        \\current_context: .quad 0
    );
}