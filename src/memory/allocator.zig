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

/// Alinha `size` para o próximo múltiplo de `alignment`, sem limite superior.
/// Retorna `null` em overflow. 0 é tratado como 1, como em `alignOffset`.
fn alignedStride(size: usize, alignment: u8) ?usize {
    const align_value: usize = if (alignment == 0) 1 else alignment;
    const remainder = size % align_value;
    if (remainder == 0) return size;
    return std.math.add(usize, size, align_value - remainder) catch null;
}

/// Blocos de tamanho e alinhamento fixos entregues a partir de um buffer
/// próprio. `alloc` reutiliza blocos devolvidos por `free`; a capacidade é fixa
/// e nunca cresce sozinha (ADR-001: sem crescimento invisível por frame).
/// Assim como os demais allocators deste arquivo, não implementa
/// `std.mem.Allocator` e não é usado pelo Editor nem pelo Runtime.
pub const PoolAllocator = struct {
    /// Buffer exatamente como veio do allocator de origem, incluindo a folga
    /// usada para alinhar o primeiro bloco. É o único bloco a liberar.
    raw: []u8,
    /// Início alinhado do primeiro bloco, sub-slice de `raw`.
    /// O alinhamento é contrato de execução, não do tipo `[]u8`.
    backing: []u8,
    /// Distância entre blocos consecutivos, múltipla de `block_align`.
    stride: usize,
    /// Pilha LIFO de índices livres: válidos em `[0, free_count)`. O topo é
    /// `free_stack[free_count - 1]`, portanto a liberação mais recente é a
    /// primeira a ser reutilizada.
    free_stack: []usize,
    free_count: usize,
    /// Marca de bloco em uso; detecta liberação dupla e liberação de bloco
    /// alheio sem corromper a pilha de reuso.
    in_use: []bool,
    block_size: usize,
    block_align: u8,
    tracker: MemoryTracker,
    allocator: std.mem.Allocator,

    pub const Error = error{ OutOfMemory, InvalidGeometry };
    pub const FreeError = error{InvalidFree};

    /// Reserva `block_count` blocos de `block_size` bytes alinhados a
    /// `block_align` (0 é tratado como 1). Geometria nula ou que não cabe em
    /// `usize` é recusada antes de qualquer reserva.
    pub fn init(allocator: std.mem.Allocator, block_size: usize, block_count: usize, block_align: u8) Error!PoolAllocator {
        if (block_size == 0 or block_count == 0) return error.InvalidGeometry;
        const stride = alignedStride(block_size, block_align) orelse return error.InvalidGeometry;
        const alignment: usize = if (block_align == 0) 1 else block_align;
        const blocks = std.math.mul(usize, stride, block_count) catch return error.InvalidGeometry;
        // Folga para alinhar o primeiro bloco dentro do buffer bruto.
        const total = std.math.add(usize, blocks, alignment - 1) catch return error.InvalidGeometry;
        const raw = try allocator.alloc(u8, total);
        errdefer allocator.free(raw);
        const base = @intFromPtr(raw.ptr);
        const slack = (alignment - (base % alignment)) % alignment;
        const free_stack = try allocator.alloc(usize, block_count);
        errdefer allocator.free(free_stack);
        const in_use = try allocator.alloc(bool, block_count);
        errdefer allocator.free(in_use);
        @memset(in_use, false);
        for (free_stack, 0..) |*slot, index| slot.* = index;
        return PoolAllocator{
            .raw = raw,
            .backing = raw[slack..][0..blocks],
            .stride = stride,
            .free_stack = free_stack,
            .free_count = block_count,
            .in_use = in_use,
            .block_size = block_size,
            .block_align = @intCast(alignment),
            .tracker = MemoryTracker.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PoolAllocator) void {
        self.allocator.free(self.free_stack);
        self.allocator.free(self.in_use);
        self.allocator.free(self.raw);
        self.free_count = 0;
    }

    /// Entrega exatamente `block_size` bytes alinhados. Esgotar a capacidade é
    /// `OutOfMemory`; o pool nunca reserva mais memória por conta própria.
    pub fn alloc(self: *PoolAllocator) error{OutOfMemory}![]u8 {
        if (self.free_count == 0) return error.OutOfMemory;
        self.free_count -= 1;
        const index = self.free_stack[self.free_count];
        self.in_use[index] = true;
        self.tracker.recordAlloc(self.block_size);
        return self.blockingAt(index);
    }

    /// Aceita apenas um bloco entregue por `alloc` e ainda em uso: comprimento
    /// diferente, ponteiro fora do backing, deslocamento não múltiplo do stride
    /// ou liberação dupla são `InvalidFree` e deixam a capacidade intacta.
    pub fn free(self: *PoolAllocator, block: []u8) FreeError!void {
        if (block.len != self.block_size) return error.InvalidFree;
        const index = self.indexOf(@intFromPtr(block.ptr)) orelse return error.InvalidFree;
        if (!self.in_use[index]) return error.InvalidFree;
        self.in_use[index] = false;
        self.free_stack[self.free_count] = index;
        self.free_count += 1;
        self.tracker.recordFree(self.block_size);
    }

    /// Devolve todos os blocos de uma vez, sem liberar o buffer reservado.
    pub fn reset(self: *PoolAllocator) void {
        @memset(self.in_use, false);
        for (self.free_stack, 0..) |*slot, index| slot.* = index;
        self.free_count = self.free_stack.len;
    }

    pub fn available(self: *const PoolAllocator) usize {
        return self.free_count;
    }

    pub fn used(self: *const PoolAllocator) usize {
        return self.in_use.len - self.free_count;
    }

    pub fn capacity(self: *const PoolAllocator) usize {
        return self.in_use.len;
    }

    /// Geometria comparável sem depender da representação interna.
    pub fn matches(self: *const PoolAllocator, block_size: usize, block_align: u8) bool {
        const alignment: u8 = if (block_align == 0) 1 else block_align;
        return self.block_size == block_size and self.block_align == alignment;
    }

    /// Índice do bloco que começa em `pointer`, ou `null` se o ponteiro não for
    /// o início de um bloco deste pool.
    fn indexOf(self: *const PoolAllocator, pointer: usize) ?usize {
        const base = @intFromPtr(self.backing.ptr);
        if (pointer < base) return null;
        const offset = pointer - base;
        if (offset >= self.backing.len or offset % self.stride != 0) return null;
        return offset / self.stride;
    }

    fn blockingAt(self: *const PoolAllocator, index: usize) []u8 {
        return self.backing[index * self.stride ..][0..self.block_size];
    }
};

/// Registro de pools por geometria. Reutiliza um pool existente para a mesma
/// combinação de `block_size`/`block_align` e encaminha liberações ao pool dono.
/// Pools são alocados individualmente para que os ponteiros devolvidos por
/// `getOrCreate` permaneçam estáveis quando o registro cresce.
pub const PoolRegistry = struct {
    allocator: std.mem.Allocator,
    pools: std.ArrayList(*PoolAllocator) = .empty,

    pub fn init(allocator: std.mem.Allocator) PoolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PoolRegistry) void {
        for (self.pools.items) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        self.pools.deinit(self.allocator);
        self.pools = .empty;
    }

    /// Devolve o pool da geometria pedida; `block_count` só é usado ao criar.
    /// Um pool esgotado continua sendo o mesmo pool e reporta `OutOfMemory`.
    pub fn getOrCreate(self: *PoolRegistry, block_size: usize, block_count: usize, block_align: u8) PoolAllocator.Error!*PoolAllocator {
        if (self.find(block_size, block_align)) |pool| return pool;
        const pool = try self.allocator.create(PoolAllocator);
        errdefer self.allocator.destroy(pool);
        pool.* = try PoolAllocator.init(self.allocator, block_size, block_count, block_align);
        errdefer pool.deinit();
        try self.pools.append(self.allocator, pool);
        return pool;
    }

    pub fn find(self: *PoolRegistry, block_size: usize, block_align: u8) ?*PoolAllocator {
        for (self.pools.items) |pool| {
            if (pool.matches(block_size, block_align)) return pool;
        }
        return null;
    }

    /// Encaminha ao pool que contém o início do bloco. Blocos de outro
    /// allocator, ou de um pool já removido, são `InvalidFree`.
    pub fn free(self: *PoolRegistry, block: []u8) PoolAllocator.FreeError!void {
        for (self.pools.items) |pool| {
            if (pool.indexOf(@intFromPtr(block.ptr)) != null) return pool.free(block);
        }
        return error.InvalidFree;
    }

    pub fn count(self: *const PoolRegistry) usize {
        return self.pools.items.len;
    }

    /// Soma da capacidade e do uso de todos os pools registrados.
    pub fn totals(self: *const PoolRegistry) struct { capacity: usize, used: usize } {
        var capacity: usize = 0;
        var used: usize = 0;
        for (self.pools.items) |pool| {
            capacity += pool.capacity();
            used += pool.used();
        }
        return .{ .capacity = capacity, .used = used };
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

test "pool hands out distinct aligned blocks of exactly the configured size" {
    var pool = try PoolAllocator.init(std.testing.allocator, 64, 4, 16);
    defer pool.deinit();

    var blocks: [4][]u8 = undefined;
    for (&blocks, 0..) |*block, index| {
        block.* = try pool.alloc();
        try std.testing.expectEqual(@as(usize, 64), block.len);
        // Alinhamento é contrato de execução: o slice é []u8, a garantia vem
        // da geometria reservada em `init`.
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(block.ptr) % 16);
        @memset(block.*, @intCast(index + 1));
    }
    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expectEqual(@as(usize, 4), pool.used());
    // Blocos distintos: nenhum se sobrepõe ao padrão escrito no vizinho.
    for (blocks, 0..) |block, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), block[0]);
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), block[63]);
    }
    try std.testing.expectError(error.OutOfMemory, pool.alloc());
}

test "pool reuses the most recently freed block and counts payload bytes" {
    var pool = try PoolAllocator.init(std.testing.allocator, 32, 3, 8);
    defer pool.deinit();

    const first = try pool.alloc();
    const second = try pool.alloc();
    try std.testing.expect(@intFromPtr(first.ptr) != @intFromPtr(second.ptr));

    try pool.free(first);
    try std.testing.expectEqual(@as(usize, 2), pool.available());
    try std.testing.expectEqual(@as(usize, 1), pool.used());

    // Reuso real: o bloco liberado volta a ser entregue, não há reserva nova.
    const reused = try pool.alloc();
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    // Dois blocos em uso e um livre; o reuso não consumiu capacidade nova.
    try std.testing.expectEqual(@as(usize, 1), pool.available());
    try std.testing.expectEqual(@as(usize, 2), pool.used());
    try std.testing.expectEqual(@as(usize, 3), pool.tracker.stats.allocations);
    try std.testing.expectEqual(@as(usize, 96), pool.tracker.stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 1), pool.tracker.stats.deallocations);
    try std.testing.expectEqual(@as(usize, 32), pool.tracker.stats.total_freed);
}

test "pool rejects double, foreign, truncated and misaligned frees" {
    var pool = try PoolAllocator.init(std.testing.allocator, 16, 2, 8);
    defer pool.deinit();
    const block = try pool.alloc();
    try pool.free(block);
    const available_after = pool.available();

    // Dupla liberação do mesmo bloco não devolve capacidade extra.
    try std.testing.expectError(error.InvalidFree, pool.free(block));
    try std.testing.expectEqual(available_after, pool.available());
    // Comprimento diferente do bloco, inclusive menores.
    try std.testing.expectError(error.InvalidFree, pool.free(block[0..8]));
    // Ponteiro deslocado não é início de bloco, mesmo com comprimento certo.
    var shifted: [17]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFree, pool.free(shifted[1..][0..16]));
    // Bloco de outro allocator.
    var foreign: [16]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFree, pool.free(&foreign));
    try std.testing.expectEqual(available_after, pool.available());
    // As recusas não corromperam a pilha: o bloco liberado é reutilizável.
    const reused = try pool.alloc();
    try std.testing.expectEqual(@intFromPtr(block.ptr), @intFromPtr(reused.ptr));
    // Somente a liberação válida conta; as recusas não alteram o tracker.
    try std.testing.expectEqual(@as(usize, 1), pool.tracker.stats.deallocations);
}

test "pool reset returns every block without releasing the buffer" {
    var pool = try PoolAllocator.init(std.testing.allocator, 8, 3, 4);
    defer pool.deinit();
    const first = try pool.alloc();
    _ = try pool.alloc();
    _ = pool.alloc() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), pool.available());

    pool.reset();
    try std.testing.expectEqual(@as(usize, 3), pool.available());
    try std.testing.expectEqual(@as(usize, 0), pool.used());
    const reused = try pool.alloc();
    // A pilha entrega do topo para baixo; o importante é o bloco voltar ao
    // buffer reservado, sem nova reserva no allocator de origem.
    try std.testing.expectEqual(@as(usize, 2 * pool.stride), @intFromPtr(reused.ptr) - @intFromPtr(pool.backing.ptr));
    try std.testing.expectEqual(@as(usize, 3), pool.capacity());
    // `reset` não inventa eventos de liberação: só o `free` explícito conta.
    try std.testing.expectEqual(@as(usize, 0), pool.tracker.stats.deallocations);
    try std.testing.expectEqual(@as(usize, 4), pool.tracker.stats.allocations);
    try std.testing.expectEqual(@as(usize, 32), pool.tracker.stats.total_allocated);
    try std.testing.expect(@intFromPtr(first.ptr) != 0);
}

test "pool pads the stride so odd block sizes stay aligned and disjoint" {
    var pool = try PoolAllocator.init(std.testing.allocator, 5, 3, 16);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 16), pool.stride);

    // Sentinela: qualquer escrita fora do payload de 5 bytes aparece na folga.
    @memset(pool.backing, 0);
    const blocks = [3][]u8{ try pool.alloc(), try pool.alloc(), try pool.alloc() };
    var seen: [3]usize = undefined;
    for (blocks, 0..) |block, index| {
        const offset = @intFromPtr(block.ptr) - @intFromPtr(pool.backing.ptr);
        try std.testing.expectEqual(@as(usize, 0), offset % 16);
        try std.testing.expect(offset == 0 or offset == 16 or offset == 32);
        try std.testing.expectEqual(@as(usize, 5), block.len);
        seen[index] = offset;
        @memset(block, 0xff);
    }
    try std.testing.expect(seen[0] != seen[1] and seen[1] != seen[2] and seen[0] != seen[2]);
    // Escrever 5 bytes em cada bloco não alcança os 11 bytes de folga vizinhos.
    for (seen) |offset| {
        for (pool.backing[offset + 5 .. offset + 16]) |padding| try std.testing.expectEqual(@as(u8, 0), padding);
        try std.testing.expectEqual(@as(u8, 0xff), pool.backing[offset + 4]);
    }
    try pool.free(blocks[1]);
    const reused = try pool.alloc();
    try std.testing.expectEqual(@intFromPtr(blocks[1].ptr), @intFromPtr(reused.ptr));
}

test "pool rejects null and overflowing geometry before allocating" {
    try std.testing.expectError(error.InvalidGeometry, PoolAllocator.init(std.testing.allocator, 0, 4, 8));
    try std.testing.expectError(error.InvalidGeometry, PoolAllocator.init(std.testing.allocator, 8, 0, 8));
    // stride * block_count não cabe em usize.
    const half = std.math.maxInt(usize) / 2 + 1;
    try std.testing.expectError(error.InvalidGeometry, PoolAllocator.init(std.testing.allocator, half, 2, 8));
    // block_size + padding do alinhamento não cabe em usize.
    try std.testing.expectError(error.InvalidGeometry, PoolAllocator.init(std.testing.allocator, std.math.maxInt(usize), 1, 16));
}

fn poolAllocationProbe(allocator: std.mem.Allocator) !void {
    var pool = try PoolAllocator.init(allocator, 24, 2, 8);
    defer pool.deinit();
    const first = try pool.alloc();
    const second = try pool.alloc();
    @memset(first, 0x11);
    @memset(second, 0x22);
    try pool.free(first);
    const reused = try pool.alloc();
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    try pool.free(second);
    _ = try pool.alloc();
    try std.testing.expectError(error.OutOfMemory, pool.alloc());
}

test "pool releases partial allocations when the origin allocator fails" {
    // Injeta falha em cada reserva, inclusive nas três do próprio pool.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, poolAllocationProbe, .{});
}

test "registry reuses one pool per geometry" {
    var registry = PoolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try registry.getOrCreate(32, 4, 8);
    // `block_count` só vale na criação; a geometria é a chave de reuso.
    const again = try registry.getOrCreate(32, 99, 8);
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const wider = try registry.getOrCreate(64, 4, 8);
    try std.testing.expect(first != wider);
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const aligned = try registry.getOrCreate(32, 4, 16);
    try std.testing.expect(aligned != first);
    try std.testing.expectEqual(@as(usize, 3), registry.count());
    // Alinhamento 0 é normalizado para 1 nos dois lados da comparação.
    const single = try registry.getOrCreate(8, 1, 0);
    try std.testing.expectEqual(single, registry.find(8, 1).?);
    try std.testing.expect(registry.find(8, 16) == null);
}

test "registry routes free to the owning pool and reuses the block" {
    var registry = PoolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const small = try registry.getOrCreate(16, 2, 8);
    const large = try registry.getOrCreate(64, 2, 8);

    const small_block = try small.alloc();
    const large_block = try large.alloc();
    @memset(small_block, 0xaa);
    @memset(large_block, 0xbb);
    try std.testing.expectEqual(@as(usize, 1), small.used());
    try std.testing.expectEqual(@as(usize, 1), large.used());
    try std.testing.expectEqual(@as(usize, 1), small.available());
    try std.testing.expectEqual(@as(usize, 1), large.available());

    try registry.free(small_block);
    try registry.free(large_block);
    try std.testing.expectEqual(@as(usize, 0), small.used());
    try std.testing.expectEqual(@as(usize, 0), large.used());
    try std.testing.expectEqual(@as(usize, 2), small.available());
    try std.testing.expectEqual(@as(usize, 2), large.available());

    const small_again = try small.alloc();
    const large_again = try large.alloc();
    try std.testing.expectEqual(@intFromPtr(small_block.ptr), @intFromPtr(small_again.ptr));
    try std.testing.expectEqual(@intFromPtr(large_block.ptr), @intFromPtr(large_again.ptr));
    // O bloco pequeno continua com o conteúdo gravado: liberar não zerou nada.
    try std.testing.expectEqual(@as(u8, 0xaa), small_again[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), large_again[63]);
}

test "registry rejects blocks it does not own and reports totals" {
    var registry = PoolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const pool = try registry.getOrCreate(24, 3, 8);
    const block = try pool.alloc();
    _ = try pool.alloc();

    var foreign: [24]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFree, registry.free(&foreign));
    try std.testing.expectError(error.InvalidFree, registry.free(block[0..16]));
    // Ponteiro deslocado com o comprimento certo também é recusado.
    var shifted: [25]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFree, registry.free(shifted[1..][0..24]));

    const totals = registry.totals();
    try std.testing.expectEqual(@as(usize, 3), totals.capacity);
    try std.testing.expectEqual(@as(usize, 2), totals.used);
    try registry.free(block);
    try std.testing.expectEqual(@as(usize, 1), registry.totals().used);
}

test "registry deinit releases every pool it created" {
    var registry = PoolRegistry.init(std.testing.allocator);
    _ = try registry.getOrCreate(16, 2, 8);
    _ = try registry.getOrCreate(32, 2, 16);
    _ = try registry.getOrCreate(8, 8, 1);
    try std.testing.expectEqual(@as(usize, 3), registry.count());
    registry.deinit();
    // O allocator de teste acusa vazamento se algum pool sobreviver.
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 0), registry.totals().capacity);
}

test "general purpose allocator forwards the wrapped allocator" {
    var gpa = GeneralPurposeAllocator.init(std.testing.allocator);
    const forwarded = gpa.allocator();

    const bytes = try forwarded.alloc(u8, 4);
    defer forwarded.free(bytes);
    try std.testing.expectEqual(@as(usize, 4), bytes.len);
}
