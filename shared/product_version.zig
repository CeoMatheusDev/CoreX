//! Strict CoreX product-version parser and precedence ordering.
//! This format is independent of package SemVer, .proj schema versions, ABI,
//! and the Zig toolchain. Parsing and comparison never allocate.
const std = @import("std");

pub const Channel = enum(u8) {
    alpha = 'a',
    beta = 'b',
    final = 'f',
    patch = 'p',

    pub fn symbol(self: Channel) u8 {
        return @backingInt(self);
    }

    fn precedence(self: Channel) u8 {
        return switch (self) {
            .alpha => 0,
            .beta => 1,
            .final => 2,
            .patch => 3,
        };
    }

    fn parse(byte: u8) ?Channel {
        return switch (byte) {
            'a' => .alpha,
            'b' => .beta,
            'f' => .final,
            'p' => .patch,
            else => null,
        };
    }
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    channel: Channel,
    revision: u32,

    pub const Error = error{ InvalidSyntax, IntegerOverflow, ZeroRevision };
    pub const TransitionError = error{ InvalidTransition, IntegerOverflow };
    pub const Bump = enum { alpha, beta, final, patch_release, major, minor, patch };

    /// Advance only through the documented release transitions.
    /// Major/minor/patch-line bumps are allowed from stable `f` or `p` versions
    /// and start the new line at `a1`; prereleases must first be finalized.
    pub fn bump(self: Version, action: Bump) TransitionError!Version {
        return switch (action) {
            .alpha => if (self.channel == .alpha)
                .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .alpha, .revision = try increment(self.revision) }
            else
                error.InvalidTransition,
            .beta => switch (self.channel) {
                .alpha => .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .beta, .revision = 1 },
                .beta => .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .beta, .revision = try increment(self.revision) },
                else => error.InvalidTransition,
            },
            .final => if (self.channel == .beta)
                .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .final, .revision = 1 }
            else
                error.InvalidTransition,
            .patch_release => switch (self.channel) {
                .final => .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .patch, .revision = 1 },
                .patch => .{ .major = self.major, .minor = self.minor, .patch = self.patch, .channel = .patch, .revision = try increment(self.revision) },
                else => error.InvalidTransition,
            },
            .major, .minor, .patch => blk: {
                if (self.channel != .final and self.channel != .patch) return error.InvalidTransition;
                break :blk .{
                    .major = if (action == .major) try increment(self.major) else self.major,
                    .minor = if (action == .major) 0 else if (action == .minor) try increment(self.minor) else self.minor,
                    .patch = if (action == .major or action == .minor) 0 else try increment(self.patch),
                    .channel = .alpha,
                    .revision = 1,
                };
            },
        };
    }

    /// Parse exactly `MAJOR.MINOR.PATCH{a|b|f|p}REVISION`.
    /// Decimal components are canonical (no leading zeroes); revision starts at 1.
    pub fn parse(text: []const u8) Error!Version {
        var cursor: usize = 0;
        const major = try decimal(text, &cursor, '.');
        const minor = try decimal(text, &cursor, '.');
        const patch = try decimal(text, &cursor, null);
        if (cursor >= text.len) return error.InvalidSyntax;
        const channel = Channel.parse(text[cursor]) orelse return error.InvalidSyntax;
        cursor += 1;
        const revision = try decimal(text, &cursor, null);
        if (cursor != text.len) return error.InvalidSyntax;
        if (revision == 0) return error.ZeroRevision;
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
            .channel = channel,
            .revision = revision,
        };
    }

    /// Product precedence is numeric release tuple, channel, then channel revision.
    pub fn compare(lhs: Version, rhs: Version) std.math.Order {
        if (lhs.major != rhs.major) return std.math.order(lhs.major, rhs.major);
        if (lhs.minor != rhs.minor) return std.math.order(lhs.minor, rhs.minor);
        if (lhs.patch != rhs.patch) return std.math.order(lhs.patch, rhs.patch);
        if (lhs.channel.precedence() != rhs.channel.precedence()) {
            return std.math.order(lhs.channel.precedence(), rhs.channel.precedence());
        }
        return std.math.order(lhs.revision, rhs.revision);
    }

    /// Deterministic SemVer token used only by the unchanged `.proj` field.
    /// Prereleases retain their channel/revision; final revision 1 keeps the
    /// existing SemVer core, and later final/patch revisions use build metadata.
    pub fn projectRequirement(self: Version, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (self.channel) {
            .alpha => std.fmt.bufPrint(buffer, "{d}.{d}.{d}-alpha.{d}", .{ self.major, self.minor, self.patch, self.revision }),
            .beta => std.fmt.bufPrint(buffer, "{d}.{d}.{d}-beta.{d}", .{ self.major, self.minor, self.patch, self.revision }),
            .final => if (self.revision == 1)
                std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch })
            else
                std.fmt.bufPrint(buffer, "{d}.{d}.{d}+corex.f{d}", .{ self.major, self.minor, self.patch, self.revision }),
            .patch => std.fmt.bufPrint(buffer, "{d}.{d}.{d}+corex.p{d}", .{ self.major, self.minor, self.patch, self.revision }),
        };
    }

    /// Write the canonical product representation into caller-owned storage.
    pub fn format(self: Version, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}{c}{d}", .{
            self.major,
            self.minor,
            self.patch,
            self.channel.symbol(),
            self.revision,
        });
    }
};

fn increment(value: u32) Version.TransitionError!u32 {
    return std.math.add(u32, value, 1) catch error.IntegerOverflow;
}

fn decimal(text: []const u8, cursor: *usize, delimiter: ?u8) Version.Error!u32 {
    const start = cursor.*;
    while (cursor.* < text.len) : (cursor.* += 1) {
        const byte = text[cursor.*];
        if (delimiter) |expected| {
            if (byte == expected) break;
        } else if (byte < '0' or byte > '9') break;
    }
    const end = cursor.*;
    if (start == end) return error.InvalidSyntax;
    if (end - start > 1 and text[start] == '0') return error.InvalidSyntax;
    const value = std.fmt.parseInt(u32, text[start..end], 10) catch |err| switch (err) {
        error.Overflow => return error.IntegerOverflow,
        error.InvalidCharacter => return error.InvalidSyntax,
    };
    if (delimiter) |expected| {
        if (cursor.* == text.len or text[cursor.*] != expected) return error.InvalidSyntax;
        cursor.* += 1;
    }
    return value;
}

test "product version parser accepts canonical channels and round-trips" {
    const cases = [_][]const u8{ "0.0.0a1", "1.2.3a9", "1.2.3b1", "1.2.3f1", "1.2.3p42", "4294967295.2.3f1" };
    for (cases) |text| {
        const parsed = try Version.parse(text);
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(text, try parsed.format(&buffer));
    }
}

test "project requirement encoding preserves channels where SemVer permits" {
    const cases = [_]struct { product: []const u8, requirement: []const u8 }{
        .{ .product = "0.1.0a1", .requirement = "0.1.0-alpha.1" },
        .{ .product = "0.1.0b2", .requirement = "0.1.0-beta.2" },
        .{ .product = "0.1.0f1", .requirement = "0.1.0" },
        .{ .product = "0.1.0f2", .requirement = "0.1.0+corex.f2" },
        .{ .product = "0.1.0p3", .requirement = "0.1.0+corex.p3" },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(case.requirement, try (try Version.parse(case.product)).projectRequirement(&buffer));
    }
}

test "product version parser rejects noncanonical syntax and overflow" {
    const cases = [_][]const u8{
        "",         "1",         "1.2",     "1.2.3",     "01.2.3a1", "1.02.3a1", "1.2.03a1",
        "1.2.3a",   "1.2.3c1",   "1.2.3A1", "1.2.3f1.0", " 1.2.3f1", "1.2.3f1 ", "1.2.3+f1",
        "1.2.3f-1", "1.2.3f1\n",
    };
    for (cases) |text| try std.testing.expectError(error.InvalidSyntax, Version.parse(text));
    try std.testing.expectError(error.IntegerOverflow, Version.parse("4294967296.0.0a1"));
    try std.testing.expectError(error.IntegerOverflow, Version.parse("1.0.0p4294967296"));
    try std.testing.expectError(error.ZeroRevision, Version.parse("1.2.3a0"));
    try std.testing.expectError(error.ZeroRevision, Version.parse("1.2.3p0"));
}

test "release bump transitions are explicit and monotonic" {
    const start = try Version.parse("0.1.0a1");
    const alpha2 = try start.bump(.alpha);
    var alpha_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1.0a2", try alpha2.format(&alpha_buffer));

    const beta1 = try start.bump(.beta);
    var beta_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1.0b1", try beta1.format(&beta_buffer));
    const beta2 = try beta1.bump(.beta);
    const final1 = try beta2.bump(.final);
    const patch1 = try final1.bump(.patch_release);
    const patch2 = try patch1.bump(.patch_release);
    for ([_]Version{ beta1, beta2, final1, patch1, patch2 }, 0..) |value, i| {
        const expected = [_][]const u8{ "0.1.0b1", "0.1.0b2", "0.1.0f1", "0.1.0p1", "0.1.0p2" };
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(expected[i], try value.format(&buffer));
    }

    const next_patch = try patch2.bump(.patch);
    const next_minor = try patch2.bump(.minor);
    const next_major = try patch2.bump(.major);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1.1a1", try next_patch.format(&buffer));
    try std.testing.expectEqual(.lt, patch2.compare(next_patch));
    try std.testing.expectEqualStrings("0.2.0a1", try next_minor.format(&buffer));
    try std.testing.expectEqualStrings("1.0.0a1", try next_major.format(&buffer));

    try std.testing.expectError(error.InvalidTransition, start.bump(.final));
    try std.testing.expectError(error.InvalidTransition, beta1.bump(.patch_release));
    try std.testing.expectError(error.InvalidTransition, final1.bump(.beta));
    try std.testing.expectError(error.InvalidTransition, start.bump(.minor));
    try std.testing.expectError(error.IntegerOverflow, (try Version.parse("1.0.0a4294967295")).bump(.alpha));
    try std.testing.expectError(error.IntegerOverflow, (try Version.parse("4294967295.0.0p1")).bump(.major));
}

test "channel precedence is alpha before beta before final before patch" {
    const values = [_][]const u8{ "2.4.0a8", "2.4.0b1", "2.4.0f1", "2.4.0p1" };
    for (values[0 .. values.len - 1], values[1..]) |left, right| {
        try std.testing.expectEqual(.lt, (try Version.parse(left)).compare(try Version.parse(right)));
    }
    try std.testing.expectEqual(.lt, (try Version.parse("2.4.0a1")).compare(try Version.parse("2.4.0a2")));
    try std.testing.expectEqual(.lt, (try Version.parse("2.4.0a999")).compare(try Version.parse("2.4.0b1")));
    try std.testing.expectEqual(.lt, (try Version.parse("2.3.99p99")).compare(try Version.parse("2.4.0a1")));
    try std.testing.expectEqual(.eq, (try Version.parse("1.2.3f1")).compare(try Version.parse("1.2.3f1")));
}
