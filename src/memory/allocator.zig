// Alocadores simples do core legado.
// Todos operam sobre um backing buffer próprio; nenhum deles substitui
// `std.mem.Allocator` e nenhum é usado pelo Editor ou pelo Runtime.
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

/// Alinha `offset` para `alignment` bytes, tratando 0 como 1.
/// Retorna `null` quando o alinhamento ultrapassa `limit`, porque nesse caso
/// nem um bloco vazio caberia.
fn alignOffset(offset: usize, alignment: u8, limit: usize) ?usize {
    const align_value: usize = if (alignment == 0) 1 else alignment;
    const remainder = offset % align_value;
    const aligned = if (remainder == 0) offset else offset + (align_value - remainder);
    if (aligned > limit) return null;
    return aligned;
}

/// Reserva com um único bloco e avança o offset a cada `alloc`.
/// `reset` reutiliza o buffer, mas não devolve memória ao allocator de origem.
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

    /// `alignment` é expresso em bytes; 0 é tratado como 1.
    /// A região retornada é sempre um sub-slice de `backing`, sem cópia.
    pub fn alloc(self: *ArenaAllocator, size: usize, alignment: u8) error{OutOfMemory}![]u8 {
        const current = alignOffset(self.offset, alignment, self.backing.len) orelse return error.OutOfMemory;
        if (size > self.backing.len - current) return error.OutOfMemory;
        const ptr = self.backing[current .. current + size];
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

    pub fn init(child_allocator: std.mem.Allocator) GeneralPurposeAllocator {
        return GeneralPurposeAllocator{
            .inner = child_allocator,
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

    /// Mesmo contrato de `ArenaAllocator.alloc`, sem contabilização.
    pub fn alloc(self: *LinearAllocator, size: usize, alignment: u8) error{OutOfMemory}![]u8 {
        const current = alignOffset(self.offset, alignment, self.backing.len) orelse return error.OutOfMemory;
        if (size > self.backing.len - current) return error.OutOfMemory;
        const ptr = self.backing[current .. current + size];
        self.offset = current + size;
        return ptr;
    }

    pub fn deinit(self: *LinearAllocator) void {
        self.allocator.free(self.backing);
    }
};

/// Descreve blocos de tamanho/alinhamento fixos.
/// Não reserva nem entrega blocos: `allocate`/`free` ainda não existem.
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

test "tracker counts payload bytes and honours enabled" {
    var tracker = MemoryTracker.init();
    tracker.recordAlloc(16);
    tracker.recordAlloc(4);
    tracker.recordFree(8);

    try std.testing.expectEqual(@as(usize, 20), tracker.stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 8), tracker.stats.total_freed);
    try std.testing.expectEqual(@as(usize, 2), tracker.stats.allocations);
    try std.testing.expectEqual(@as(usize, 1), tracker.stats.deallocations);

    tracker.enabled = false;
    tracker.recordAlloc(1024);
    try std.testing.expectEqual(@as(usize, 20), tracker.stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 2), tracker.stats.allocations);
}

test "arena returns disjoint sub-slices aligned to the requested boundary" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 64);
    defer arena.deinit();

    const first = try arena.alloc(3, 1);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    @memset(first, 0xaa);

    const second = try arena.alloc(2, 8);
    // Primeiro bloco ocupa 0..3; o segundo começa no próximo múltiplo de 8.
    try std.testing.expectEqual(@intFromPtr(arena.backing.ptr) + 8, @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(u8, 0xaa), arena.backing[0]);

    try std.testing.expectEqual(@as(usize, 5), arena.tracker.stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 2), arena.tracker.stats.allocations);
}

test "arena treats zero alignment as one and reports exhaustion" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 8);
    defer arena.deinit();

    _ = try arena.alloc(8, 0);
    try std.testing.expectError(error.OutOfMemory, arena.alloc(1, 1));
    try std.testing.expectError(error.OutOfMemory, arena.alloc(std.math.maxInt(usize), 1));
    // Nada foi contabilizado pelas tentativas recusadas.
    try std.testing.expectEqual(@as(usize, 1), arena.tracker.stats.allocations);
}

test "arena alignment beyond the backing buffer is rejected, not wrapped" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 10);
    defer arena.deinit();

    _ = try arena.alloc(9, 1);
    try std.testing.expectError(error.OutOfMemory, arena.alloc(0, 4));
}

test "arena reset reuses the backing buffer" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 16);
    defer arena.deinit();

    const first = try arena.alloc(16, 1);
    arena.reset();
    const reused = try arena.alloc(16, 1);

    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
}

test "linear allocator advances and rejects oversized requests" {
    var linear = try LinearAllocator.init(std.testing.allocator, 16);
    defer linear.deinit();

    const first = try linear.alloc(4, 1);
    const second = try linear.alloc(4, 1);
    try std.testing.expectEqual(@intFromPtr(first.ptr) + 4, @intFromPtr(second.ptr));

    try std.testing.expectError(error.OutOfMemory, linear.alloc(9, 1));
    try std.testing.expectError(error.OutOfMemory, linear.alloc(std.math.maxInt(usize), 1));
}

test "frame allocator reuses memory after reset" {
    var frame = try FrameAllocator.init(std.testing.allocator, 32);
    defer frame.deinit();

    frame.offset = 32;
    frame.reset();

    try std.testing.expectEqual(@as(usize, 0), frame.offset);
    try std.testing.expectEqual(@as(usize, 32), frame.backing.len);
}

test "pool descriptor keeps the configured geometry" {
    const pool = PoolAllocator.init(std.testing.allocator, 64, 16);
    try std.testing.expectEqual(@as(usize, 64), pool.block_size);
    try std.testing.expectEqual(@as(u8, 16), pool.block_align);
}

test "general purpose allocator forwards the wrapped allocator" {
    var gpa = GeneralPurposeAllocator.init(std.testing.allocator);
    const forwarded = gpa.allocator();

    const bytes = try forwarded.alloc(u8, 4);
    defer forwarded.free(bytes);
    try std.testing.expectEqual(@as(usize, 4), bytes.len);
}
