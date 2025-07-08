//! RAM filesystem (ramfs) implementation for Ghost Kernel
//! Simple in-memory filesystem for initial testing and temporary storage

const std = @import("std");
const vfs = @import("vfs.zig");
const memory = @import("../mm/memory.zig");

/// RamFS inode data
const RamFSInodeData = struct {
    allocator: std.mem.Allocator,
    data: ?[]u8 = null,
    children: ?std.StringHashMap(*vfs.Inode) = null,
    parent: ?*vfs.Inode = null,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, is_directory: bool) !*Self {
        const data = try allocator.create(Self);
        data.* = Self{
            .allocator = allocator,
            .children = if (is_directory) std.StringHashMap(*vfs.Inode).init(allocator) else null,
        };
        return data;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.data) |d| {
            self.allocator.free(d);
        }
        if (self.children) |*c| {
            var iter = c.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.put();
            }
            c.deinit();
        }
        self.allocator.destroy(self);
    }
};

/// RamFS specific operations
var ramfs_inode_ops = vfs.InodeOps{
    .lookup = ramfsLookup,
    .create = ramfsCreate,
    .unlink = ramfsUnlink,
    .mkdir = ramfsMkdir,
    .rmdir = ramfsRmdir,
};

var ramfs_file_ops = vfs.FileOps{
    .read = ramfsRead,
    .write = ramfsWrite,
    .seek = ramfsSeek,
    .readdir = ramfsReaddir,
};

var ramfs_super_ops = vfs.SuperOps{
    .alloc_inode = ramfsAllocInode,
    .destroy_inode = ramfsDestroyInode,
};

/// RamFS filesystem type
pub const ramfs_type = vfs.FilesystemType{
    .name = "ramfs",
    .mount = ramfsMount,
    .kill_sb = ramfsKillSb,
};

/// Mount ramfs
fn ramfsMount(dev_name: []const u8, mount_point: []const u8, flags: u32, data: ?[]const u8) vfs.VFSError!*vfs.SuperBlock {
    _ = dev_name;
    _ = mount_point;
    _ = flags;
    _ = data;
    
    const allocator = memory.kernel_allocator;
    
    // Create superblock
    const sb = try allocator.create(vfs.SuperBlock);
    sb.* = vfs.SuperBlock{
        .block_size = 4096,
        .total_blocks = 0,
        .free_blocks = 0,
        .total_inodes = 0,
        .free_inodes = 0,
        .root = null,
        .ops = &ramfs_super_ops,
        .private_data = null,
        .flags = flags,
    };
    
    // Create root inode
    const root_inode = try ramfsAllocInode(sb);
    root_inode.mode = vfs.FileMode{
        .file_type = .directory,
        .user_read = true,
        .user_write = true,
        .user_execute = true,
        .group_read = true,
        .group_execute = true,
        .other_read = true,
        .other_execute = true,
    };
    root_inode.number = 1;
    sb.root = root_inode;
    
    return sb;
}

/// Kill ramfs superblock
fn ramfsKillSb(sb: *vfs.SuperBlock) void {
    const allocator = memory.kernel_allocator;
    if (sb.root) |root| {
        root.put();
    }
    allocator.destroy(sb);
}

/// Allocate ramfs inode
fn ramfsAllocInode(sb: *vfs.SuperBlock) vfs.VFSError!*vfs.Inode {
    const allocator = memory.kernel_allocator;
    
    const inode = try allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(sb, 0, &ramfs_inode_ops);
    
    // Allocate private data
    const private_data = RamFSInodeData.init(allocator, false) catch return vfs.VFSError.OutOfMemory;
    inode.private_data = @ptrCast(private_data);
    
    return inode;
}

/// Destroy ramfs inode
fn ramfsDestroyInode(inode: *vfs.Inode) void {
    const allocator = memory.kernel_allocator;
    
    if (inode.private_data) |pd| {
        const data = @as(*RamFSInodeData, @ptrCast(@alignCast(pd)));
        data.deinit();
    }
    
    allocator.destroy(inode);
}

/// Lookup file in directory
fn ramfsLookup(dir: *vfs.Inode, name: []const u8) vfs.VFSError!?*vfs.Inode {
    if (dir.mode.file_type != .directory) {
        return vfs.VFSError.NotDirectory;
    }
    
    const data = @as(*RamFSInodeData, @ptrCast(@alignCast(dir.private_data.?)));
    if (data.children) |*children| {
        if (children.get(name)) |inode| {
            return inode.get();
        }
    }
    
    return null;
}

/// Create file in directory
fn ramfsCreate(dir: *vfs.Inode, name: []const u8, mode: vfs.FileMode) vfs.VFSError!*vfs.Inode {
    if (dir.mode.file_type != .directory) {
        return vfs.VFSError.NotDirectory;
    }
    
    const allocator = memory.kernel_allocator;
    const dir_data = @as(*RamFSInodeData, @ptrCast(@alignCast(dir.private_data.?)));
    
    // Check if file already exists
    if (dir_data.children) |*children| {
        if (children.contains(name)) {
            return vfs.VFSError.FileExists;
        }
    }
    
    // Create new inode
    const new_inode = try ramfsAllocInode(dir.superblock);
    new_inode.mode = mode;
    new_inode.number = @intFromPtr(new_inode); // Use pointer as inode number
    
    // Set up file data
    const inode_data = @as(*RamFSInodeData, @ptrCast(@alignCast(new_inode.private_data.?)));
    inode_data.parent = dir;
    
    // Add to parent's children
    const name_copy = try allocator.dupe(u8, name);
    try dir_data.children.?.put(name_copy, new_inode);
    
    // Update directory times
    dir.modify_time = @intCast(std.time.nanoTimestamp());
    dir.change_time = dir.modify_time;
    
    return new_inode;
}

/// Remove file from directory
fn ramfsUnlink(dir: *vfs.Inode, name: []const u8) vfs.VFSError!void {
    if (dir.mode.file_type != .directory) {
        return vfs.VFSError.NotDirectory;
    }
    
    const allocator = memory.kernel_allocator;
    const dir_data = @as(*RamFSInodeData, @ptrCast(@alignCast(dir.private_data.?)));
    
    if (dir_data.children) |*children| {
        if (children.fetchRemove(name)) |entry| {
            allocator.free(entry.key);
            entry.value.put();
            
            // Update directory times
            dir.modify_time = @intCast(std.time.nanoTimestamp());
            dir.change_time = dir.modify_time;
        } else {
            return vfs.VFSError.FileNotFound;
        }
    } else {
        return vfs.VFSError.FileNotFound;
    }
}

/// Create directory
fn ramfsMkdir(parent: *vfs.Inode, name: []const u8, mode: vfs.FileMode) vfs.VFSError!*vfs.Inode {
    var dir_mode = mode;
    dir_mode.file_type = .directory;
    
    const new_dir = try ramfsCreate(parent, name, dir_mode);
    
    // Initialize as directory
    const dir_data = @as(*RamFSInodeData, @ptrCast(@alignCast(new_dir.private_data.?)));
    dir_data.deinit();
    
    const new_data = try RamFSInodeData.init(memory.kernel_allocator, true);
    new_dir.private_data = @ptrCast(new_data);
    new_data.parent = parent;
    
    return new_dir;
}

/// Remove directory
fn ramfsRmdir(parent: *vfs.Inode, name: []const u8) vfs.VFSError!void {
    const dir_data = @as(*RamFSInodeData, @ptrCast(@alignCast(parent.private_data.?)));
    
    if (dir_data.children) |*children| {
        if (children.get(name)) |child| {
            const child_data = @as(*RamFSInodeData, @ptrCast(@alignCast(child.private_data.?)));
            
            // Check if directory is empty
            if (child_data.children) |*c| {
                if (c.count() > 0) {
                    return vfs.VFSError.DirectoryNotEmpty;
                }
            }
        }
    }
    
    // Remove like a regular file
    try ramfsUnlink(parent, name);
}

/// Read from file
fn ramfsRead(file: *vfs.File, buffer: []u8, offset: u64) vfs.VFSError!usize {
    const inode = file.inode;
    const data = @as(*RamFSInodeData, @ptrCast(@alignCast(inode.private_data.?)));
    
    if (inode.mode.file_type == .directory) {
        return vfs.VFSError.IsDirectory;
    }
    
    if (data.data) |file_data| {
        if (offset >= file_data.len) {
            return 0; // EOF
        }
        
        const available = file_data.len - offset;
        const to_read = @min(buffer.len, available);
        
        @memcpy(buffer[0..to_read], file_data[offset..offset + to_read]);
        
        // Update access time
        inode.access_time = @intCast(std.time.nanoTimestamp());
        
        return to_read;
    }
    
    return 0; // Empty file
}

/// Write to file
fn ramfsWrite(file: *vfs.File, buffer: []const u8, offset: u64) vfs.VFSError!usize {
    const allocator = memory.kernel_allocator;
    const inode = file.inode;
    const data = @as(*RamFSInodeData, @ptrCast(@alignCast(inode.private_data.?)));
    
    if (inode.mode.file_type == .directory) {
        return vfs.VFSError.IsDirectory;
    }
    
    // Extend file if necessary
    const required_size = offset + buffer.len;
    
    if (data.data) |file_data| {
        if (required_size > file_data.len) {
            // Reallocate
            const new_data = try allocator.alloc(u8, required_size);
            @memcpy(new_data[0..file_data.len], file_data);
            @memset(new_data[file_data.len..offset], 0); // Zero-fill gap
            allocator.free(file_data);
            data.data = new_data;
        }
    } else {
        // Allocate new
        data.data = try allocator.alloc(u8, required_size);
        @memset(data.data.?[0..offset], 0); // Zero-fill up to offset
    }
    
    // Write data
    @memcpy(data.data.?[offset..offset + buffer.len], buffer);
    
    // Update inode metadata
    inode.size = @max(inode.size, required_size);
    inode.modify_time = @intCast(std.time.nanoTimestamp());
    inode.change_time = inode.modify_time;
    
    return buffer.len;
}

/// Seek in file
fn ramfsSeek(file: *vfs.File, offset: i64, whence: vfs.SeekWhence) vfs.VFSError!u64 {
    _ = file;
    _ = offset;
    _ = whence;
    // Default seek implementation in VFS is sufficient
    return vfs.VFSError.NotSupported;
}

/// Read directory entries
fn ramfsReaddir(file: *vfs.File, buffer: []u8, offset: u64) vfs.VFSError!usize {
    const inode = file.inode;
    const data = @as(*RamFSInodeData, @ptrCast(@alignCast(inode.private_data.?)));
    
    if (inode.mode.file_type != .directory) {
        return vfs.VFSError.NotDirectory;
    }
    
    var written: usize = 0;
    var current_offset: u64 = 0;
    
    if (data.children) |*children| {
        var iter = children.iterator();
        
        // Skip to offset
        while (current_offset < offset) : (current_offset += 1) {
            if (iter.next() == null) {
                return 0; // EOF
            }
        }
        
        // Write entries
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const child_inode = entry.value_ptr.*;
            
            const entry_size = @sizeOf(vfs.DirEntry) + name.len + 1;
            if (written + entry_size > buffer.len) {
                break; // Buffer full
            }
            
            const dir_entry = @as(*vfs.DirEntry, @ptrCast(@alignCast(&buffer[written])));
            dir_entry.* = vfs.DirEntry{
                .inode = child_inode.number,
                .offset = current_offset + 1,
                .record_length = @intCast(entry_size),
                .name_length = @intCast(name.len),
                .file_type = child_inode.mode.file_type,
                .name = undefined,
            };
            
            // Copy name
            const name_dst = buffer[written + @sizeOf(vfs.DirEntry)..];
            @memcpy(name_dst[0..name.len], name);
            name_dst[name.len] = 0; // Null terminate
            
            written += entry_size;
            current_offset += 1;
        }
    }
    
    file.position = current_offset;
    return written;
}

// Tests
test "ramfs mount and root creation" {
    const allocator = std.testing.allocator;
    memory.kernel_allocator = allocator;
    defer memory.kernel_allocator = undefined;
    
    const sb = try ramfsMount("", "/", 0, null);
    defer ramfsKillSb(sb);
    
    try std.testing.expect(sb.root != null);
    try std.testing.expect(sb.root.?.mode.file_type == .directory);
}

test "ramfs file creation and operations" {
    const allocator = std.testing.allocator;
    memory.kernel_allocator = allocator;
    defer memory.kernel_allocator = undefined;
    
    const sb = try ramfsMount("", "/", 0, null);
    defer ramfsKillSb(sb);
    
    const root = sb.root.?;
    
    // Create a file
    const mode = vfs.FileMode{
        .file_type = .regular,
        .user_read = true,
        .user_write = true,
    };
    const file_inode = try ramfsCreate(root, "test.txt", mode);
    defer file_inode.put();
    
    // Create file object
    var file = vfs.File.init(file_inode, .{ .write = true }, &ramfs_file_ops);
    defer file.put();
    
    // Write data
    const data = "Hello, RamFS!";
    const written = try ramfsWrite(&file, data, 0);
    try std.testing.expect(written == data.len);
    try std.testing.expect(file_inode.size == data.len);
    
    // Read data back
    var read_buffer: [32]u8 = undefined;
    file.position = 0;
    const read_bytes = try ramfsRead(&file, &read_buffer, 0);
    try std.testing.expect(read_bytes == data.len);
    try std.testing.expectEqualStrings(data, read_buffer[0..read_bytes]);
}

test "ramfs directory operations" {
    const allocator = std.testing.allocator;
    memory.kernel_allocator = allocator;
    defer memory.kernel_allocator = undefined;
    
    const sb = try ramfsMount("", "/", 0, null);
    defer ramfsKillSb(sb);
    
    const root = sb.root.?;
    
    // Create directory
    const dir_mode = vfs.FileMode{
        .file_type = .directory,
        .user_read = true,
        .user_write = true,
        .user_execute = true,
    };
    const dir = try ramfsMkdir(root, "testdir", dir_mode);
    defer dir.put();
    
    // Verify it's a directory
    try std.testing.expect(dir.mode.file_type == .directory);
    
    // Lookup should find it
    const found = try ramfsLookup(root, "testdir");
    try std.testing.expect(found != null);
    found.?.put();
    
    // Remove directory
    try ramfsRmdir(root, "testdir");
    
    // Lookup should not find it
    const not_found = try ramfsLookup(root, "testdir");
    try std.testing.expect(not_found == null);
}