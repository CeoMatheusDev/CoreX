//! Test-only allocator that counts calls while delegating to a real allocator.
//! Production code never imports this file.
const std = @import("std");

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    bytes: isize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn resetCounters(self: *CountingAllocator) void {
        self.allocations = 0;
        self.frees = 0;
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.bytes += @intCast(len);
        return result;
    }

    fn resize(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.bytes += @as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len));
        return true;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.bytes += @as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len));
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        self.frees += 1;
        self.bytes -= @intCast(memory.len);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
