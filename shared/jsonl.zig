//! Bounded JSONL framing and protocol validation. Invalid records remain raw
//! diagnostics; callers must not treat arbitrary text as a successful handshake.
const std = @import("std");
const limits = @import("limits.zig");
const logging = @import("logging.zig");
pub const Parsed = std.json.Parsed(std.json.Value);
pub const Frame = union(enum) { line: []const u8, oversized: usize };
pub const Framer = struct {
    buffer: [logging.max_record_bytes - 1]u8 = undefined,
    len: usize = 0,
    count: usize = 0,
    dropping: bool = false,

    /// Returned slices are borrowed until the next push/finish. Process each
    /// frame immediately; never store it while appending another fragment.
    pub fn push(self: *Framer, byte: u8) ?Frame {
        self.count +|= 1;
        if (byte == '\n') return self.flush();
        if (self.len == self.buffer.len) self.dropping = true;
        if (!self.dropping) {
            self.buffer[self.len] = byte;
            self.len += 1;
        }
        return null;
    }
    pub fn finish(self: *Framer) ?Frame {
        if (self.count == 0) return null;
        return self.flush();
    }
    fn flush(self: *Framer) Frame {
        const result: Frame = if (self.dropping) .{ .oversized = self.count } else .{ .line = self.buffer[0..self.len] };
        self.len = 0;
        self.count = 0;
        self.dropping = false;
        return result;
    }
};

fn text(value: std.json.Value, key: []const u8, max: usize) ![]const u8 {
    const item = value.object.get(key) orelse return error.InvalidLogRecord;
    if (item != .string or item.string.len > max) return error.InvalidLogRecord;
    return item.string;
}
fn unsigned(item: std.json.Value) !u64 {
    if (item != .number_string) return error.InvalidLogRecord;
    for (item.number_string) |c| if (!std.ascii.isDigit(c)) return error.InvalidLogRecord;
    return std.fmt.parseInt(u64, item.number_string, 10) catch return error.InvalidLogRecord;
}

pub fn parse(a: std.mem.Allocator, line: []const u8) !Parsed {
    try limits.jsonWithLimits(a, line, .{ .bytes = logging.max_record_bytes - 1, .string_bytes = logging.max_record_bytes, .depth = 16, .members = 512, .collection = 512, .allow_nul_strings = true });
    var parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{ .allocate = .alloc_always, .parse_numbers = false });
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return error.InvalidLogRecord;
    const version = value.object.get("log_version") orelse return error.InvalidLogRecord;
    if (try unsigned(version) != 1) return error.UnsupportedLogVersion;
    const stamp = try text(value, "timestamp", 24);
    if (!logging.validTimestamp(stamp)) return error.InvalidLogRecord;
    const level = try text(value, "level", 5);
    if (std.meta.stringToEnum(logging.Level, level) == null) return error.InvalidLogRecord;
    const source = try text(value, "source", 128);
    const event = try text(value, "event", 128);
    const session = try text(value, "session_id", 128);
    if (source.len == 0 or event.len == 0 or session.len == 0) return error.InvalidLogRecord;
    _ = try text(value, "message", 4096);
    if (try unsigned(value.object.get("seq") orelse return error.InvalidLogRecord) == 0) return error.InvalidLogRecord;
    const tick = value.object.get("tick") orelse return error.InvalidLogRecord;
    if (tick != .null) _ = try unsigned(tick);
    const fields = value.object.get("fields") orelse return error.InvalidLogRecord;
    if (fields != .object) return error.InvalidLogRecord;
    if (value.object.get("message_truncated")) |flag| if (flag != .bool) return error.InvalidLogRecord;
    return parsed;
}

test "framer accepts fragments CRLF and EOF without final newline" {
    var framer: Framer = .{};
    for ("frag") |byte| try std.testing.expect(framer.push(byte) == null);
    for ("mented\r") |byte| try std.testing.expect(framer.push(byte) == null);
    const frame = framer.push('\n').?;
    try std.testing.expectEqualStrings("fragmented\r", frame.line);
    for ("last") |byte| _ = framer.push(byte);
    try std.testing.expectEqualStrings("last", framer.finish().?.line);
    try std.testing.expect(framer.finish() == null);
}

test "framer discards oversized line and resumes on next boundary" {
    var framer: Framer = .{};
    for (0..logging.max_record_bytes + 10) |_| _ = framer.push('x');
    try std.testing.expectEqual(logging.max_record_bytes + 11, framer.push('\n').?.oversized);
    _ = framer.push('a');
    try std.testing.expectEqualStrings("a", framer.push('\n').?.line);
}

test "structured log reader rejects raw malformed future and incomplete metadata" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidLogRecord, parse(a, "{}"));
    try std.testing.expectError(error.UnsupportedLogVersion, parse(a, "{\"log_version\":2}"));
    var buffer: [4096]u8 = undefined;
    const line = try logging.encode(&buffer, .{ .timestamp = "2026-11-01T12:00:00.000Z", .level = .info, .source = .runtime, .event = "runtime.validation_complete", .message = "ok\x00", .session_id = "session", .seq = 1 }, .{ .value = 1 });
    var parsed = try parse(a, std.mem.trimEnd(u8, line, "\n"));
    defer parsed.deinit();
    try std.testing.expectEqualStrings("runtime.validation_complete", parsed.value.object.get("event").?.string);
    try std.testing.expectEqualStrings("ok\x00", parsed.value.object.get("message").?.string);
}

fn allocationProbe(a: std.mem.Allocator, invalid: bool) !void {
    var buffer: [4096]u8 = undefined;
    const line = try logging.encode(&buffer, .{ .timestamp = "2026-11-01T12:00:00.000Z", .level = .info, .source = .runtime, .event = "test", .message = "ok", .session_id = "test", .seq = 1 }, .{ .value = 1 });
    if (invalid) {
        const index = std.mem.indexOf(u8, line, "\"seq\":1").?;
        buffer[index + 6] = '0';
    }
    var parsed = parse(a, std.mem.trimEnd(u8, line, "\n")) catch |err| {
        if (invalid and err == error.InvalidLogRecord) return;
        return err;
    };
    defer parsed.deinit();
    if (invalid) return error.TestUnexpectedResult;
}

test "JSONL owns records and cleans allocation failures on valid and invalid metadata" {
    try @import("testing_allocator.zig").checkAllFailures(allocationProbe, .{false});
    try @import("testing_allocator.zig").checkAllFailures(allocationProbe, .{true});
}
