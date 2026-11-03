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
const fixed = @import("fixed.zig");

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

    /// Compose: self * other. The legacy API keeps its unchecked arithmetic.
    /// Use `tryMul` with externally supplied or otherwise unbounded matrices.
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        return self.mulImpl(other, false) catch unreachable;
    }

    /// Checked composition, using the same per-product Q16.16 rounding and
    /// left-to-right addition as `mul`. Each product and intermediate sum must
    /// fit i32, even when a later term would cancel an overflow.
    pub fn tryMul(self: Mat4, other: Mat4) error{TransformOverflow}!Mat4 {
        return self.mulImpl(other, true);
    }

    fn mulImpl(self: Mat4, o: Mat4, comptime checked: bool) error{TransformOverflow}!Mat4 {
        return .{
            .m00 = try dot3(checked, self.m00, self.m01, self.m02, o.m00, o.m10, o.m20, 0),
            .m01 = try dot3(checked, self.m00, self.m01, self.m02, o.m01, o.m11, o.m21, 0),
            .m02 = try dot3(checked, self.m00, self.m01, self.m02, o.m02, o.m12, o.m22, 0),
            .m03 = try dot3(checked, self.m00, self.m01, self.m02, o.m03, o.m13, o.m23, self.m03),
            .m10 = try dot3(checked, self.m10, self.m11, self.m12, o.m00, o.m10, o.m20, 0),
            .m11 = try dot3(checked, self.m10, self.m11, self.m12, o.m01, o.m11, o.m21, 0),
            .m12 = try dot3(checked, self.m10, self.m11, self.m12, o.m02, o.m12, o.m22, 0),
            .m13 = try dot3(checked, self.m10, self.m11, self.m12, o.m03, o.m13, o.m23, self.m13),
            .m20 = try dot3(checked, self.m20, self.m21, self.m22, o.m00, o.m10, o.m20, 0),
            .m21 = try dot3(checked, self.m20, self.m21, self.m22, o.m01, o.m11, o.m21, 0),
            .m22 = try dot3(checked, self.m20, self.m21, self.m22, o.m02, o.m12, o.m22, 0),
            .m23 = try dot3(checked, self.m20, self.m21, self.m22, o.m03, o.m13, o.m23, self.m23),
        };
    }

    /// Transform a 3D point. Returns (x, y, z) in Q16.16.
    pub fn applyPoint(self: Mat4, x: i32, y: i32, z: i32) struct { x: i32, y: i32, z: i32 } {
        const point = self.applyPointImpl(x, y, z, false) catch unreachable;
        return .{ .x = point.x, .y = point.y, .z = point.z };
    }

    /// Checked alternative to `applyPoint`, with the same rounding semantics.
    pub fn tryApplyPoint(self: Mat4, x: i32, y: i32, z: i32) error{TransformOverflow}!struct { x: i32, y: i32, z: i32 } {
        const point = try self.applyPointImpl(x, y, z, true);
        return .{ .x = point.x, .y = point.y, .z = point.z };
    }

    fn applyPointImpl(self: Mat4, x: i32, y: i32, z: i32, comptime checked: bool) error{TransformOverflow}!struct { x: i32, y: i32, z: i32 } {
        return .{
            .x = try dot3(checked, self.m00, self.m01, self.m02, x, y, z, self.m03),
            .y = try dot3(checked, self.m10, self.m11, self.m12, x, y, z, self.m13),
            .z = try dot3(checked, self.m20, self.m21, self.m22, x, y, z, self.m23),
        };
    }
};

// The legacy and checked entry points share the exact expression order and
// per-product rounding; `checked` is resolved at comptime on the hot path.
fn dot3(comptime checked: bool, a0: i32, a1: i32, a2: i32, b0: i32, b1: i32, b2: i32, offset: i32) error{TransformOverflow}!i32 {
    const p0 = try product(checked, a0, b0);
    const p1 = try product(checked, a1, b1);
    const p2 = try product(checked, a2, b2);
    return try add(checked, try add(checked, try add(checked, p0, p1), p2), offset);
}

fn product(comptime checked: bool, a: i32, b: i32) error{TransformOverflow}!i32 {
    if (checked) return fixed.tryMulQ16(a, b) catch error.TransformOverflow;
    return fixed.mulQ16(a, b);
}

fn add(comptime checked: bool, a: i32, b: i32) error{TransformOverflow}!i32 {
    if (checked) return std.math.add(i32, a, b) catch error.TransformOverflow;
    return a + b;
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
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
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
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
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

test "3D identity composition preserves negative values exactly" {
    const transform = Mat4{ .m00 = -65536, .m01 = -1234, .m03 = -5, .m13 = -17, .m23 = -3 };
    try testing.expectEqualDeep(transform, Mat4.identity().mul(transform));
    try testing.expectEqual(@as(i32, -5), Mat4.identity().applyPoint(-5, 0, 0).x);
}

test "checked 3D operations match existing arithmetic for bounded inputs" {
    var seed: u32 = 17;
    for (0..256) |_| {
        var a = Mat4.identity();
        var b = Mat4.identity();
        inline for (@typeInfo(Mat4).@"struct".field_names) |name| {
            seed = seed *% 1664525 +% 1013904223;
            @field(a, name) = @as(i32, @intCast(seed % 131073)) - 65536;
            seed = seed *% 1664525 +% 1013904223;
            @field(b, name) = @as(i32, @intCast(seed % 131073)) - 65536;
        }
        try testing.expectEqualDeep(a.mul(b), try a.tryMul(b));
        const old_point = a.applyPoint(-7, 2, 65536);
        const checked_point = try a.tryApplyPoint(-7, 2, 65536);
        try testing.expectEqual(old_point.x, checked_point.x);
        try testing.expectEqual(old_point.y, checked_point.y);
        try testing.expectEqual(old_point.z, checked_point.z);

        // Independent row/column oracle catches field-index mistakes. Each
        // product rounds separately, matching the established Q16 contract.
        const left = [_][4]i32{ .{ a.m00, a.m01, a.m02, a.m03 }, .{ a.m10, a.m11, a.m12, a.m13 }, .{ a.m20, a.m21, a.m22, a.m23 } };
        const right = [_][4]i32{ .{ b.m00, b.m01, b.m02, b.m03 }, .{ b.m10, b.m11, b.m12, b.m13 }, .{ b.m20, b.m21, b.m22, b.m23 } };
        const result = try a.tryMul(b);
        const actual = [_][4]i32{ .{ result.m00, result.m01, result.m02, result.m03 }, .{ result.m10, result.m11, result.m12, result.m13 }, .{ result.m20, result.m21, result.m22, result.m23 } };
        for (0..3) |row| for (0..4) |col| {
            var expected: i64 = if (col == 3) left[row][3] else 0;
            for (0..3) |k| expected += fixed.mulQ16(left[row][k], right[k][col]);
            try testing.expectEqual(expected, @as(i64, actual[row][col]));
        };
    }
    const rotated = try Mat4.rotationZ(90).tryMul(Mat4.translation(fixed_one, 0, 0));
    try testing.expectEqual(@as(i32, 0), rotated.m03);
    try testing.expectEqual(fixed_one, rotated.m13);
}

test "checked 3D arithmetic handles boundaries and detects each overflow" {
    const lo = std.math.minInt(i32);
    const hi = std.math.maxInt(i32);
    const boundary = Mat4.translation(lo, hi, 0);
    try testing.expectEqualDeep(boundary, try Mat4.identity().tryMul(boundary));
    try testing.expectEqual(lo, (try Mat4.identity().tryApplyPoint(lo, hi, 0)).x);

    try testing.expectError(error.TransformOverflow, (Mat4{ .m00 = hi }).tryMul(.{ .m00 = hi }));
    try testing.expectError(error.TransformOverflow, (Mat4{ .m00 = fixed_one, .m01 = fixed_one }).tryMul(.{ .m00 = hi, .m10 = 1 }));
    try testing.expectError(error.TransformOverflow, Mat4.translation(hi, 0, 0).tryMul(Mat4.translation(1, 0, 0)));
    try testing.expectError(error.TransformOverflow, Mat4.translation(lo, 0, 0).tryMul(Mat4.translation(-1, 0, 0)));
    try testing.expectError(error.TransformOverflow, Mat4.translation(hi, 0, 0).tryApplyPoint(1, 0, 0));
    // Overflowing intermediate sums are not silently cancelled by later terms.
    try testing.expectError(error.TransformOverflow, (Mat4{ .m00 = fixed_one, .m01 = fixed_one, .m02 = fixed_one }).tryMul(.{ .m00 = hi, .m10 = 1, .m20 = -1 }));
    try testing.expectEqual(@as(i32, -1), (try (Mat4{ .m00 = 32768 }).tryApplyPoint(-1, 0, 0)).x);
}
