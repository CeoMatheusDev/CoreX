//! 2D affine transform hierarchy: local matrix composed with parent's world
//! matrix. Extends `transform.zig` with rotation and scale, using fixed-point
//! integer math (no floats, deterministic across platforms).
//!
//! Matrix layout (row-major 2x3 affine):
//!   | a c tx |
//!   | b d ty |
//! Point transform: x' = a*x + c*y + tx ; y' = b*x + d*y + ty
//!
//! Rotation uses milliradians (mrad) as i32. sin/cos via lookup-free
//! integer approximation is avoided — we use std.math.sin/cos on floats
//! converted to fixed-point, but only at authoring time, never in the hot
//! propagation loop. For full determinism across platforms, angles use a
//! precomputed table of 360 degrees (1-degree resolution) in fixed-point.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const hierarchy = @import("hierarchy.zig");

/// Fixed-point scale: 1.0 = 65536.
pub const fixed_one: i32 = 65536;

/// 2x3 affine matrix in fixed-point (Q16.16 for a/b/c/d, Q16.16 for tx/ty).
pub const Mat2x3 = struct {
    a: i32 = fixed_one,
    b: i32 = 0,
    c: i32 = 0,
    d: i32 = fixed_one,
    tx: i32 = 0,
    ty: i32 = 0,

    pub fn identity() Mat2x3 {
        return .{};
    }

    /// Translation matrix.
    pub fn translation(x: i32, y: i32) Mat2x3 {
        return .{ .tx = x, .ty = y };
    }

    /// Scale matrix (sx, sy in Q16.16).
    pub fn scale(sx: i32, sy: i32) Mat2x3 {
        return .{ .a = sx, .d = sy };
    }

    /// Rotation matrix. `angle_deg` is integer degrees (0-359).
    /// Uses a 360-entry lookup table for sin/cos in Q16.16.
    pub fn rotation(angle_deg: i32) Mat2x3 {
        const three_sixty: i32 = 360;
        var deg: i32 = @rem(angle_deg, three_sixty);
        if (deg < 0) deg += three_sixty;
        const idx: usize = @intCast(deg);
        const s = sin_table[idx];
        const c = cos_table[idx];
        return .{ .a = c, .b = s, .c = -s, .d = c };
    }

    /// Compose: self * other (apply other first, then self).
    pub fn mul(self: Mat2x3, other: Mat2x3) Mat2x3 {
        return .{
            .a = mulFixed(self.a, other.a) + mulFixed(self.c, other.b),
            .b = mulFixed(self.b, other.a) + mulFixed(self.d, other.b),
            .c = mulFixed(self.a, other.c) + mulFixed(self.c, other.d),
            .d = mulFixed(self.b, other.c) + mulFixed(self.d, other.d),
            .tx = mulFixed(self.a, other.tx) + mulFixed(self.c, other.ty) + self.tx,
            .ty = mulFixed(self.b, other.tx) + mulFixed(self.d, other.ty) + self.ty,
        };
    }

    /// Transform a point.
    pub fn applyPoint(self: Mat2x3, x: i32, y: i32) struct { x: i32, y: i32 } {
        return .{
            .x = mulFixed(self.a, x) + mulFixed(self.c, y) + self.tx,
            .y = mulFixed(self.b, x) + mulFixed(self.d, y) + self.ty,
        };
    }
};

/// Q16.16 multiply: (a * b) >> 16 with rounding.
fn mulFixed(a: i32, b: i32) i32 {
    const wide: i64 = @as(i64, a) * @as(i64, b);
    const half: i64 = 32768;
    const rounded = if (wide >= 0) wide + half else wide - half;
    return @intCast(rounded >> 16);
}

/// Component: local 2D affine transform relative to parent.
pub const LocalTransform2D = struct {
    matrix: Mat2x3 = .identity(),
};

/// Component: computed world-space 2D affine transform.
pub const WorldTransform2D = struct {
    matrix: Mat2x3 = .identity(),
};

/// Propagates local 2D transforms through the hierarchy.
/// world = parent.world * local ; root: world = local.
pub fn propagateTransforms2D(comptime WorldT: type, world: *WorldT) void {
    const hw = world.highWater();
    var pass: u32 = 0;
    while (pass < hw) : (pass += 1) {
        var index: u32 = 0;
        while (index < hw) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            const local = world.getConst(LocalTransform2D, entity) orelse continue;
            const parent_entity = hierarchy.getParent(WorldT, world, entity);
            const world_matrix: Mat2x3 = if (parent_entity) |p| blk: {
                const pw = world.getConst(WorldTransform2D, p) orelse break :blk local.matrix;
                break :blk pw.matrix.mul(local.matrix);
            } else local.matrix;
            if (world.get(WorldTransform2D, entity)) |ew| {
                ew.matrix = world_matrix;
            } else {
                world.add(WorldTransform2D, entity, .{ .matrix = world_matrix }) catch {};
            }
        }
    }
}

// --- sin/cos lookup tables (Q16.16, 1-degree resolution, 0..359) ---
const sin_table: [360]i32 = blk: {
    var t: [360]i32 = undefined;
    var i: usize = 0;
    while (i < 360) : (i += 1) {
        const rad = @as(f64, @floatFromInt(i)) * std.math.pi / 180.0;
        t[i] = @intFromFloat(@round(std.math.sin(rad) * 65536.0));
    }
    break :blk t;
};

const cos_table: [360]i32 = blk: {
    var t: [360]i32 = undefined;
    var i: usize = 0;
    while (i < 360) : (i += 1) {
        const rad = @as(f64, @floatFromInt(i)) * std.math.pi / 180.0;
        t[i] = @intFromFloat(@round(std.math.cos(rad) * 65536.0));
    }
    break :blk t;
};

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");
const world_mod = @import("world.zig");

const T2DStores = struct {
    parent: sparse_set.SparseSet(hierarchy.Parent),
    children: sparse_set.SparseSet(hierarchy.Children),
    local: sparse_set.SparseSet(LocalTransform2D),
    world_t: sparse_set.SparseSet(WorldTransform2D),
};

const TestWorld = world_mod.World(T2DStores);

test "identity transform stays identity" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(LocalTransform2D, e, .{ .matrix = .identity() });
    propagateTransforms2D(TestWorld, &world);
    const w = world.getConst(WorldTransform2D, e).?.matrix;
    try testing.expectEqual(fixed_one, w.a);
    try testing.expectEqual(@as(i32, 0), w.tx);
}

test "translation composes through hierarchy" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    const p = try world.create();
    try world.add(LocalTransform2D, p, .{ .matrix = .translation(100, 0) });
    const c = try world.create();
    try world.add(LocalTransform2D, c, .{ .matrix = .translation(5, 7) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, p, c);
    propagateTransforms2D(TestWorld, &world);
    const w = world.getConst(WorldTransform2D, c).?.matrix;
    try testing.expectEqual(@as(i32, 105), w.tx);
    try testing.expectEqual(@as(i32, 7), w.ty);
}

test "rotation 90 degrees maps (1,0) to (0,1)" {
    const r = Mat2x3.rotation(90);
    const p = r.applyPoint(fixed_one, 0);
    try testing.expectEqual(@as(i32, 0), p.x);
    try testing.expectEqual(fixed_one, p.y);
}

test "scale doubles coordinates" {
    const s = Mat2x3.scale(fixed_one * 2, fixed_one * 2);
    const p = s.applyPoint(10, 20);
    try testing.expectEqual(@as(i32, 20), p.x);
    try testing.expectEqual(@as(i32, 40), p.y);
}

test "rotation then translation through hierarchy" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    const p = try world.create();
    try world.add(LocalTransform2D, p, .{ .matrix = .translation(100, 0) });
    const c = try world.create();
    try world.add(LocalTransform2D, c, .{ .matrix = .rotation(90) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, p, c);
    propagateTransforms2D(TestWorld, &world);
    // Child world = parent.translation * rotation(90).
    // Point (1,0) under child world: rotation gives (0,1), then +100 x.
    const w = world.getConst(WorldTransform2D, c).?.matrix;
    const pt = w.applyPoint(fixed_one, 0);
    try testing.expectEqual(@as(i32, 100), pt.x);
    try testing.expectEqual(fixed_one, pt.y);
}
