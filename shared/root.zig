//! Reusable application contracts; no dependency on Editor UI or Runtime state.
pub const project = @import("project.zig");
pub const presets = @import("presets.zig");
pub const validation = @import("validation.zig");
pub const graphics_abi = @import("graphics_abi.zig");
pub const limits = @import("limits.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("contract_tests.zig");
}
