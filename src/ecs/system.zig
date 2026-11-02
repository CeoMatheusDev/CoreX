//! Contrato de sistema do ECS legado.
//! Zig 0.17.0 não possui mais a palavra-chave `interface`; o mesmo contrato
//! (update/init sobre o próprio sistema) é expresso como tabela de funções
//! com contexto opaco. Isto não registra sistemas nem os executa: o World
//! legado ainda não possui scheduler.

const std = @import("std");

/// Chamadas despachadas por um `System`. O contexto deve permanecer válido
/// enquanto o `System` for usado e deve apontar para o tipo concreto.
pub const System = struct {
    context: *anyopaque,
    update_fn: *const fn (context: *anyopaque, dt: f32) void,
    init_fn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!void,

    /// Encaminha `dt` ao sistema concreto. Não aloca e não retém `dt`.
    pub fn update(self: System, dt: f32) void {
        self.update_fn(self.context, dt);
    }

    /// Inicializa o sistema concreto com o allocator informado.
    /// Erros do sistema são propagados sem tradução.
    pub fn init(self: System, allocator: std.mem.Allocator) anyerror!void {
        return self.init_fn(self.context, allocator);
    }
};

const TestSystem = struct {
    updates: usize = 0,
    last_dt: f32 = 0,
    initialized: bool = false,
    freed: bool = false,

    fn update(context: *anyopaque, dt: f32) void {
        const self: *TestSystem = @ptrCast(@alignCast(context));
        self.updates += 1;
        self.last_dt = dt;
    }

    fn init(context: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *TestSystem = @ptrCast(@alignCast(context));
        self.initialized = true;
        self.freed = false;
        _ = allocator;
    }

    fn failingInit(context: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = context;
        _ = allocator;
        return error.Unavailable;
    }

    fn asSystem(self: *TestSystem) System {
        return .{
            .context = self,
            .update_fn = update,
            .init_fn = init,
        };
    }
};

test "system dispatches update to the concrete context" {
    var concrete = TestSystem{};
    const system = concrete.asSystem();

    system.update(0.25);
    system.update(1.5);

    try std.testing.expectEqual(@as(usize, 2), concrete.updates);
    try std.testing.expectEqual(@as(f32, 1.5), concrete.last_dt);
}

test "system dispatches init with the given allocator" {
    var concrete = TestSystem{};
    const system = concrete.asSystem();

    try system.init(std.testing.allocator);
    try std.testing.expect(concrete.initialized);
}

test "system propagates init errors unchanged" {
    var concrete = TestSystem{};
    const system = System{
        .context = &concrete,
        .update_fn = TestSystem.update,
        .init_fn = TestSystem.failingInit,
    };

    try std.testing.expectError(error.Unavailable, system.init(std.testing.allocator));
    try std.testing.expect(!concrete.initialized);
}
