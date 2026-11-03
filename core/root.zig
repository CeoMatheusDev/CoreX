//! CoreX Core: the dependency-free foundation shared by Editor and Runtime.
//!
//! Scope of this library today: application lifecycle, explicit subsystem
//! ownership and deterministic teardown. It links no graphics, no windowing and
//! no external package, so both applications can depend on it without inheriting
//! platform or GPU decisions.
//!
//! Deliberately absent (see docs/ADR-006): job system, event bus, memory
//! management and the platform/native-handle contract. Each of those needs a
//! real consumer before it belongs here.
pub const lifecycle = @import("lifecycle.zig");
pub const subsystem = @import("subsystem.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("lifecycle.zig");
    _ = @import("subsystem.zig");
}
