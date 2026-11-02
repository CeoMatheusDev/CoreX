//! Single-writer, allocation-free JSONL encoder and bootstrap sink.
//! Not a concurrent core/frame logging queue; calls are thread-affine.
const std = @import("std");
const cli = @import("cli.zig");
pub const max_record_bytes = 64 * 1024; // includes final LF
pub const Level = enum { debug, info, warn, @"error" };
pub const Error = error{ RecordTooLarge, InvalidText, InvalidTimestamp, SequenceExhausted };
pub const SinkError = Error || error{LogSinkFailed};
pub const Header = struct {
    timestamp: []const u8,
    level: Level,
    source: cli.Kind,
    event: []const u8,
    message: []const u8,
    session_id: []const u8,
    seq: u64,
    tick: ?u64 = null,
};

pub fn timestamp(milliseconds: i64) error{InvalidTimestamp}![24]u8 {
    // Explicit bootstrap profile: 1970..9999, without trapping on a bad clock.
    if (milliseconds < 0 or milliseconds >= 253402300800000) return error.InvalidTimestamp;
    const seconds: u64 = @intCast(@divTrunc(milliseconds, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    var out: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                                month_day.month.numeric(), @as(u32, month_day.day_index) + 1,
        day.getHoursIntoDay(),                        day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
        @as(u16, @intCast(@mod(milliseconds, 1000))),
    }) catch return error.InvalidTimestamp;
    return out;
}

pub fn validTimestamp(s: []const u8) bool {
    if (s.len != 24 or s[19] != '.' or s[23] != 'Z') return false;
    for (s[20..23]) |c| if (!std.ascii.isDigit(c)) return false;
    var date: [20]u8 = undefined;
    @memcpy(date[0..19], s[0..19]);
    date[19] = 'Z';
    return @import("validation.zig").utcDate(&date);
}

fn clipped(text: []const u8, max: usize) []const u8 {
    var end = @min(text.len, max);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

/// Builds the complete record before exposing any bytes to the sink.
/// Fields must be a named struct (JSON object), not an array/tuple or raw JSON.
/// On error no partial record should be sent to the sink. No allocation.
pub fn encode(buffer: []u8, header: Header, fields: anytype) Error![]const u8 {
    const T = @TypeOf(fields);
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) @compileError("log fields must be a named-field object");
    if (!validTimestamp(header.timestamp)) return error.InvalidTimestamp;
    if (header.seq == 0) return error.InvalidText;
    if (header.event.len == 0 or header.event.len > 128 or header.session_id.len == 0 or header.session_id.len > 128) return error.InvalidText;
    for ([_][]const u8{ header.timestamp, header.event, header.message, header.session_id }) |s| {
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidText;
    }
    const message = clipped(header.message, 4096);
    var writer = std.Io.Writer.fixed(buffer[0..@min(buffer.len, max_record_bytes)]);
    std.json.Stringify.value(.{
        .log_version = @as(u32, 1),
        .timestamp = header.timestamp,
        .level = header.level,
        .source = header.source,
        .event = header.event,
        .message = message,
        .session_id = header.session_id,
        .seq = header.seq,
        .tick = header.tick,
        .message_truncated = message.len != header.message.len,
        .fields = fields,
    }, .{}, &writer) catch return error.RecordTooLarge;
    // OS paths and callers' fields may contain non-UTF8 bytes even when the
    // header is valid. Never expose an invalid JSON string to the sink.
    if (!std.unicode.utf8ValidateSlice(writer.buffered())) return error.InvalidText;
    writer.writeByte('\n') catch return error.RecordTooLarge;
    return writer.buffered();
}

pub const Logger = struct {
    io: std.Io,
    source: cli.Kind,
    session_id: [32]u8,
    seq: u64 = 0,
    buffer: [max_record_bytes]u8 = undefined,

    pub fn init(io: std.Io, kind: cli.Kind) Logger {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        return .{ .io = io, .source = kind, .session_id = std.fmt.bytesToHex(nonce, .lower) };
    }

    /// Synchronous bootstrap/control-path sink only. stdout for debug/info;
    /// stderr for warn/error. Write errors propagate to a nonzero exit status.
    pub fn emit(self: *Logger, level: Level, event: []const u8, message: []const u8, fields: anytype) SinkError!void {
        const stamp = try timestamp(std.Io.Clock.real.now(self.io).toMilliseconds());
        self.seq = std.math.add(u64, self.seq, 1) catch return error.SequenceExhausted;
        const header: Header = .{
            .timestamp = &stamp,
            .level = level,
            .source = self.source,
            .event = event,
            .message = message,
            .session_id = &self.session_id,
            .seq = self.seq,
        };
        var output_level = level;
        const bytes = encode(&self.buffer, header, fields) catch |err| switch (err) {
            error.RecordTooLarge => blk: {
                output_level = .warn;
                break :blk try encode(&self.buffer, .{
                    .timestamp = &stamp,
                    .level = .warn,
                    .source = self.source,
                    .event = "log.record_too_large",
                    .message = "Registro excedeu o limite; campos descartados",
                    .session_id = &self.session_id,
                    .seq = self.seq,
                }, .{ .code = "log.record_too_large", .original_event = event, .truncated = true });
            },
            else => return err,
        };
        const file = switch (output_level) {
            .debug, .info => std.Io.File.stdout(),
            .warn, .@"error" => std.Io.File.stderr(),
        };
        file.writeStreamingAll(self.io, bytes) catch return error.LogSinkFailed;
    }
};

test "timestamp uses UTC milliseconds and rejects unsupported clock range" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &(try timestamp(0)));
    try std.testing.expectEqualStrings("2000-02-29T12:34:56.123Z", &(try timestamp(951827696123)));
    try std.testing.expectError(error.InvalidTimestamp, timestamp(-1));
    try std.testing.expectError(error.InvalidTimestamp, timestamp(253402300800000));
}

test "JSONL escaping preserves one record and typed fields without allocation" {
    var buffer: [4096]u8 = undefined;
    const line = try encode(&buffer, .{
        .timestamp = "2026-11-01T12:00:00.000Z",
        .level = .info,
        .source = .runtime,
        .event = "runtime.validation_complete",
        .message = "ação\n\"quoted\"\\",
        .session_id = "test",
        .seq = 1,
    }, .{ .enabled = false, .seed = @as(u32, 0) });
    try std.testing.expect(line[line.len - 1] == '\n');
    try std.testing.expect(std.mem.count(u8, line, "\n") == 1);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ação\n\"quoted\"\\", parsed.value.object.get("message").?.string);
    try std.testing.expect(parsed.value.object.get("tick").? == .null);
    try std.testing.expect(!parsed.value.object.get("fields").?.object.get("enabled").?.bool);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("fields").?.object.get("seed").?.integer);
}

test "JSONL limits reject partial output and truncate message at UTF8 boundaries" {
    var small: [16]u8 = undefined;
    const h: Header = .{ .timestamp = "2026-11-01T12:00:00.000Z", .level = .info, .source = .editor, .event = "test", .message = "ok", .session_id = "test", .seq = 1 };
    try std.testing.expectError(error.RecordTooLarge, encode(&small, h, .{ .value = 1 }));
    var buffer: [max_record_bytes]u8 = undefined;
    var big: [4098]u8 = undefined;
    @memset(&big, 'x');
    @memcpy(big[4095..], "あ");
    var long = h;
    long.message = &big;
    const line = try encode(&buffer, long, .{ .value = 1 });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("message_truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 4095), parsed.value.object.get("message").?.string.len);
    const raw_bytes = try encode(&buffer, h, .{ .invalid = @as([]const u8, "\xff") });
    try std.testing.expect(std.mem.indexOf(u8, raw_bytes, "\"invalid\":[255]") != null);
    try std.testing.expectError(error.InvalidText, encode(&buffer, h, .{ .invalid = std.json.Value{ .number_string = "\xff" } }));
}
