//! Reusable application contracts; no dependency on Editor UI or Runtime state.
pub const cli = @import("cli.zig");
pub const logging = @import("logging.zig");
pub const jsonl = @import("jsonl.zig");
pub const distribution = @import("distribution.zig");
pub const fingerprint = @import("fingerprint.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const child_process = @import("platform_ext/process.zig");
pub const scope = @import("scope.zig");
pub const project = @import("project.zig");
pub const presets = @import("presets.zig");
pub const validation = @import("validation.zig");
pub const graphics_abi = @import("graphics_abi.zig");
pub const limits = @import("limits.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("contract_tests.zig");
}
