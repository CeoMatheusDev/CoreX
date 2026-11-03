//! Shared deterministic Q16.16 multiplication for affine transforms.
const std = @import("std");

/// Round to nearest integer, with halfway cases away from zero. Using signed
/// truncating division avoids the negative bias of arithmetic right shifts.
pub fn mulQ16(a: i32, b: i32) i32 {
    const product = @as(i64, a) * @as(i64, b);
    const rounded = if (product >= 0) product + 32768 else product - 32768;
    return @intCast(@divTrunc(rounded, 65536));
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
