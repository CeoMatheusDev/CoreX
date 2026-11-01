const std = @import("std");

pub const Scene = struct {
    name: []const u8,
    entities: []const u32,
};
