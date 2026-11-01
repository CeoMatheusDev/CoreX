const std = @import("std");

pub const MemoryStats = struct {
    total_allocated: usize = 0,
    total_freed: usize = 0,
    allocations: usize = 0,
    deallocations: usize = 0,
};

pub const MemoryTracker = struct {
    stats: MemoryStats = .{},
    enabled: bool = true,

    pub fn init() MemoryTracker {
        return .{};
    }

    pub fn recordAlloc(self: *MemoryTracker, size: usize) void {
        if (!self.enabled) return;
        self.stats.total_allocated += size;
        self.stats.allocations += 1;
    }

    pub fn recordFree(self: *MemoryTracker, size: usize) void {
        if (!self.enabled) return;
        self.stats.total_freed += size;
        self.stats.deallocations += 1;
    }
};

pub const ArenaAllocator = struct {
    backing: []u8,
    offset: usize = 0,
    tracker: MemoryTracker,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ArenaAllocator {
        const backing = try allocator.alloc(u8, size);
        return ArenaAllocator{
            .backing = backing,
            .offset = 0,
            .tracker = MemoryTracker.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        self.allocator.free(self.backing);
        self.offset = 0;
    }

    pub fn alloc(self: *ArenaAllocator, size: usize, align: u8) error{OutOfMemory}![]u8 {
        const align_val = if (@intCast(usize, align) > 0) @intCast(usize, align) else 1;
        // Alinhamento simples
        var current = self.offset;
        const rem = current % align_val;
        if (rem != 0) current += align_val - rem;
        if (current + size > self.backing.len) return error.OutOfMemory;
        const ptr = self.backing[current..current+size];
        self.offset = current + size;
        self.tracker.recordAlloc(size);
        return ptr;
    }

    pub fn reset(self: *ArenaAllocator) void {
        self.offset = 0;
    }
};

pub const GeneralPurposeAllocator = struct {
    inner: std.mem.Allocator,
    tracker: MemoryTracker,

    pub fn init(allocator: std.mem.Allocator) GeneralPurposeAllocator {
        return GeneralPurposeAllocator{
            .inner = allocator,
            .tracker = MemoryTracker.init(),
        };
    }

    pub fn allocator(self: *GeneralPurposeAllocator) std.mem.Allocator {
        return self.inner;
    }
};

pub const LinearAllocator = struct {
    backing: []u8,
    offset: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !LinearAllocator {
        return LinearAllocator{
            .backing = try allocator.alloc(u8, size),
            .offset = 0,
            .allocator = allocator,
        };
    }

    pub fn alloc(self: *LinearAllocator, size: usize, align: u8) error{OutOfMemory}![]u8 {
        const align_val = if (@intCast(usize, align) > 0) @intCast(usize, align) else 1;
        var current = self.offset;
        const rem = current % align_val;
        if (rem != 0) current += align_val - rem;
        if (current + size > self.backing.len) return error.OutOfMemory;
        const ptr = self.backing[current..current+size];
        self.offset = current + size;
        return ptr;
    }

    pub fn deinit(self: *LinearAllocator) void {
        self.allocator.free(self.backing);
    }
};

pub const PoolAllocator = struct {
    block_size: usize,
    block_align: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, block_size: usize, block_align: u8) PoolAllocator {
        return PoolAllocator{
            .block_size = block_size,
            .block_align = block_align,
            .allocator = allocator,
        };
    }
};

pub const FrameAllocator = struct {
    backing: []u8,
    offset: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !FrameAllocator {
        return FrameAllocator{
            .backing = try allocator.alloc(u8, size),
            .offset = 0,
            .allocator = allocator,
        };
    }

    pub fn reset(self: *FrameAllocator) void {
        self.offset = 0;
    }

    pub fn deinit(self: *FrameAllocator) void {
        self.allocator.free(self.backing);
    }
};
