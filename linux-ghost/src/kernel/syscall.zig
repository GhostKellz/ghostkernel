//! System Call Interface
//! Linux-compatible system call implementation in Zig

const std = @import("std");
const process = @import("process.zig");
const memory = @import("../mm/memory.zig");
const console = @import("../arch/x86_64/console.zig");
const timer = @import("timer.zig");

/// System call numbers (x86_64 Linux ABI)
pub const SysCall = enum(u64) {
    read = 0,
    write = 1,
    open = 2,
    close = 3,
    stat = 4,
    fstat = 5,
    lstat = 6,
    poll = 7,
    lseek = 8,
    mmap = 9,
    mprotect = 10,
    munmap = 11,
    brk = 12,
    rt_sigaction = 13,
    rt_sigprocmask = 14,
    ioctl = 16,
    pread64 = 17,
    pwrite64 = 18,
    readv = 19,
    writev = 20,
    access = 21,
    pipe = 22,
    select = 23,
    sched_yield = 24,
    mremap = 25,
    msync = 26,
    mincore = 27,
    madvise = 28,
    shmget = 29,
    shmat = 30,
    shmctl = 31,
    dup = 32,
    dup2 = 33,
    pause = 34,
    nanosleep = 35,
    getitimer = 36,
    alarm = 37,
    setitimer = 38,
    getpid = 39,
    sendfile = 40,
    socket = 41,
    connect = 42,
    accept = 43,
    sendto = 44,
    recvfrom = 45,
    shutdown = 48,
    bind = 49,
    listen = 50,
    getsockname = 51,
    getpeername = 52,
    socketpair = 53,
    clone = 56,
    fork = 57,
    vfork = 58,
    execve = 59,
    exit = 60,
    wait4 = 61,
    kill = 62,
    uname = 63,
    getppid = 110,
    getuid = 102,
    geteuid = 107,
    getgid = 104,
    getegid = 108,
    gettid = 186,
    time = 201,
    futex = 202,
    set_tid_address = 218,
    clock_gettime = 228,
    clock_getres = 229,
    clock_nanosleep = 230,
    exit_group = 231,
    openat = 257,
    mkdirat = 258,
    mknodat = 259,
    fchownat = 260,
    newfstatat = 262,
    unlinkat = 263,
    renameat = 264,
    linkat = 265,
    symlinkat = 266,
    readlinkat = 267,
    fchmodat = 268,
    faccessat = 269,
    pselect6 = 270,
    ppoll = 271,
    set_robust_list = 273,
    get_robust_list = 274,
    _,
};

/// System call error codes
pub const Error = error{
    EPERM,      // Operation not permitted
    ENOENT,     // No such file or directory
    ESRCH,      // No such process
    EINTR,      // Interrupted system call
    EIO,        // I/O error
    ENXIO,      // No such device or address
    E2BIG,      // Argument list too long
    ENOEXEC,    // Exec format error
    EBADF,      // Bad file number
    ECHILD,     // No child processes
    EAGAIN,     // Try again
    ENOMEM,     // Out of memory
    EACCES,     // Permission denied
    EFAULT,     // Bad address
    EBUSY,      // Device or resource busy
    EEXIST,     // File exists
    ENODEV,     // No such device
    ENOTDIR,    // Not a directory
    EISDIR,     // Is a directory
    EINVAL,     // Invalid argument
    ENFILE,     // File table overflow
    EMFILE,     // Too many open files
    ENOTTY,     // Not a typewriter
    EFBIG,      // File too large
    ENOSPC,     // No space left on device
    ESPIPE,     // Illegal seek
    EROFS,      // Read-only file system
    EMLINK,     // Too many links
    EPIPE,      // Broken pipe
    ENOSYS,     // Function not implemented
};

/// Convert error to errno
fn errorToErrno(err: Error) i64 {
    return switch (err) {
        error.EPERM => -1,
        error.ENOENT => -2,
        error.ESRCH => -3,
        error.EINTR => -4,
        error.EIO => -5,
        error.ENXIO => -6,
        error.E2BIG => -7,
        error.ENOEXEC => -8,
        error.EBADF => -9,
        error.ECHILD => -10,
        error.EAGAIN => -11,
        error.ENOMEM => -12,
        error.EACCES => -13,
        error.EFAULT => -14,
        error.EBUSY => -16,
        error.EEXIST => -17,
        error.ENODEV => -19,
        error.ENOTDIR => -20,
        error.EISDIR => -21,
        error.EINVAL => -22,
        error.ENFILE => -23,
        error.EMFILE => -24,
        error.ENOTTY => -25,
        error.EFBIG => -27,
        error.ENOSPC => -28,
        error.ESPIPE => -29,
        error.EROFS => -30,
        error.EMLINK => -31,
        error.EPIPE => -32,
        error.ENOSYS => -38,
    };
}

/// System call frame from interrupt
pub const SyscallFrame = extern struct {
    // Saved by interrupt handler
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,   // System call number
    rcx: u64,   // Return address
    rdx: u64,   // Arg 3
    rsi: u64,   // Arg 2
    rdi: u64,   // Arg 1
    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// System call handler table
var syscall_table: [512]SyscallHandler = undefined;

/// System call handler function type
const SyscallHandler = *const fn (*SyscallFrame) i64;

/// Initialize system call interface
pub fn init() !void {
    console.writeString("Initializing system call interface...\n");
    
    // Initialize syscall table with default handler
    for (&syscall_table) |*handler| {
        handler.* = &sysUnimplemented;
    }
    
    // Register implemented system calls
    syscall_table[@intFromEnum(SysCall.read)] = &sysRead;
    syscall_table[@intFromEnum(SysCall.write)] = &sysWrite;
    syscall_table[@intFromEnum(SysCall.open)] = &sysOpen;
    syscall_table[@intFromEnum(SysCall.close)] = &sysClose;
    syscall_table[@intFromEnum(SysCall.fork)] = &sysFork;
    syscall_table[@intFromEnum(SysCall.execve)] = &sysExecve;
    syscall_table[@intFromEnum(SysCall.exit)] = &sysExit;
    syscall_table[@intFromEnum(SysCall.getpid)] = &sysGetpid;
    syscall_table[@intFromEnum(SysCall.getppid)] = &sysGetppid;
    syscall_table[@intFromEnum(SysCall.brk)] = &sysBrk;
    syscall_table[@intFromEnum(SysCall.mmap)] = &sysMmap;
    syscall_table[@intFromEnum(SysCall.munmap)] = &sysMunmap;
    syscall_table[@intFromEnum(SysCall.clock_gettime)] = &sysClockGettime;
    syscall_table[@intFromEnum(SysCall.nanosleep)] = &sysNanosleep;
    
    // Set up SYSCALL/SYSRET
    setupSyscallMSRs();
    
    console.writeString("System call interface initialized\n");
}

/// Main system call dispatcher
export fn syscallHandler(frame: *SyscallFrame) callconv(.C) void {
    const syscall_num = frame.rax;
    
    if (syscall_num >= syscall_table.len) {
        frame.rax = @bitCast(errorToErrno(error.ENOSYS));
        return;
    }
    
    const handler = syscall_table[syscall_num];
    const result = handler(frame);
    
    // Set return value
    frame.rax = @bitCast(result);
}

// System call implementations

fn sysRead(frame: *SyscallFrame) i64 {
    const fd = @as(i32, @intCast(frame.rdi));
    const buf = @as([*]u8, @ptrFromInt(frame.rsi));
    const count = frame.rdx;
    
    _ = fd;
    _ = buf;
    _ = count;
    
    // TODO: Implement file reading
    return errorToErrno(error.ENOSYS);
}

fn sysWrite(frame: *SyscallFrame) i64 {
    const fd = @as(i32, @intCast(frame.rdi));
    const buf = @as([*]const u8, @ptrFromInt(frame.rsi));
    const count = frame.rdx;
    
    // Simple console output for stdout/stderr
    if (fd == 1 or fd == 2) {
        for (0..count) |i| {
            console.writeChar(buf[i]);
        }
        return @intCast(count);
    }
    
    // TODO: Implement file writing
    return errorToErrno(error.EBADF);
}

fn sysOpen(frame: *SyscallFrame) i64 {
    const pathname = @as([*:0]const u8, @ptrFromInt(frame.rdi));
    const flags = @as(i32, @intCast(frame.rsi));
    const mode = @as(u32, @intCast(frame.rdx));
    
    _ = pathname;
    _ = flags;
    _ = mode;
    
    // TODO: Implement file opening
    return errorToErrno(error.ENOSYS);
}

fn sysClose(frame: *SyscallFrame) i64 {
    const fd = @as(i32, @intCast(frame.rdi));
    
    _ = fd;
    
    // TODO: Implement file closing
    return errorToErrno(error.ENOSYS);
}

fn sysFork(frame: *SyscallFrame) i64 {
    _ = frame;
    
    const child_pid = process.fork() catch |err| {
        return switch (err) {
            error.OutOfMemory => errorToErrno(error.ENOMEM),
            else => errorToErrno(error.EAGAIN),
        };
    };
    
    return @intCast(child_pid);
}

fn sysExecve(frame: *SyscallFrame) i64 {
    const pathname = @as([*:0]const u8, @ptrFromInt(frame.rdi));
    const argv = @as([*]const [*:0]const u8, @ptrFromInt(frame.rsi));
    const envp = @as([*]const [*:0]const u8, @ptrFromInt(frame.rdx));
    
    _ = pathname;
    _ = argv;
    _ = envp;
    
    // TODO: Implement program execution
    return errorToErrno(error.ENOSYS);
}

fn sysExit(frame: *SyscallFrame) i64 {
    const status = @as(i32, @intCast(frame.rdi));
    
    if (process.getCurrentProcess()) |proc| {
        proc.exit(status);
    }
    
    // Should not return
    return 0;
}

fn sysGetpid(frame: *SyscallFrame) i64 {
    _ = frame;
    
    if (process.getCurrentProcess()) |proc| {
        return @intCast(proc.pid);
    }
    
    return 0;
}

fn sysGetppid(frame: *SyscallFrame) i64 {
    _ = frame;
    
    if (process.getCurrentProcess()) |proc| {
        return @intCast(proc.ppid);
    }
    
    return 0;
}

fn sysBrk(frame: *SyscallFrame) i64 {
    const new_brk = frame.rdi;
    
    const proc = process.getCurrentProcess() orelse return 0;
    const mm = proc.mm orelse return 0;
    
    if (new_brk == 0) {
        // Return current brk
        return @bitCast(mm.brk);
    }
    
    // TODO: Validate and update brk
    if (new_brk >= mm.start_brk and new_brk < USER_HEAP_MAX) {
        mm.brk = new_brk;
        return @bitCast(new_brk);
    }
    
    return @bitCast(mm.brk);
}

fn sysMmap(frame: *SyscallFrame) i64 {
    const addr = frame.rdi;
    const length = frame.rsi;
    const prot = @as(i32, @intCast(frame.rdx));
    const flags = @as(i32, @intCast(frame.r10));
    const fd = @as(i32, @intCast(frame.r8));
    const offset = frame.r9;
    
    _ = addr;
    _ = length;
    _ = prot;
    _ = flags;
    _ = fd;
    _ = offset;
    
    // TODO: Implement memory mapping
    return errorToErrno(error.ENOMEM);
}

fn sysMunmap(frame: *SyscallFrame) i64 {
    const addr = frame.rdi;
    const length = frame.rsi;
    
    _ = addr;
    _ = length;
    
    // TODO: Implement memory unmapping
    return errorToErrno(error.ENOSYS);
}

fn sysClockGettime(frame: *SyscallFrame) i64 {
    const clockid = @as(i32, @intCast(frame.rdi));
    const timespec_ptr = @as(?*timer.Timespec, @ptrFromInt(frame.rsi));
    
    if (timespec_ptr == null) {
        return errorToErrno(error.EFAULT);
    }
    
    const ts = switch (clockid) {
        0 => timer.getCurrentTime(),      // CLOCK_REALTIME
        1 => timer.getUptime(),          // CLOCK_MONOTONIC
        else => return errorToErrno(error.EINVAL),
    };
    
    timespec_ptr.?.* = ts;
    return 0;
}

fn sysNanosleep(frame: *SyscallFrame) i64 {
    const req = @as(?*const timer.Timespec, @ptrFromInt(frame.rdi));
    const rem = @as(?*timer.Timespec, @ptrFromInt(frame.rsi));
    
    _ = rem; // TODO: Handle remaining time on interrupt
    
    if (req == null) {
        return errorToErrno(error.EFAULT);
    }
    
    const sleep_ns = req.?.toNsec();
    timer.sleepNsec(sleep_ns);
    
    return 0;
}

fn sysUnimplemented(frame: *SyscallFrame) i64 {
    const syscall_num = frame.rax;
    console.printf("Unimplemented syscall: {}\n", .{syscall_num});
    return errorToErrno(error.ENOSYS);
}

// Constants
const USER_HEAP_MAX: u64 = 0x0000_7000_0000_0000;

// System call entry setup
fn setupSyscallMSRs() void {
    // Set up SYSCALL/SYSRET MSRs
    const STAR_MSR: u32 = 0xC0000081;
    const LSTAR_MSR: u32 = 0xC0000082;
    const SFMASK_MSR: u32 = 0xC0000084;
    
    // STAR: Kernel CS = 0x08, SS = 0x10, User CS = 0x18, SS = 0x20
    const star_value: u64 = (0x08 << 32) | (0x18 << 48);
    writeMSR(STAR_MSR, star_value);
    
    // LSTAR: System call entry point
    writeMSR(LSTAR_MSR, @intFromPtr(&syscallEntry));
    
    // SFMASK: Clear interrupts on syscall
    writeMSR(SFMASK_MSR, 0x200); // Clear IF
}

// Assembly syscall entry point
export fn syscallEntry() callconv(.Naked) void {
    asm volatile (
        \\swapgs              # Switch to kernel GS
        \\movq %rsp, %gs:8    # Save user RSP
        \\movq %gs:0, %rsp    # Load kernel RSP
        \\
        \\pushq %ss           # User SS
        \\pushq %gs:8         # User RSP
        \\pushq %r11          # User RFLAGS
        \\pushq %cs           # User CS
        \\pushq %rcx          # User RIP
        \\
        \\pushq %rdi
        \\pushq %rsi
        \\pushq %rdx
        \\pushq %rcx
        \\pushq %rax
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\pushq %rbx
        \\pushq %rbp
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\
        \\movq %rsp, %rdi     # Frame pointer
        \\call syscallHandler
        \\
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %rbp
        \\popq %rbx
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rax           # Return value
        \\popq %rcx
        \\popq %rdx
        \\popq %rsi
        \\popq %rdi
        \\
        \\popq %rcx           # User RIP
        \\addq $8, %rsp       # Skip CS
        \\popq %r11           # User RFLAGS
        \\popq %rsp           # User RSP
        \\
        \\swapgs              # Switch back to user GS
        \\sysretq
    );
}

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