//! Pure semantic checks. No filesystem access or implicit normalization.
const std = @import("std");

pub fn exactU32(text: []const u8) !u32 {
    // JSON scanner owns syntax validation. Work in decimal, never via f64:
    // 1.0000000000000000001 must not silently become 1.
    if (text.len == 0) return error.InvalidNumber;
    const negative = text[0] == '-';
    var digits: [4096]u8 = undefined;
    var count: usize = 0;
    var fractional: i32 = 0;
    var dot = false;
    var i: usize = if (negative) 1 else 0;
    while (i < text.len and text[i] != 'e' and text[i] != 'E') : (i += 1) {
        const c = text[i];
        if (c == '.') {
            if (dot) return error.InvalidNumber;
            dot = true;
        } else {
            if (!std.ascii.isDigit(c) or count == digits.len) return error.InvalidNumber;
            digits[count] = c;
            count += 1;
            if (dot) fractional += 1;
        }
    }
    if (count == 0) return error.InvalidNumber;
    var all_zero = true;
    for (digits[0..count]) |c| if (c != '0') {
        all_zero = false;
    };
    if (all_zero) return 0;
    if (negative) return error.InvalidNumber;
    var exponent: i32 = 0;
    if (i < text.len) {
        exponent = std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return error.InvalidNumber;
    }
    var end = count;
    var shift = std.math.sub(i32, exponent, fractional) catch return error.InvalidNumber;
    while (end > 0 and digits[end - 1] == '0') {
        end -= 1;
        shift = std.math.add(i32, shift, 1) catch return error.InvalidNumber;
    }
    if (end == 0) return 0;
    if (shift < 0 or shift > 10) return error.InvalidNumber;
    var result: u32 = 0;
    for (digits[0..end]) |c| {
        result = std.math.mul(u32, result, 10) catch return error.InvalidNumber;
        result = std.math.add(u32, result, c - '0') catch return error.InvalidNumber;
    }
    var n: i32 = 0;
    while (n < shift) : (n += 1) result = std.math.mul(u32, result, 10) catch return error.InvalidNumber;
    return result;
}

pub fn semver(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    const plus = std.mem.indexOfScalar(u8, s, '+');
    const version = if (plus) |p| s[0..p] else s;
    if (plus) |p| if (!identifiers(s[p + 1 ..], false)) return false;
    const dash = std.mem.indexOfScalar(u8, version, '-');
    const core = if (dash) |p| version[0..p] else version;
    if (dash) |p| if (!identifiers(version[p + 1 ..], true)) return false;
    var parts = std.mem.splitScalar(u8, core, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!numeric(part) or (part.len > 1 and part[0] == '0')) return false;
    }
    return count == 3;
}

fn numeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn identifiers(s: []const u8, forbid_numeric_zero: bool) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        if (forbid_numeric_zero and numeric(part) and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}

pub fn uuidV4(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return s[14] == '4' and std.mem.indexOfScalar(u8, "89ab", s[19]) != null;
}

pub fn utcDate(s: []const u8) bool {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return false;
    const positions = [_][2]usize{ .{ 0, 4 }, .{ 5, 7 }, .{ 8, 10 }, .{ 11, 13 }, .{ 14, 16 }, .{ 17, 19 } };
    var values: [6]u32 = undefined;
    for (positions, 0..) |pos, i| {
        const text = s[pos[0]..pos[1]];
        if (!numeric(text)) return false;
        values[i] = std.fmt.parseInt(u32, text, 10) catch return false;
    }
    const y = values[0];
    const m = values[1];
    const d = values[2];
    if (y == 0 or m == 0 or m > 12 or d == 0 or values[3] > 23 or values[4] > 59 or values[5] > 59) return false;
    const leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d <= days[m - 1];
}

fn whitespace(c: u21) bool {
    return (c >= 9 and c <= 13) or c == 32 or c == 0x85 or c == 0xa0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200a) or c == 0x2028 or c == 0x2029 or c == 0x202f or c == 0x205f or c == 0x3000;
}

pub fn projectName(s: []const u8) bool {
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    var count: usize = 0;
    var last: u21 = 0;
    while (it.nextCodepoint()) |c| {
        if (c < 32 or c == 127 or (count == 0 and whitespace(c))) return false;
        last = c;
        count += 1;
    }
    return count >= 1 and count <= 128 and !whitespace(last);
}

/// Lexical only. Filesystem containment/case/symlinks belong to platform_ext.
/// P14: fail closed on non-ASCII until complete NFC verification is available.
pub fn relativePath(s: []const u8) !void {
    if (s.len == 0 or s.len > 1024) return error.InvalidPath;
    for (s) |c| {
        if (c >= 128) return error.UnicodePathNormalizationUnavailable;
        if (c < 32 or c == 127 or std.mem.indexOfScalar(u8, "\\:<>\"|?*", c) != null) return error.InvalidPath;
    }
    var parts = std.mem.splitScalar(u8, s, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidPath;
        const basename = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(basename, reserved)) return error.InvalidPath;
        }
        if (basename.len == 4 and (std.ascii.eqlIgnoreCase(basename[0..3], "COM") or std.ascii.eqlIgnoreCase(basename[0..3], "LPT")) and basename[3] >= '1' and basename[3] <= '9') return error.InvalidPath;
    }
}

pub fn containedLexically(root: []const u8, path: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

test "decimal integer conversion is exact, not float rounded" {
    try std.testing.expectEqual(@as(u32, 60), try exactU32("6e1"));
    try std.testing.expectEqual(@as(u32, 0), try exactU32("-0.0"));
    try std.testing.expectEqual(@as(u32, 0), try exactU32("0e99999999999999999999"));
    try std.testing.expectEqual(@as(u32, 60), try exactU32("60.0"));
    try std.testing.expectEqual(@as(u32, 4294967295), try exactU32("4294967295"));
    for ([_][]const u8{ "1.00000000000000001", "4294967296", "-1", "1e-9999", "1e9999", "0.1" }) |s| try std.testing.expectError(error.InvalidNumber, exactU32(s));
}

test "metadata dates and SemVer" {
    try std.testing.expect(utcDate("2024-02-29T00:00:00Z"));
    for ([_][]const u8{ "2026-02-29T00:00:00Z", "0000-01-01T00:00:00Z", "2026-01-01T24:00:00Z" }) |s| try std.testing.expect(!utcDate(s));
    try std.testing.expect(semver("1.2.3-rc.1+build.01"));
    for ([_][]const u8{ "01.2.3", "1.2.3-01", "1.2.3+", "1.2", "1.2.3+a+b" }) |s| try std.testing.expect(!semver(s));
    try std.testing.expect(projectName("Jogo ação"));
    try std.testing.expect(!projectName(" Jogo"));
}

test "portable path lexical rejection" {
    for ([_][]const u8{ "", ".", "../assets", "/assets", "C:/assets", "a//b", "a/", "a/./b", "a/../b", "con.txt", "assets/LPT1.png", "a/b.", "a/b " }) |s| try std.testing.expectError(error.InvalidPath, relativePath(s));
    try relativePath("assets/My Game/a.png");
    try std.testing.expectError(error.UnicodePathNormalizationUnavailable, relativePath("assets/ação"));
    try std.testing.expect(!containedLexically("scenes", "scenes-other/a.scene"));
}
