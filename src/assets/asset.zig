const std = @import("std");

pub const Asset = struct {
    path: []const u8,
    loaded: bool = false,
};

pub const AssetPipeline = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AssetPipeline {
        return .{ .allocator = allocator };
    }

    pub fn load(self: *AssetPipeline, path: []const u8) !Asset {
        _ = self;
        return .{ .path = path, .loaded = true };
    }
};
