//! Virtual File System (VFS) layer for Ghost Kernel
//! Pure Zig implementation providing a unified interface for all filesystems

const std = @import("std");
const memory = @import("../mm/memory.zig");
const process = @import("../kernel/process.zig");

/// File types
pub const FileType = enum(u8) {
    regular = 0,
    directory = 1,
    character_device = 2,
    block_device = 3,
    fifo = 4,
    socket = 5,
    symlink = 6,
};

/// File permissions
pub const FileMode = packed struct(u16) {
    other_execute: bool = false,
    other_write: bool = false,
    other_read: bool = false,
    group_execute: bool = false,
    group_write: bool = false,
    group_read: bool = false,
    user_execute: bool = false,
    user_write: bool = false,
    user_read: bool = false,
    sticky: bool = false,
    setgid: bool = false,
    setuid: bool = false,
    file_type: FileType = .regular,
    _reserved: u1 = 0,
};

/// Open file flags
pub const OpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    append: bool = false,
    nonblock: bool = false,
    directory: bool = false,
    nofollow: bool = false,
    cloexec: bool = false,
    sync: bool = false,
    _reserved: u21 = 0,
};

/// Seek whence values
pub const SeekWhence = enum(u8) {
    set = 0,    // SEEK_SET
    current = 1, // SEEK_CUR
    end = 2,    // SEEK_END
};

/// File statistics
pub const FileStat = struct {
    device_id: u64,          // Device ID
    inode: u64,              // Inode number
    mode: FileMode,          // File mode and permissions
    hard_links: u32,         // Number of hard links
    user_id: u32,            // User ID
    group_id: u32,           // Group ID
    rdev: u64,               // Device ID (if special file)
    size: u64,               // File size in bytes
    block_size: u32,         // Block size for filesystem I/O
    blocks: u64,             // Number of 512B blocks allocated
    access_time: u64,        // Last access time (nanoseconds since epoch)
    modify_time: u64,        // Last modification time
    change_time: u64,        // Last status change time
};

/// Directory entry
pub const DirEntry = struct {
    inode: u64,              // Inode number
    offset: u64,             // Offset to next record
    record_length: u16,      // Length of this record
    name_length: u8,         // Length of name
    file_type: FileType,     // File type
    name: []const u8,        // File name (null-terminated)
};

/// VFS errors
pub const VFSError = error{
    FileNotFound,
    PermissionDenied,
    IsDirectory,
    NotDirectory,
    FileExists,
    InvalidPath,
    TooManySymlinks,
    NameTooLong,
    NoSpace,
    ReadOnlyFilesystem,
    FileTooLarge,
    InvalidArgument,
    NotSupported,
    Busy,
    CrossDeviceLink,
    DirectoryNotEmpty,
    InvalidFileDescriptor,
    OutOfMemory,
    IOError,
};

/// Inode operations interface
pub const InodeOps = struct {
    lookup: ?*const fn (inode: *Inode, name: []const u8) VFSError!?*Inode = null,
    create: ?*const fn (inode: *Inode, name: []const u8, mode: FileMode) VFSError!*Inode = null,
    link: ?*const fn (old_inode: *Inode, dir: *Inode, name: []const u8) VFSError!void = null,
    unlink: ?*const fn (dir: *Inode, name: []const u8) VFSError!void = null,
    symlink: ?*const fn (dir: *Inode, name: []const u8, target: []const u8) VFSError!*Inode = null,
    mkdir: ?*const fn (dir: *Inode, name: []const u8, mode: FileMode) VFSError!*Inode = null,
    rmdir: ?*const fn (dir: *Inode, name: []const u8) VFSError!void = null,
    rename: ?*const fn (old_dir: *Inode, old_name: []const u8, new_dir: *Inode, new_name: []const u8) VFSError!void = null,
    readlink: ?*const fn (inode: *Inode, buffer: []u8) VFSError!usize = null,
    permission: ?*const fn (inode: *Inode, mask: u32) VFSError!void = null,
};

/// File operations interface
pub const FileOps = struct {
    read: ?*const fn (file: *File, buffer: []u8, offset: u64) VFSError!usize = null,
    write: ?*const fn (file: *File, buffer: []const u8, offset: u64) VFSError!usize = null,
    seek: ?*const fn (file: *File, offset: i64, whence: SeekWhence) VFSError!u64 = null,
    flush: ?*const fn (file: *File) VFSError!void = null,
    fsync: ?*const fn (file: *File) VFSError!void = null,
    readdir: ?*const fn (file: *File, buffer: []u8, offset: u64) VFSError!usize = null,
    poll: ?*const fn (file: *File, mask: u32) VFSError!u32 = null,
    ioctl: ?*const fn (file: *File, cmd: u32, arg: usize) VFSError!usize = null,
    mmap: ?*const fn (file: *File, length: usize, prot: u32, flags: u32, offset: u64) VFSError!?*anyopaque = null,
};

/// Superblock operations
pub const SuperOps = struct {
    alloc_inode: ?*const fn (sb: *SuperBlock) VFSError!*Inode = null,
    destroy_inode: ?*const fn (inode: *Inode) void = null,
    read_inode: ?*const fn (inode: *Inode) VFSError!void = null,
    write_inode: ?*const fn (inode: *Inode) VFSError!void = null,
    put_super: ?*const fn (sb: *SuperBlock) void = null,
    sync_fs: ?*const fn (sb: *SuperBlock) VFSError!void = null,
    statfs: ?*const fn (sb: *SuperBlock, stat: *FilesystemStat) VFSError!void = null,
};

/// Inode structure
pub const Inode = struct {
    number: u64,             // Inode number
    mode: FileMode,          // File mode and permissions
    user_id: u32,            // User ID
    group_id: u32,           // Group ID
    size: u64,               // File size
    blocks: u64,             // Number of blocks
    access_time: u64,        // Last access time
    modify_time: u64,        // Last modification time
    change_time: u64,        // Last status change time
    link_count: u32,         // Hard link count
    superblock: *SuperBlock, // Pointer to superblock
    ops: *const InodeOps,    // Inode operations
    private_data: ?*anyopaque = null, // Filesystem-specific data
    ref_count: std.atomic.Value(u32), // Reference count
    
    const Self = @This();
    
    pub fn init(sb: *SuperBlock, number: u64, ops: *const InodeOps) Self {
        return Self{
            .number = number,
            .mode = FileMode{},
            .user_id = 0,
            .group_id = 0,
            .size = 0,
            .blocks = 0,
            .access_time = 0,
            .modify_time = 0,
            .change_time = 0,
            .link_count = 1,
            .superblock = sb,
            .ops = ops,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            if (self.superblock.ops.destroy_inode) |destroy| {
                destroy(self);
            }
        }
    }
    
    pub fn lookup(self: *Self, name: []const u8) VFSError!?*Inode {
        if (self.ops.lookup) |lookup_fn| {
            return lookup_fn(self, name);
        }
        return VFSError.NotSupported;
    }
    
    pub fn create(self: *Self, name: []const u8, mode: FileMode) VFSError!*Inode {
        if (self.ops.create) |create_fn| {
            return create_fn(self, name, mode);
        }
        return VFSError.NotSupported;
    }
    
    pub fn unlink(self: *Self, name: []const u8) VFSError!void {
        if (self.ops.unlink) |unlink_fn| {
            return unlink_fn(self, name);
        }
        return VFSError.NotSupported;
    }
    
    pub fn mkdir(self: *Self, name: []const u8, mode: FileMode) VFSError!*Inode {
        if (self.ops.mkdir) |mkdir_fn| {
            return mkdir_fn(self, name, mode);
        }
        return VFSError.NotSupported;
    }
};

/// File structure
pub const File = struct {
    inode: *Inode,           // Associated inode
    flags: OpenFlags,        // Open flags
    position: u64,           // Current file position
    ops: *const FileOps,     // File operations
    private_data: ?*anyopaque = null, // Filesystem-specific data
    ref_count: std.atomic.Value(u32), // Reference count
    
    const Self = @This();
    
    pub fn init(inode: *Inode, flags: OpenFlags, ops: *const FileOps) Self {
        return Self{
            .inode = inode.get(),
            .flags = flags,
            .position = 0,
            .ops = ops,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    
    pub fn get(self: *Self) *Self {
        _ = self.ref_count.fetchAdd(1, .acquire);
        return self;
    }
    
    pub fn put(self: *Self) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            self.inode.put();
        }
    }
    
    pub fn read(self: *Self, buffer: []u8) VFSError!usize {
        if (self.ops.read) |read_fn| {
            const bytes_read = try read_fn(self, buffer, self.position);
            self.position += bytes_read;
            return bytes_read;
        }
        return VFSError.NotSupported;
    }
    
    pub fn write(self: *Self, buffer: []const u8) VFSError!usize {
        if (self.ops.write) |write_fn| {
            const bytes_written = try write_fn(self, buffer, self.position);
            self.position += bytes_written;
            return bytes_written;
        }
        return VFSError.NotSupported;
    }
    
    pub fn seek(self: *Self, offset: i64, whence: SeekWhence) VFSError!u64 {
        if (self.ops.seek) |seek_fn| {
            self.position = try seek_fn(self, offset, whence);
            return self.position;
        }
        
        // Default seek implementation
        const new_pos: i64 = switch (whence) {
            .set => offset,
            .current => @as(i64, @intCast(self.position)) + offset,
            .end => @as(i64, @intCast(self.inode.size)) + offset,
        };
        
        if (new_pos < 0) return VFSError.InvalidArgument;
        self.position = @intCast(new_pos);
        return self.position;
    }
    
    pub fn readdir(self: *Self, buffer: []u8) VFSError!usize {
        if (self.ops.readdir) |readdir_fn| {
            return readdir_fn(self, buffer, self.position);
        }
        return VFSError.NotSupported;
    }
};

/// Superblock structure
pub const SuperBlock = struct {
    block_size: u32,         // Block size
    total_blocks: u64,       // Total blocks
    free_blocks: u64,        // Free blocks
    total_inodes: u64,       // Total inodes
    free_inodes: u64,        // Free inodes
    root: ?*Inode,           // Root inode
    ops: *const SuperOps,    // Superblock operations
    private_data: ?*anyopaque = null, // Filesystem-specific data
    flags: u32 = 0,          // Mount flags
    
    pub fn statfs(self: *SuperBlock, stat: *FilesystemStat) VFSError!void {
        if (self.ops.statfs) |statfs_fn| {
            return statfs_fn(self, stat);
        }
        
        // Default implementation
        stat.* = FilesystemStat{
            .type = 0,
            .block_size = self.block_size,
            .total_blocks = self.total_blocks,
            .free_blocks = self.free_blocks,
            .available_blocks = self.free_blocks,
            .total_inodes = self.total_inodes,
            .free_inodes = self.free_inodes,
            .filesystem_id = 0,
            .max_filename_length = 255,
        };
    }
};

/// Filesystem statistics
pub const FilesystemStat = struct {
    type: u64,               // Filesystem type
    block_size: u32,         // Block size
    total_blocks: u64,       // Total blocks
    free_blocks: u64,        // Free blocks
    available_blocks: u64,   // Available blocks
    total_inodes: u64,       // Total inodes
    free_inodes: u64,        // Free inodes
    filesystem_id: u64,      // Filesystem ID
    max_filename_length: u32, // Maximum filename length
};

/// Filesystem type
pub const FilesystemType = struct {
    name: []const u8,
    mount: *const fn (dev_name: []const u8, mount_point: []const u8, flags: u32, data: ?[]const u8) VFSError!*SuperBlock,
    kill_sb: *const fn (sb: *SuperBlock) void,
};

/// Mount point
pub const Mount = struct {
    superblock: *SuperBlock,
    mount_point: []const u8,
    filesystem_type: *const FilesystemType,
    flags: u32,
    next: ?*Mount = null,
};

/// Path lookup cache entry
pub const DentryCache = struct {
    const CacheEntry = struct {
        path: []const u8,
        inode: *Inode,
        timestamp: u64,
    };
    
    entries: std.HashMap(u64, CacheEntry),
    allocator: std.mem.Allocator,
    max_entries: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, max_entries: u32) Self {
        return Self{
            .entries = std.HashMap(u64, CacheEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.inode.put();
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit();
    }
    
    pub fn lookup(self: *Self, path: []const u8) ?*Inode {
        const hash = std.hash_map.hashString(path);
        if (self.entries.get(hash)) |entry| {
            return entry.inode.get();
        }
        return null;
    }
    
    pub fn insert(self: *Self, path: []const u8, inode: *Inode) !void {
        if (self.entries.count() >= self.max_entries) {
            // Evict oldest entry
            try self.evictOldest();
        }
        
        const hash = std.hash_map.hashString(path);
        const path_copy = try self.allocator.dupe(u8, path);
        
        try self.entries.put(hash, CacheEntry{
            .path = path_copy,
            .inode = inode.get(),
            .timestamp = std.time.nanoTimestamp(),
        });
    }
    
    fn evictOldest(self: *Self) !void {
        var oldest_hash: u64 = 0;
        var oldest_time: u64 = std.math.maxInt(u64);
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_time) {
                oldest_time = entry.value_ptr.timestamp;
                oldest_hash = entry.key_ptr.*;
            }
        }
        
        if (self.entries.fetchRemove(oldest_hash)) |removed| {
            removed.value.inode.put();
            self.allocator.free(removed.value.path);
        }
    }
};

/// Virtual File System
pub const VFS = struct {
    allocator: std.mem.Allocator,
    root_mount: ?*Mount,
    mounts: ?*Mount,
    dentry_cache: DentryCache,
    filesystem_types: std.ArrayList(*const FilesystemType),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .root_mount = null,
            .mounts = null,
            .dentry_cache = DentryCache.init(allocator, 1024),
            .filesystem_types = std.ArrayList(*const FilesystemType).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.dentry_cache.deinit();
        self.filesystem_types.deinit();
        
        // Clean up mounts
        var mount = self.mounts;
        while (mount) |m| {
            const next = m.next;
            self.allocator.destroy(m);
            mount = next;
        }
    }
    
    pub fn registerFilesystem(self: *Self, fs_type: *const FilesystemType) !void {
        try self.filesystem_types.append(fs_type);
    }
    
    pub fn mount(self: *Self, fs_type_name: []const u8, dev_name: []const u8, mount_point: []const u8, flags: u32, data: ?[]const u8) !void {
        // Find filesystem type
        var fs_type: ?*const FilesystemType = null;
        for (self.filesystem_types.items) |ft| {
            if (std.mem.eql(u8, ft.name, fs_type_name)) {
                fs_type = ft;
                break;
            }
        }
        
        if (fs_type == null) {
            return VFSError.NotSupported;
        }
        
        // Create mount point
        const superblock = try fs_type.?.mount(dev_name, mount_point, flags, data);
        
        const new_mount = try self.allocator.create(Mount);
        new_mount.* = Mount{
            .superblock = superblock,
            .mount_point = try self.allocator.dupe(u8, mount_point),
            .filesystem_type = fs_type.?,
            .flags = flags,
            .next = self.mounts,
        };
        
        self.mounts = new_mount;
        
        // Set as root if first mount
        if (self.root_mount == null and std.mem.eql(u8, mount_point, "/")) {
            self.root_mount = new_mount;
        }
    }
    
    pub fn open(self: *Self, path: []const u8, flags: OpenFlags) VFSError!*File {
        // Look up inode
        const inode = try self.pathLookup(path);
        
        // Check permissions
        // TODO: Implement permission checking
        
        // Create file object
        const file = try self.allocator.create(File);
        // TODO: Get file operations from filesystem
        const file_ops = &FileOps{}; // Placeholder
        file.* = File.init(inode, flags, file_ops);
        
        return file;
    }
    
    pub fn stat(self: *Self, path: []const u8) VFSError!FileStat {
        const inode = try self.pathLookup(path);
        defer inode.put();
        
        return FileStat{
            .device_id = 0, // TODO: Get device ID
            .inode = inode.number,
            .mode = inode.mode,
            .hard_links = inode.link_count,
            .user_id = inode.user_id,
            .group_id = inode.group_id,
            .rdev = 0,
            .size = inode.size,
            .block_size = inode.superblock.block_size,
            .blocks = inode.blocks,
            .access_time = inode.access_time,
            .modify_time = inode.modify_time,
            .change_time = inode.change_time,
        };
    }
    
    pub fn pathLookup(self: *Self, path: []const u8) VFSError!*Inode {
        // Check cache first
        if (self.dentry_cache.lookup(path)) |cached_inode| {
            return cached_inode;
        }
        
        // Validate path
        if (path.len == 0 or path[0] != '/') {
            return VFSError.InvalidPath;
        }
        
        // Start from root
        if (self.root_mount == null or self.root_mount.?.superblock.root == null) {
            return VFSError.FileNotFound;
        }
        
        var current_inode = self.root_mount.?.superblock.root.?.get();
        
        // Handle root path
        if (path.len == 1) {
            try self.dentry_cache.insert(path, current_inode);
            return current_inode;
        }
        
        // Split path and traverse
        var path_iter = std.mem.split(u8, path[1..], "/");
        while (path_iter.next()) |component| {
            if (component.len == 0) continue;
            
            // Look up component in current directory
            const next_inode = try current_inode.lookup(component) orelse {
                current_inode.put();
                return VFSError.FileNotFound;
            };
            
            current_inode.put();
            current_inode = next_inode;
        }
        
        // Cache the result
        try self.dentry_cache.insert(path, current_inode);
        return current_inode;
    }
    
    pub fn create(self: *Self, path: []const u8, mode: FileMode) VFSError!*Inode {
        // Split path into directory and filename
        const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return VFSError.InvalidPath;
        const dir_path = path[0..last_slash];
        const filename = path[last_slash + 1 ..];
        
        if (filename.len == 0) {
            return VFSError.InvalidPath;
        }
        
        // Look up parent directory
        const parent_dir = if (dir_path.len == 0) 
            try self.pathLookup("/")
        else
            try self.pathLookup(dir_path);
        defer parent_dir.put();
        
        // Create file in parent directory
        return parent_dir.create(filename, mode);
    }
    
    pub fn unlink(self: *Self, path: []const u8) VFSError!void {
        // Split path into directory and filename
        const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return VFSError.InvalidPath;
        const dir_path = path[0..last_slash];
        const filename = path[last_slash + 1 ..];
        
        if (filename.len == 0) {
            return VFSError.InvalidPath;
        }
        
        // Look up parent directory
        const parent_dir = if (dir_path.len == 0) 
            try self.pathLookup("/")
        else
            try self.pathLookup(dir_path);
        defer parent_dir.put();
        
        // Remove file from parent directory
        try parent_dir.unlink(filename);
    }
    
    pub fn mkdir(self: *Self, path: []const u8, mode: FileMode) VFSError!void {
        // Split path into directory and filename
        const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return VFSError.InvalidPath;
        const dir_path = path[0..last_slash];
        const dirname = path[last_slash + 1 ..];
        
        if (dirname.len == 0) {
            return VFSError.InvalidPath;
        }
        
        // Look up parent directory
        const parent_dir = if (dir_path.len == 0) 
            try self.pathLookup("/")
        else
            try self.pathLookup(dir_path);
        defer parent_dir.put();
        
        // Create directory in parent
        const new_dir = try parent_dir.mkdir(dirname, mode);
        new_dir.put();
    }
};

// Global VFS instance
var global_vfs: ?*VFS = null;

/// Initialize the VFS subsystem
pub fn initVFS(allocator: std.mem.Allocator) !void {
    const vfs = try allocator.create(VFS);
    vfs.* = VFS.init(allocator);
    global_vfs = vfs;
}

/// Get the global VFS instance
pub fn getVFS() *VFS {
    return global_vfs orelse @panic("VFS not initialized");
}

// Tests
test "VFS initialization" {
    const allocator = std.testing.allocator;
    
    var vfs = VFS.init(allocator);
    defer vfs.deinit();
    
    try std.testing.expect(vfs.root_mount == null);
    try std.testing.expect(vfs.mounts == null);
}

test "path validation" {
    const allocator = std.testing.allocator;
    
    var vfs = VFS.init(allocator);
    defer vfs.deinit();
    
    // Invalid paths should return error
    const result = vfs.pathLookup("invalid/path");
    try std.testing.expectError(VFSError.InvalidPath, result);
}

test "file mode operations" {
    var mode = FileMode{
        .user_read = true,
        .user_write = true,
        .user_execute = false,
        .file_type = .regular,
    };
    
    try std.testing.expect(mode.user_read);
    try std.testing.expect(mode.user_write);
    try std.testing.expect(!mode.user_execute);
    try std.testing.expect(mode.file_type == .regular);
}

test "inode reference counting" {
    const allocator = std.testing.allocator;
    
    var sb = SuperBlock{
        .block_size = 4096,
        .total_blocks = 1000,
        .free_blocks = 900,
        .total_inodes = 1000,
        .free_inodes = 900,
        .root = null,
        .ops = &SuperOps{},
    };
    
    var inode = Inode.init(&sb, 1, &InodeOps{});
    
    try std.testing.expect(inode.ref_count.load(.acquire) == 1);
    
    const inode2 = inode.get();
    try std.testing.expect(inode.ref_count.load(.acquire) == 2);
    try std.testing.expect(inode2 == &inode);
    
    inode2.put();
    try std.testing.expect(inode.ref_count.load(.acquire) == 1);
}