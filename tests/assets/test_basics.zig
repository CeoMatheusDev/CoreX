const std = @import("std");
const AssetPipeline = @import("../../src/assets/asset.zig").AssetPipeline;

pub fn main() !void {
    var p = AssetPipeline.init(std.heap.page_allocator);
    defer _ = p;
    var a = try p.load("textures/default.png");
    std.debug.assert(a.loaded);
    std.debug.print("Asset OK\n", .{});
}
