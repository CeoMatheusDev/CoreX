// Lua allocator adapter for Zig allocators.
// Fornece a interface entre o allocator do host (page allocator, custom)
// e o modelo de gestão de memória interno do runtime Lua.

pub const LuaAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LuaAllocator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LuaAllocator) void {
        // não há vazamento: o garbage collector gerencia a memória Lua
    }

    pub fn alloc(self: *LuaAllocator, n: usize) ![]u8 {
        return try self.allocator.alloc(u8, n);
    }

    pub fn free(self: *LuaAllocator, ptr: []void, bytes: usize) void {
        self.allocator.free(ptr, bytes);
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
    /// Trunca um bloco liberado comoAllocation a margem fora dos bounds do bloco libertado
};
