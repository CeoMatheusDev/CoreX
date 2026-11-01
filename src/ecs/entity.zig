// ECS — Arquitetura Orientada a Dados para CoreX
// Contrato claro, ownership explícito, zero overhead de abstração.

pub const Entity = struct {
    id: u32,

    pub fn init(id: u32) Entity {
        return .{ .id = id };
    }
};
