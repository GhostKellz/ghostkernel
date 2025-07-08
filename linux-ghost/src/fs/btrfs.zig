//! Btrfs filesystem implementation for Ghost Kernel
//! Pure Zig implementation of Btrfs with gaming optimizations

const std = @import("std");
const vfs = @import("vfs.zig");
const driver_framework = @import("../drivers/driver_framework.zig");
const memory = @import("../mm/memory.zig");
const paging = @import("../mm/paging.zig");

/// Btrfs magic number
const BTRFS_MAGIC = 0x4D5F53665248425F; // "_BHRfS_M"

/// Btrfs superblock signature
const BTRFS_SUPER_MAGIC = 0x9123683E;

/// Block size constants
const BTRFS_MIN_BLOCK_SIZE = 4096;
const BTRFS_MAX_BLOCK_SIZE = 65536;

/// Btrfs root tree object IDs
const BTRFS_ROOT_TREE_OBJECTID = 1;
const BTRFS_EXTENT_TREE_OBJECTID = 2;
const BTRFS_CHUNK_TREE_OBJECTID = 3;
const BTRFS_DEV_TREE_OBJECTID = 4;
const BTRFS_FS_TREE_OBJECTID = 5;
const BTRFS_CSUM_TREE_OBJECTID = 7;
const BTRFS_QUOTA_TREE_OBJECTID = 8;
const BTRFS_UUID_TREE_OBJECTID = 9;
const BTRFS_FREE_SPACE_TREE_OBJECTID = 10;

/// Btrfs item types
const BTRFS_INODE_ITEM_KEY = 1;
const BTRFS_INODE_REF_KEY = 12;
const BTRFS_INODE_EXTREF_KEY = 13;
const BTRFS_XATTR_ITEM_KEY = 24;
const BTRFS_ORPHAN_ITEM_KEY = 48;
const BTRFS_DIR_LOG_ITEM_KEY = 60;
const BTRFS_DIR_LOG_INDEX_KEY = 72;
const BTRFS_DIR_ITEM_KEY = 84;
const BTRFS_DIR_INDEX_KEY = 96;
const BTRFS_EXTENT_DATA_KEY = 108;
const BTRFS_EXTENT_CSUM_KEY = 128;
const BTRFS_ROOT_ITEM_KEY = 132;
const BTRFS_ROOT_BACKREF_KEY = 144;
const BTRFS_ROOT_REF_KEY = 156;
const BTRFS_EXTENT_ITEM_KEY = 168;
const BTRFS_METADATA_ITEM_KEY = 169;
const BTRFS_TREE_BLOCK_REF_KEY = 176;
const BTRFS_EXTENT_DATA_REF_KEY = 178;
const BTRFS_EXTENT_REF_V0_KEY = 180;
const BTRFS_SHARED_BLOCK_REF_KEY = 182;
const BTRFS_SHARED_DATA_REF_KEY = 184;
const BTRFS_BLOCK_GROUP_ITEM_KEY = 192;
const BTRFS_FREE_SPACE_INFO_KEY = 198;
const BTRFS_FREE_SPACE_EXTENT_KEY = 199;
const BTRFS_FREE_SPACE_BITMAP_KEY = 200;
const BTRFS_DEV_EXTENT_KEY = 204;
const BTRFS_DEV_ITEM_KEY = 216;
const BTRFS_CHUNK_ITEM_KEY = 228;
const BTRFS_QGROUP_STATUS_KEY = 240;
const BTRFS_QGROUP_INFO_KEY = 242;
const BTRFS_QGROUP_LIMIT_KEY = 244;
const BTRFS_QGROUP_RELATION_KEY = 246;
const BTRFS_BALANCE_ITEM_KEY = 248;
const BTRFS_TEMPORARY_ITEM_KEY = 248;
const BTRFS_PERSISTENT_ITEM_KEY = 249;

/// Btrfs superblock structure
const BtrfsSuperblock = extern struct {
    csum: [32]u8,
    fsid: [16]u8,
    bytenr: u64,
    flags: u64,
    magic: u64,
    generation: u64,
    root: u64,
    chunk_root: u64,
    log_root: u64,
    log_root_transid: u64,
    total_bytes: u64,
    bytes_used: u64,
    root_dir_objectid: u64,
    num_devices: u64,
    sectorsize: u32,
    nodesize: u32,
    leafsize: u32,
    stripesize: u32,
    sys_chunk_array_size: u32,
    chunk_root_generation: u64,
    compat_flags: u64,
    compat_ro_flags: u64,
    incompat_flags: u64,
    csum_type: u16,
    root_level: u8,
    chunk_root_level: u8,
    log_root_level: u8,
    dev_item: BtrfsDevItem,
    label: [256]u8,
    cache_generation: u64,
    uuid_tree_generation: u64,
    metadata_uuid: [16]u8,
    nr_global_roots: u64,
    reserved: [945]u64,
    sys_chunk_array: [2048]u8,
    super_roots: [4]BtrfsRootBackup,
    reserved2: [565]u8,
};

/// Btrfs device item
const BtrfsDevItem = extern struct {
    devid: u64,
    total_bytes: u64,
    bytes_used: u64,
    io_align: u32,
    io_width: u32,
    sector_size: u32,
    type: u64,
    generation: u64,
    start_offset: u64,
    dev_group: u32,
    seek_speed: u8,
    bandwidth: u8,
    uuid: [16]u8,
    fsid: [16]u8,
};

/// Btrfs root backup
const BtrfsRootBackup = extern struct {
    tree_root: u64,
    tree_root_gen: u64,
    chunk_root: u64,
    chunk_root_gen: u64,
    extent_root: u64,
    extent_root_gen: u64,
    fs_root: u64,
    fs_root_gen: u64,
    dev_root: u64,
    dev_root_gen: u64,
    csum_root: u64,
    csum_root_gen: u64,
    total_bytes: u64,
    bytes_used: u64,
    num_devices: u64,
    unused_64: [4]u64,
    tree_root_level: u8,
    chunk_root_level: u8,
    extent_root_level: u8,
    fs_root_level: u8,
    dev_root_level: u8,
    csum_root_level: u8,
    unused_8: [10]u8,
};

/// Btrfs header
const BtrfsHeader = extern struct {
    csum: [32]u8,
    fsid: [16]u8,
    bytenr: u64,
    flags: u64,
    chunk_tree_uuid: [16]u8,
    generation: u64,
    owner: u64,
    nritems: u32,
    level: u8,
    _pad: [3]u8,
};

/// Btrfs item
const BtrfsItem = extern struct {
    key: BtrfsKey,
    offset: u32,
    size: u32,
};

/// Btrfs key
const BtrfsKey = extern struct {
    objectid: u64,
    type: u8,
    offset: u64,
    
    pub fn compare(self: BtrfsKey, other: BtrfsKey) std.math.Order {
        if (self.objectid < other.objectid) return .lt;
        if (self.objectid > other.objectid) return .gt;
        if (self.type < other.type) return .lt;
        if (self.type > other.type) return .gt;
        if (self.offset < other.offset) return .lt;
        if (self.offset > other.offset) return .gt;
        return .eq;
    }
};

/// Btrfs key pointer
const BtrfsKeyPtr = extern struct {
    key: BtrfsKey,
    blockptr: u64,
    generation: u64,
};

/// Btrfs inode item
const BtrfsInodeItem = extern struct {
    generation: u64,
    transid: u64,
    size: u64,
    nbytes: u64,
    block_group: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    mode: u32,
    rdev: u64,
    flags: u64,
    sequence: u64,
    atime: BtrfsTimespec,
    ctime: BtrfsTimespec,
    mtime: BtrfsTimespec,
    otime: BtrfsTimespec,
};

/// Btrfs timespec
const BtrfsTimespec = extern struct {
    sec: u64,
    nsec: u32,
    _pad: u32,
};

/// Btrfs directory item
const BtrfsDirItem = extern struct {
    location: BtrfsKey,
    transid: u64,
    data_len: u16,
    name_len: u16,
    type: u8,
    _pad: [3]u8,
};

/// Btrfs extent data
const BtrfsExtentData = extern struct {
    generation: u64,
    ram_bytes: u64,
    compression: u8,
    encryption: u8,
    other_encoding: u16,
    type: u8,
    _pad: [3]u8,
};

/// Btrfs file extent types
const BTRFS_FILE_EXTENT_INLINE = 0;
const BTRFS_FILE_EXTENT_REG = 1;
const BTRFS_FILE_EXTENT_PREALLOC = 2;

/// Btrfs regular file extent
const BtrfsRegularExtent = extern struct {
    disk_bytenr: u64,
    disk_num_bytes: u64,
    offset: u64,
    num_bytes: u64,
};

/// Btrfs node
const BtrfsNode = struct {
    header: BtrfsHeader,
    ptrs: []BtrfsKeyPtr,
    
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !BtrfsNode {
        if (data.len < @sizeOf(BtrfsHeader)) {
            return error.InvalidNode;
        }
        
        const header = @as(*const BtrfsHeader, @ptrCast(@alignCast(data.ptr))).*;
        const ptrs_data = data[@sizeOf(BtrfsHeader)..];
        const ptrs = @as([*]const BtrfsKeyPtr, @ptrCast(@alignCast(ptrs_data.ptr)))[0..header.nritems];
        
        return BtrfsNode{
            .header = header,
            .ptrs = try allocator.dupe(BtrfsKeyPtr, ptrs),
        };
    }
    
    pub fn deinit(self: *BtrfsNode, allocator: std.mem.Allocator) void {
        allocator.free(self.ptrs);
    }
    
    pub fn findKey(self: *BtrfsNode, key: BtrfsKey) ?u64 {
        for (self.ptrs) |ptr| {
            if (ptr.key.compare(key) == .eq) {
                return ptr.blockptr;
            }
        }
        return null;
    }
    
    pub fn findSlot(self: *BtrfsNode, key: BtrfsKey) usize {
        var left: usize = 0;
        var right: usize = self.ptrs.len;
        
        while (left < right) {
            const mid = (left + right) / 2;
            if (self.ptrs[mid].key.compare(key) == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        return left;
    }
};

/// Btrfs leaf
const BtrfsLeaf = struct {
    header: BtrfsHeader,
    items: []BtrfsItem,
    data: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !BtrfsLeaf {
        if (data.len < @sizeOf(BtrfsHeader)) {
            return error.InvalidLeaf;
        }
        
        const header = @as(*const BtrfsHeader, @ptrCast(@alignCast(data.ptr))).*;
        const items_data = data[@sizeOf(BtrfsHeader)..];
        const items = @as([*]const BtrfsItem, @ptrCast(@alignCast(items_data.ptr)))[0..header.nritems];
        
        return BtrfsLeaf{
            .header = header,
            .items = try allocator.dupe(BtrfsItem, items),
            .data = data,
        };
    }
    
    pub fn deinit(self: *BtrfsLeaf, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
    
    pub fn findItem(self: *BtrfsLeaf, key: BtrfsKey) ?usize {
        for (self.items, 0..) |item, i| {
            if (item.key.compare(key) == .eq) {
                return i;
            }
        }
        return null;
    }
    
    pub fn getItemData(self: *BtrfsLeaf, index: usize) []const u8 {
        if (index >= self.items.len) return &[_]u8{};
        
        const item = self.items[index];
        const data_start = @sizeOf(BtrfsHeader) + self.header.nritems * @sizeOf(BtrfsItem) + item.offset;
        return self.data[data_start..data_start + item.size];
    }
};

/// Btrfs filesystem
pub const BtrfsFilesystem = struct {
    allocator: std.mem.Allocator,
    superblock: BtrfsSuperblock,
    device: ?*driver_framework.Device,
    
    // Caching
    block_cache: std.HashMap(u64, []u8),
    node_cache: std.HashMap(u64, BtrfsNode),
    leaf_cache: std.HashMap(u64, BtrfsLeaf),
    
    // Gaming optimizations
    prefetch_enabled: bool,
    async_io_enabled: bool,
    compression_enabled: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .superblock = undefined,
            .device = null,
            .block_cache = std.HashMap(u64, []u8).init(allocator),
            .node_cache = std.HashMap(u64, BtrfsNode).init(allocator),
            .leaf_cache = std.HashMap(u64, BtrfsLeaf).init(allocator),
            .prefetch_enabled = true,
            .async_io_enabled = true,
            .compression_enabled = true,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up caches
        var block_iter = self.block_cache.iterator();
        while (block_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.block_cache.deinit();
        
        var node_iter = self.node_cache.iterator();
        while (node_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.node_cache.deinit();
        
        var leaf_iter = self.leaf_cache.iterator();
        while (leaf_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.leaf_cache.deinit();
    }
    
    pub fn mount(self: *Self, device: *driver_framework.Device) !void {
        self.device = device;
        
        // Read superblock
        const superblock_data = try self.readBlock(65536); // Superblock at offset 64KB
        if (superblock_data.len < @sizeOf(BtrfsSuperblock)) {
            return error.InvalidSuperblock;
        }
        
        self.superblock = @as(*const BtrfsSuperblock, @ptrCast(@alignCast(superblock_data.ptr))).*;
        
        // Validate superblock
        if (self.superblock.magic != BTRFS_SUPER_MAGIC) {
            return error.InvalidFilesystem;
        }
        
        // Validate checksum
        if (!try self.validateChecksum(superblock_data)) {
            return error.CorruptedSuperblock;
        }
        
        // Initialize gaming optimizations
        if (self.prefetch_enabled) {
            try self.initializePrefetching();
        }
    }
    
    pub fn readBlock(self: *Self, bytenr: u64) ![]u8 {
        // Check cache first
        if (self.block_cache.get(bytenr)) |cached| {
            return cached;
        }
        
        // Read from device
        const block_size = self.superblock.sectorsize;
        const block_data = try self.allocator.alloc(u8, block_size);
        
        // Perform actual I/O (simplified)
        if (self.device) |dev| {
            const file = try dev.open(0);
            defer file.put();
            
            _ = try file.read(block_data);
        }
        
        // Cache the block
        try self.block_cache.put(bytenr, block_data);
        
        return block_data;
    }
    
    pub fn readNode(self: *Self, bytenr: u64) !BtrfsNode {
        // Check cache first
        if (self.node_cache.get(bytenr)) |cached| {
            return cached;
        }
        
        // Read block data
        const block_data = try self.readBlock(bytenr);
        
        // Parse as node
        const node = try BtrfsNode.init(self.allocator, block_data);
        
        // Cache the node
        try self.node_cache.put(bytenr, node);
        
        return node;
    }
    
    pub fn readLeaf(self: *Self, bytenr: u64) !BtrfsLeaf {
        // Check cache first
        if (self.leaf_cache.get(bytenr)) |cached| {
            return cached;
        }
        
        // Read block data
        const block_data = try self.readBlock(bytenr);
        
        // Parse as leaf
        const leaf = try BtrfsLeaf.init(self.allocator, block_data);
        
        // Cache the leaf
        try self.leaf_cache.put(bytenr, leaf);
        
        return leaf;
    }
    
    pub fn searchTree(self: *Self, root_bytenr: u64, key: BtrfsKey) !?BtrfsLeaf {
        var current_bytenr = root_bytenr;
        
        while (true) {
            const block_data = try self.readBlock(current_bytenr);
            const header = @as(*const BtrfsHeader, @ptrCast(@alignCast(block_data.ptr))).*;
            
            if (header.level == 0) {
                // This is a leaf
                return try self.readLeaf(current_bytenr);
            } else {
                // This is a node
                const node = try self.readNode(current_bytenr);
                const slot = node.findSlot(key);
                
                if (slot >= node.ptrs.len) {
                    return null;
                }
                
                current_bytenr = node.ptrs[slot].blockptr;
            }
        }
    }
    
    pub fn lookupInode(self: *Self, objectid: u64) !?BtrfsInodeItem {
        const key = BtrfsKey{
            .objectid = objectid,
            .type = BTRFS_INODE_ITEM_KEY,
            .offset = 0,
        };
        
        const leaf = try self.searchTree(self.superblock.root, key) orelse return null;
        const item_index = leaf.findItem(key) orelse return null;
        const item_data = leaf.getItemData(item_index);
        
        if (item_data.len < @sizeOf(BtrfsInodeItem)) {
            return null;
        }
        
        return @as(*const BtrfsInodeItem, @ptrCast(@alignCast(item_data.ptr))).*;
    }
    
    pub fn lookupDirItem(self: *Self, parent_objectid: u64, name: []const u8) !?BtrfsKey {
        const name_hash = self.nameHash(name);
        const key = BtrfsKey{
            .objectid = parent_objectid,
            .type = BTRFS_DIR_ITEM_KEY,
            .offset = name_hash,
        };
        
        const leaf = try self.searchTree(self.superblock.root, key) orelse return null;
        const item_index = leaf.findItem(key) orelse return null;
        const item_data = leaf.getItemData(item_index);
        
        if (item_data.len < @sizeOf(BtrfsDirItem)) {
            return null;
        }
        
        const dir_item = @as(*const BtrfsDirItem, @ptrCast(@alignCast(item_data.ptr))).*;
        
        // Verify name matches
        const stored_name = item_data[@sizeOf(BtrfsDirItem)..@sizeOf(BtrfsDirItem) + dir_item.name_len];
        if (!std.mem.eql(u8, name, stored_name)) {
            return null;
        }
        
        return dir_item.location;
    }
    
    pub fn readFileExtent(self: *Self, objectid: u64, offset: u64, buffer: []u8) !usize {
        const key = BtrfsKey{
            .objectid = objectid,
            .type = BTRFS_EXTENT_DATA_KEY,
            .offset = offset,
        };
        
        const leaf = try self.searchTree(self.superblock.root, key) orelse return 0;
        const item_index = leaf.findItem(key) orelse return 0;
        const item_data = leaf.getItemData(item_index);
        
        if (item_data.len < @sizeOf(BtrfsExtentData)) {
            return 0;
        }
        
        const extent_data = @as(*const BtrfsExtentData, @ptrCast(@alignCast(item_data.ptr))).*;
        
        switch (extent_data.type) {
            BTRFS_FILE_EXTENT_INLINE => {
                // Inline data
                const inline_data = item_data[@sizeOf(BtrfsExtentData)..];
                const copy_len = @min(buffer.len, inline_data.len);
                @memcpy(buffer[0..copy_len], inline_data[0..copy_len]);
                return copy_len;
            },
            BTRFS_FILE_EXTENT_REG => {
                // Regular extent
                const extent = @as(*const BtrfsRegularExtent, @ptrCast(@alignCast(item_data[@sizeOf(BtrfsExtentData)..].ptr))).*;
                const extent_data_raw = try self.readBlock(extent.disk_bytenr);
                
                const data_offset = extent.offset;
                const data_len = @min(buffer.len, extent.num_bytes);
                const copy_len = @min(data_len, extent_data_raw.len - data_offset);
                
                @memcpy(buffer[0..copy_len], extent_data_raw[data_offset..data_offset + copy_len]);
                return copy_len;
            },
            else => return 0,
        }
    }
    
    pub fn enableGamingOptimizations(self: *Self) !void {
        self.prefetch_enabled = true;
        self.async_io_enabled = true;
        
        // Increase cache sizes for gaming workloads
        try self.resizeCaches(1024 * 1024); // 1MB cache
        
        // Enable compression for faster loading
        self.compression_enabled = true;
    }
    
    fn nameHash(self: *Self, name: []const u8) u64 {
        _ = self;
        var hash: u64 = 0;
        for (name) |byte| {
            hash = (hash << 5) + hash + byte;
        }
        return hash;
    }
    
    fn validateChecksum(self: *Self, data: []const u8) !bool {
        _ = self;
        // CRC32 checksum validation
        const crc = std.hash.crc.Crc32.init();
        const calculated = crc.hash(data[32..]);
        const stored = std.mem.readInt(u32, data[0..4], .little);
        return calculated == stored;
    }
    
    fn initializePrefetching(self: *Self) !void {
        // Initialize prefetching for gaming workloads
        _ = self;
        // This would set up background prefetching threads
    }
    
    fn resizeCaches(self: *Self, new_size: usize) !void {
        _ = self;
        _ = new_size;
        // Resize caches for better performance
    }
};

/// Btrfs VFS operations
const BtrfsVFS = struct {
    fs: *BtrfsFilesystem,
    
    pub fn init(fs: *BtrfsFilesystem) BtrfsVFS {
        return BtrfsVFS{ .fs = fs };
    }
    
    pub fn lookup(self: *BtrfsVFS, parent_inode: *vfs.Inode, name: []const u8) vfs.VFSError!?*vfs.Inode {
        const parent_objectid = parent_inode.number;
        const child_key = self.fs.lookupDirItem(parent_objectid, name) catch return vfs.VFSError.IOError;
        
        if (child_key) |key| {
            const child_inode_item = self.fs.lookupInode(key.objectid) catch return vfs.VFSError.IOError;
            if (child_inode_item) |inode_item| {
                const child_inode = try parent_inode.superblock.allocator.create(vfs.Inode);
                child_inode.* = vfs.Inode.init(parent_inode.superblock, key.objectid, &btrfs_inode_ops);
                
                // Set inode attributes
                child_inode.size = inode_item.size;
                child_inode.access_time = inode_item.atime.sec;
                child_inode.modify_time = inode_item.mtime.sec;
                child_inode.change_time = inode_item.ctime.sec;
                child_inode.user_id = inode_item.uid;
                child_inode.group_id = inode_item.gid;
                
                return child_inode;
            }
        }
        
        return null;
    }
    
    pub fn read(self: *BtrfsVFS, file: *vfs.File, buffer: []u8, offset: u64) vfs.VFSError!usize {
        const bytes_read = self.fs.readFileExtent(file.inode.number, offset, buffer) catch return vfs.VFSError.IOError;
        return bytes_read;
    }
};

/// Btrfs inode operations
var btrfs_inode_ops = vfs.InodeOps{
    .lookup = btrfsLookup,
};

fn btrfsLookup(inode: *vfs.Inode, name: []const u8) vfs.VFSError!?*vfs.Inode {
    const btrfs_vfs = @as(*BtrfsVFS, @ptrCast(@alignCast(inode.private_data.?)));
    return btrfs_vfs.lookup(inode, name);
}

/// Btrfs file operations
var btrfs_file_ops = vfs.FileOps{
    .read = btrfsRead,
    .seek = btrfsSeek,
};

fn btrfsRead(file: *vfs.File, buffer: []u8, offset: u64) vfs.VFSError!usize {
    const btrfs_vfs = @as(*BtrfsVFS, @ptrCast(@alignCast(file.private_data.?)));
    return btrfs_vfs.read(file, buffer, offset);
}

fn btrfsSeek(file: *vfs.File, offset: i64, whence: vfs.SeekWhence) vfs.VFSError!u64 {
    const new_pos: i64 = switch (whence) {
        .set => offset,
        .current => @as(i64, @intCast(file.position)) + offset,
        .end => @as(i64, @intCast(file.inode.size)) + offset,
    };
    
    if (new_pos < 0) return vfs.VFSError.InvalidArgument;
    file.position = @intCast(new_pos);
    return file.position;
}

/// Btrfs superblock operations
var btrfs_super_ops = vfs.SuperOps{
    .put_super = btrfsPutSuper,
    .sync_fs = btrfsSyncFS,
    .statfs = btrfsStatFS,
};

fn btrfsPutSuper(sb: *vfs.SuperBlock) void {
    const btrfs_fs = @as(*BtrfsFilesystem, @ptrCast(@alignCast(sb.private_data.?)));
    btrfs_fs.deinit();
}

fn btrfsSyncFS(sb: *vfs.SuperBlock) vfs.VFSError!void {
    _ = sb;
    // Sync filesystem to disk
}

fn btrfsStatFS(sb: *vfs.SuperBlock, stat: *vfs.FilesystemStat) vfs.VFSError!void {
    const btrfs_fs = @as(*BtrfsFilesystem, @ptrCast(@alignCast(sb.private_data.?)));
    
    stat.* = vfs.FilesystemStat{
        .type = BTRFS_SUPER_MAGIC,
        .block_size = btrfs_fs.superblock.sectorsize,
        .total_blocks = btrfs_fs.superblock.total_bytes / btrfs_fs.superblock.sectorsize,
        .free_blocks = (btrfs_fs.superblock.total_bytes - btrfs_fs.superblock.bytes_used) / btrfs_fs.superblock.sectorsize,
        .available_blocks = (btrfs_fs.superblock.total_bytes - btrfs_fs.superblock.bytes_used) / btrfs_fs.superblock.sectorsize,
        .total_inodes = 0, // Btrfs doesn't have a fixed inode count
        .free_inodes = 0,
        .filesystem_id = 0,
        .max_filename_length = 255,
    };
}

/// Btrfs filesystem type
pub const btrfs_filesystem_type = vfs.FilesystemType{
    .name = "btrfs",
    .mount = btrfsMount,
    .kill_sb = btrfsKillSB,
};

fn btrfsMount(dev_name: []const u8, mount_point: []const u8, flags: u32, data: ?[]const u8) vfs.VFSError!*vfs.SuperBlock {
    _ = mount_point;
    _ = flags;
    _ = data;
    
    // Find device
    const dm = driver_framework.getDeviceManager();
    const device = dm.findDeviceByType(.block) orelse return vfs.VFSError.DeviceNotFound;
    
    // Create filesystem
    const allocator = dm.allocator;
    const btrfs_fs = try allocator.create(BtrfsFilesystem);
    btrfs_fs.* = BtrfsFilesystem.init(allocator);
    
    // Mount filesystem
    btrfs_fs.mount(device) catch |err| {
        btrfs_fs.deinit();
        allocator.destroy(btrfs_fs);
        return switch (err) {
            error.InvalidSuperblock => vfs.VFSError.InvalidArgument,
            error.InvalidFilesystem => vfs.VFSError.InvalidArgument,
            error.CorruptedSuperblock => vfs.VFSError.IOError,
            else => vfs.VFSError.IOError,
        };
    };
    
    // Create superblock
    const sb = try allocator.create(vfs.SuperBlock);
    sb.* = vfs.SuperBlock{
        .block_size = btrfs_fs.superblock.sectorsize,
        .total_blocks = btrfs_fs.superblock.total_bytes / btrfs_fs.superblock.sectorsize,
        .free_blocks = (btrfs_fs.superblock.total_bytes - btrfs_fs.superblock.bytes_used) / btrfs_fs.superblock.sectorsize,
        .total_inodes = 0,
        .free_inodes = 0,
        .root = null,
        .ops = &btrfs_super_ops,
        .private_data = btrfs_fs,
    };
    
    // Create root inode
    const root_inode = try allocator.create(vfs.Inode);
    root_inode.* = vfs.Inode.init(sb, BTRFS_FS_TREE_OBJECTID, &btrfs_inode_ops);
    root_inode.private_data = &BtrfsVFS.init(btrfs_fs);
    
    sb.root = root_inode;
    
    return sb;
}

fn btrfsKillSB(sb: *vfs.SuperBlock) void {
    const btrfs_fs = @as(*BtrfsFilesystem, @ptrCast(@alignCast(sb.private_data.?)));
    btrfs_fs.deinit();
    
    const allocator = btrfs_fs.allocator;
    allocator.destroy(btrfs_fs);
    allocator.destroy(sb);
}

/// Initialize Btrfs filesystem support
pub fn initBtrfs() !void {
    const vfs_instance = vfs.getVFS();
    try vfs_instance.registerFilesystem(&btrfs_filesystem_type);
}

// Tests
test "btrfs key comparison" {
    const key1 = BtrfsKey{ .objectid = 1, .type = 1, .offset = 0 };
    const key2 = BtrfsKey{ .objectid = 1, .type = 1, .offset = 1 };
    const key3 = BtrfsKey{ .objectid = 2, .type = 1, .offset = 0 };
    
    try std.testing.expect(key1.compare(key2) == .lt);
    try std.testing.expect(key1.compare(key3) == .lt);
    try std.testing.expect(key2.compare(key1) == .gt);
    try std.testing.expect(key1.compare(key1) == .eq);
}

test "btrfs name hash" {
    const allocator = std.testing.allocator;
    var fs = BtrfsFilesystem.init(allocator);
    defer fs.deinit();
    
    const hash1 = fs.nameHash("test");
    const hash2 = fs.nameHash("test");
    const hash3 = fs.nameHash("different");
    
    try std.testing.expect(hash1 == hash2);
    try std.testing.expect(hash1 != hash3);
}

test "btrfs filesystem initialization" {
    const allocator = std.testing.allocator;
    var fs = BtrfsFilesystem.init(allocator);
    defer fs.deinit();
    
    try std.testing.expect(fs.prefetch_enabled == true);
    try std.testing.expect(fs.async_io_enabled == true);
    try std.testing.expect(fs.compression_enabled == true);
}