//! Shared deterministic Q16.16 multiplication for affine transforms.
const std = @import("std");

/// Round to nearest integer, with halfway cases away from zero. Using signed
/// truncating division avoids the negative bias of arithmetic right shifts.
pub fn mulQ16(a: i32, b: i32) i32 {
    return @intCast(roundedQ16(a, b));
}

/// Checked alternative for untrusted values, with identical rounding when the
/// result fits. The full i32 product plus the rounding offset fits in i64.
pub fn tryMulQ16(a: i32, b: i32) error{Overflow}!i32 {
    return std.math.cast(i32, roundedQ16(a, b)) orelse error.Overflow;
}

fn roundedQ16(a: i32, b: i32) i64 {
    const product = @as(i64, a) * @as(i64, b);
    const rounded = if (product >= 0) product + 32768 else product - 32768;
    return @divTrunc(rounded, 65536);
}

test "Q16 multiplication handles signs and symmetric ties" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 5), mulQ16(65536, 5));
    try testing.expectEqual(@as(i32, -5), mulQ16(65536, -5));
    try testing.expectEqual(@as(i32, 0), mulQ16(16384, -1));
    try testing.expectEqual(@as(i32, 1), mulQ16(32768, 1));
    try testing.expectEqual(@as(i32, -1), mulQ16(32768, -1));
    try testing.expectEqual(@as(i32, 2), mulQ16(98304, 1));
    try testing.expectEqual(@as(i32, -2), mulQ16(98304, -1));
}

test "checked Q16 multiplication preserves rounding and reports overflow" {
    const testing = std.testing;
    const samples = [_]i32{ std.math.minInt(i32), -65536, -32768, -1, 0, 1, 32768, 65536, std.math.maxInt(i32) };
    for (samples) |a| for (samples) |b| {
        const exact = roundedQ16(a, b);
        if (std.math.cast(i32, exact)) |expected| {
            try testing.expectEqual(expected, try tryMulQ16(a, b));
            try testing.expectEqual(mulQ16(a, b), try tryMulQ16(a, b));
        } else {
            try testing.expectError(error.Overflow, tryMulQ16(a, b));
        }
    };
    try testing.expectEqual(std.math.minInt(i32), try tryMulQ16(65536, std.math.minInt(i32)));
    try testing.expectEqual(std.math.maxInt(i32), try tryMulQ16(65536, std.math.maxInt(i32)));
}
