const std = @import("std");

pub const LuaSandbox = struct {
    pub const Policy = struct {
        max_memory_bytes: usize,
    };

    pub fn apply(policy: Policy) void {
        _ = policy;
    }
};
