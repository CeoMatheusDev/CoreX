// Adaptador de allocator para o runtime Lua do core legado.
// Fornece a interface entre o allocator do host (page allocator, custom)
// e o modelo de gestão de memória interno do runtime Lua.
// Não interpreta Lua: apenas encaminha reservas e liberações.
const std = @import("std");

pub const LuaAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LuaAllocator {
        return .{ .allocator = allocator };
    }

    /// Nada é reservado em `init`, portanto nada é liberado aqui.
    /// O garbage collector Lua continua responsável pela memória do script.
    pub fn deinit(self: *LuaAllocator) void {
        _ = self;
    }

    pub fn alloc(self: *LuaAllocator, n: usize) ![]u8 {
        return try self.allocator.alloc(u8, n);
    }

    /// O comprimento vem do próprio slice; a contagem de bytes da API C do Lua
    /// é redundante aqui e não deve ser usada para truncar a liberação.
    pub fn free(self: *LuaAllocator, ptr: []u8) void {
        self.allocator.free(ptr);
    }
};

/// Contrato primordial oferecido pela camada de alocação.
pub const LuaAllocationOp = enum {
    /// Alloca `n` bytes na heap Lua, atomicamente via GC
    malloc,
    /// Reescreve o ponteiro com a alocação precedente, sem TLS
    realloc,
    /// Libera um bloco obtido anteriormente
    free,
    // Trunca um bloco liberado; a margem fora dos bounds nunca é endereçada.
    shrink,
};

test "allocator round trip returns exactly the requested length" {
    var lua = LuaAllocator.init(std.testing.allocator);
    defer lua.deinit();

    const block = try lua.alloc(12);
    @memset(block, 0x5a);
    try std.testing.expectEqual(@as(usize, 12), block.len);
    try std.testing.expectEqual(@as(u8, 0x5a), block[11]);

    lua.free(block);
}

test "zero-length allocation is accepted and freed" {
    var lua = LuaAllocator.init(std.testing.allocator);
    defer lua.deinit();

    const empty = try lua.alloc(0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    lua.free(empty);
}

test "allocation operations stay a closed four-value contract" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(LuaAllocationOp).@"enum".field_names.len);
    try std.testing.expectEqual(LuaAllocationOp.malloc, @as(LuaAllocationOp, .malloc));
    try std.testing.expectEqualStrings("shrink", @tagName(LuaAllocationOp.shrink));
}
