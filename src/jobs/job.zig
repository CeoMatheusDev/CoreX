const std = @import("std");

pub const Job = struct {
    name: []const u8,
    func: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};
