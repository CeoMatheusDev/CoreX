//! Test-only allocator that counts calls while delegating to a real allocator.
//! Production code never imports this file.
const std = @import("std");

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    allocation_attempts: usize = 0,
    resize_attempts: usize = 0,
    remap_attempts: usize = 0,
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
        self.allocation_attempts = 0;
        self.resize_attempts = 0;
        self.remap_attempts = 0;
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        self.allocation_attempts += 1;
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.bytes += @intCast(len);
        return result;
    }

    fn resize(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        self.resize_attempts += 1;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.bytes += @as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len));
        return true;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(pointer));
        self.remap_attempts += 1;
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

test "counts allocation resize and remap attempts even when they fail" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var counter = CountingAllocator{ .backing = failing.allocator() };
    const allocator = counter.allocator();
    const buffer = try allocator.alloc(u8, 16);
    defer allocator.free(buffer);
    counter.resetCounters();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4));
    try testing.expect(!allocator.resize(buffer, 32));
    try testing.expect(allocator.remap(buffer, 32) == null);
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(usize, 1), counter.allocation_attempts);
    try testing.expectEqual(@as(usize, 1), counter.resize_attempts);
    try testing.expectEqual(@as(usize, 1), counter.remap_attempts);
}
