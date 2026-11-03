//! 3D affine transform hierarchy: 4x4 matrix in fixed-point Q16.16.
//! Follows the same pattern as `transform2d.zig` but for 3D (ADR-003 scope:
//! scene_3d). Deterministic integer math, no floats in the hot path.
//!
//! Matrix layout (row-major 4x4, affine bottom row 0 0 0 1):
//!   | m00 m01 m02 m03 |
//!   | m10 m11 m12 m13 |
//!   | m20 m21 m22 m23 |
//!   |  0   0   0   1  |
//! Point: x' = m00*x + m01*y + m02*z + m03, etc.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const hierarchy = @import("hierarchy.zig");

pub const fixed_one: i32 = 65536;

/// 4x4 affine matrix in Q16.16 fixed-point. Only 12 fields stored (bottom row
/// is implicit 0 0 0 1).
pub const Mat4 = struct {
    m00: i32 = fixed_one,
    m01: i32 = 0,
    m02: i32 = 0,
    m03: i32 = 0,
    m10: i32 = 0,
    m11: i32 = fixed_one,
    m12: i32 = 0,
    m13: i32 = 0,
    m20: i32 = 0,
    m21: i32 = 0,
    m22: i32 = fixed_one,
    m23: i32 = 0,

    pub fn identity() Mat4 {
        return .{};
    }

    pub fn translation(x: i32, y: i32, z: i32) Mat4 {
        return .{ .m03 = x, .m13 = y, .m23 = z };
    }

    pub fn scale(sx: i32, sy: i32, sz: i32) Mat4 {
        return .{ .m00 = sx, .m11 = sy, .m22 = sz };
    }

    /// Rotation around X axis, angle in integer degrees (LUT 0..359).
    pub fn rotationX(angle_deg: i32) Mat4 {
        const s = sinLut(angle_deg);
        const c = cosLut(angle_deg);
        return .{ .m11 = c, .m12 = -s, .m21 = s, .m22 = c };
    }

    /// Rotation around Y axis.
    pub fn rotationY(angle_deg: i32) Mat4 {
        const s = sinLut(angle_deg);
        const c = cosLut(angle_deg);
        return .{ .m00 = c, .m02 = s, .m20 = -s, .m22 = c };
    }

    /// Rotation around Z axis.
    pub fn rotationZ(angle_deg: i32) Mat4 {
        const s = sinLut(angle_deg);
        const c = cosLut(angle_deg);
        return .{ .m00 = c, .m01 = -s, .m10 = s, .m11 = c };
    }

    /// Compose: self * other.
    pub fn mul(self: Mat4, o: Mat4) Mat4 {
        return .{
            .m00 = mulF(self.m00, o.m00) + mulF(self.m01, o.m10) + mulF(self.m02, o.m20),
            .m01 = mulF(self.m00, o.m01) + mulF(self.m01, o.m11) + mulF(self.m02, o.m21),
            .m02 = mulF(self.m00, o.m02) + mulF(self.m01, o.m12) + mulF(self.m02, o.m22),
            .m03 = mulF(self.m00, o.m03) + mulF(self.m01, o.m13) + mulF(self.m02, o.m23) + self.m03,
            .m10 = mulF(self.m10, o.m00) + mulF(self.m11, o.m10) + mulF(self.m12, o.m20),
            .m11 = mulF(self.m10, o.m01) + mulF(self.m11, o.m11) + mulF(self.m12, o.m21),
            .m12 = mulF(self.m10, o.m02) + mulF(self.m11, o.m12) + mulF(self.m12, o.m22),
            .m13 = mulF(self.m10, o.m03) + mulF(self.m11, o.m13) + mulF(self.m12, o.m23) + self.m13,
            .m20 = mulF(self.m20, o.m00) + mulF(self.m21, o.m10) + mulF(self.m22, o.m20),
            .m21 = mulF(self.m20, o.m01) + mulF(self.m21, o.m11) + mulF(self.m22, o.m21),
            .m22 = mulF(self.m20, o.m02) + mulF(self.m21, o.m12) + mulF(self.m22, o.m22),
            .m23 = mulF(self.m20, o.m03) + mulF(self.m21, o.m13) + mulF(self.m22, o.m23) + self.m23,
        };
    }

    /// Transform a 3D point. Returns (x, y, z) in Q16.16.
    pub fn applyPoint(self: Mat4, x: i32, y: i32, z: i32) struct { x: i32, y: i32, z: i32 } {
        return .{
            .x = mulF(self.m00, x) + mulF(self.m01, y) + mulF(self.m02, z) + self.m03,
            .y = mulF(self.m10, x) + mulF(self.m11, y) + mulF(self.m12, z) + self.m13,
            .z = mulF(self.m20, x) + mulF(self.m21, y) + mulF(self.m22, z) + self.m23,
        };
    }
};

fn mulF(a: i32, b: i32) i32 {
    const wide: i64 = @as(i64, a) * @as(i64, b);
    const half: i64 = 32768;
    const rounded = if (wide >= 0) wide + half else wide - half;
    return @intCast(rounded >> 16);
}

fn normAngle(angle_deg: i32) usize {
    const three_sixty: i32 = 360;
    var deg: i32 = @rem(angle_deg, three_sixty);
    if (deg < 0) deg += three_sixty;
    return @intCast(deg);
}

fn sinLut(angle_deg: i32) i32 {
    return sin_table[normAngle(angle_deg)];
}

fn cosLut(angle_deg: i32) i32 {
    return cos_table[normAngle(angle_deg)];
}

/// Local 3D transform component.
pub const LocalTransform3D = struct {
    matrix: Mat4 = .identity(),
};

/// Computed world 3D transform component.
pub const WorldTransform3D = struct {
    matrix: Mat4 = .identity(),
};

/// Propagates local 3D transforms through the hierarchy.
pub fn propagateTransforms3D(comptime WorldT: type, world: *WorldT) void {
    const hw = world.highWater();
    var pass: u32 = 0;
    while (pass < hw) : (pass += 1) {
        var index: u32 = 0;
        while (index < hw) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            const local = world.getConst(LocalTransform3D, entity) orelse continue;
            const parent_entity = hierarchy.getParent(WorldT, world, entity);
            const world_matrix: Mat4 = if (parent_entity) |p| blk: {
                const pw = world.getConst(WorldTransform3D, p) orelse break :blk local.matrix;
                break :blk pw.matrix.mul(local.matrix);
            } else local.matrix;
            if (world.get(WorldTransform3D, entity)) |ew| {
                ew.matrix = world_matrix;
            } else {
                world.add(WorldTransform3D, entity, .{ .matrix = world_matrix }) catch {};
            }
        }
    }
}

// --- LUTs (Q16.16, 1-degree resolution) ---
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

const T3DStores = struct {
    parent: sparse_set.SparseSet(hierarchy.Parent),
    children: sparse_set.SparseSet(hierarchy.Children),
    local: sparse_set.SparseSet(LocalTransform3D),
    world_t: sparse_set.SparseSet(WorldTransform3D),
};

const TestWorld = world_mod.World(T3DStores);

test "identity 3D transform" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(LocalTransform3D, e, .{ .matrix = .identity() });
    propagateTransforms3D(TestWorld, &world);
    const w = world.getConst(WorldTransform3D, e).?.matrix;
    try testing.expectEqual(fixed_one, w.m00);
    try testing.expectEqual(@as(i32, 0), w.m03);
}

test "3D translation composes through hierarchy" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    const p = try world.create();
    try world.add(LocalTransform3D, p, .{ .matrix = .translation(10, 20, 30) });
    const c = try world.create();
    try world.add(LocalTransform3D, c, .{ .matrix = .translation(1, 2, 3) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, p, c);
    propagateTransforms3D(TestWorld, &world);
    const w = world.getConst(WorldTransform3D, c).?.matrix;
    try testing.expectEqual(@as(i32, 11), w.m03);
    try testing.expectEqual(@as(i32, 22), w.m13);
    try testing.expectEqual(@as(i32, 33), w.m23);
}

test "rotationZ 90 maps (1,0,0) to (0,1,0)" {
    const r = Mat4.rotationZ(90);
    const p = r.applyPoint(fixed_one, 0, 0);
    try testing.expectEqual(@as(i32, 0), p.x);
    try testing.expectEqual(fixed_one, p.y);
    try testing.expectEqual(@as(i32, 0), p.z);
}

test "rotationX 90 maps (0,1,0) to (0,0,1)" {
    const r = Mat4.rotationX(90);
    const p = r.applyPoint(0, fixed_one, 0);
    try testing.expectEqual(@as(i32, 0), p.x);
    try testing.expectEqual(@as(i32, 0), p.y);
    try testing.expectEqual(fixed_one, p.z);
}

test "scale 3D" {
    const s = Mat4.scale(fixed_one * 2, fixed_one * 3, fixed_one);
    const p = s.applyPoint(10, 10, 10);
    try testing.expectEqual(@as(i32, 20), p.x);
    try testing.expectEqual(@as(i32, 30), p.y);
    try testing.expectEqual(@as(i32, 10), p.z);
}
