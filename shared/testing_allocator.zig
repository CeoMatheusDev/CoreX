//! Test-only OOM matrix. Never changes the applications' allocator policy.
//! OS-dependent in-place resize/remap success changes allocation counts (seen
//! on native macOS). Force growth through alloc so every failure index is stable.
const std = @import("std");

const NoResize = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *NoResize) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

pub fn checkAllFailures(comptime probe: anytype, extra: anytype) !void {
    var backing: NoResize = .{ .backing = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(backing.allocator(), probe, extra);
}
