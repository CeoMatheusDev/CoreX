//! Bounded lexical preflight before building an allocated JSON/ZON tree.
const std = @import("std");

pub fn json(allocator: std.mem.Allocator, source: []const u8) error{ OutOfMemory, LimitExceeded, InvalidJson }!void {
    if (source.len > 1024 * 1024) return error.LimitExceeded;
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf") or !std.unicode.utf8ValidateSlice(source)) return error.InvalidJson;
    var scanner = std.json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();
    const Frame = struct { object: bool, key: bool = true, elements: usize = 0 };
    var frames: [16]Frame = undefined;
    var depth: usize = 0;
    var members: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(allocator, .alloc_always, 4096) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.LimitExceeded,
            else => return error.InvalidJson,
        };
        const string: ?[]const u8 = switch (token) {
            .string, .allocated_string => |s| s,
            else => null,
        };
        defer switch (token) {
            .allocated_string, .allocated_number => |s| allocator.free(s),
            else => {},
        };
        if (string) |s| {
            if (!std.unicode.utf8ValidateSlice(s) or std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidJson;
            if (depth > 0 and frames[depth - 1].object and frames[depth - 1].key) {
                members += 1;
                if (members > 256) return error.LimitExceeded;
                frames[depth - 1].key = false;
                continue;
            }
        }
        switch (token) {
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .end_of_document => return,
            else => {
                if (depth > 0) {
                    if (frames[depth - 1].object) {
                        frames[depth - 1].key = true;
                    } else {
                        frames[depth - 1].elements += 1;
                        if (frames[depth - 1].elements > 256) return error.LimitExceeded;
                    }
                }
                switch (token) {
                    .object_begin, .array_begin => {
                        if (depth == frames.len) return error.LimitExceeded;
                        frames[depth] = .{ .object = token == .object_begin };
                        depth += 1;
                    },
                    else => {},
                }
            },
        }
    }
}

pub fn zon(source: [:0]const u8) error{ LimitExceeded, InvalidZon }!void {
    if (source.len > 64 * 1024) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null or std.mem.startsWith(u8, source, "\xef\xbb\xbf") or std.mem.indexOf(u8, source, "//") != null) return error.InvalidZon;
    var tokenizer = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var members: usize = 0;
    var previous: std.zig.Token.Tag = .eof;
    while (true) {
        const token = tokenizer.next();
        const text = source[token.loc.start..token.loc.end];
        switch (token.tag) {
            .eof => break,
            .l_brace => {
                depth += 1;
                if (depth > 4) return error.LimitExceeded;
            },
            .r_brace => {
                if (depth == 0) return error.InvalidZon;
                depth -= 1;
            },
            .equal => {
                members += 1;
                if (members > 128) return error.LimitExceeded;
            },
            .number_literal => {
                if (text.len + @as(usize, if (previous == .minus) 1 else 0) > 64) return error.LimitExceeded;
                // JSON's decimal grammar is also the numeric subset of our ZON profile.
                if (!decimalLiteral(text)) return error.InvalidZon;
            },
            .string_literal => {},
            .identifier => {
                if (previous == .equal and !std.mem.eql(u8, text, "true") and !std.mem.eql(u8, text, "false")) return error.InvalidZon;
            },
            .period, .comma, .minus => {},
            else => return error.InvalidZon,
        }
        previous = token.tag;
    }
    if (depth != 0) return error.InvalidZon;
}

test "JSON preflight rejects depth before allocated tree" {
    try std.testing.expectError(error.LimitExceeded, json(std.testing.allocator, "[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]"));
    try std.testing.expectError(error.InvalidJson, json(std.testing.allocator, "{\"x\":\"\\uD800\"}"));
    try std.testing.expectError(error.InvalidJson, json(std.testing.allocator, "{\"x\":\"\\u0000\"}"));
}

fn decimalLiteral(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return false;
    var i: usize = 1;
    if (s[0] != '0') while (i < s.len and std.ascii.isDigit(s[i])) {
        i += 1;
    };
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == start) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == start) return false;
    }
    return i == s.len;
}
