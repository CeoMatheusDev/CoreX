const std = @import("std");
const project = @import("project.zig");
const presets = @import("presets.zig");
const limits = @import("limits.zig");
const a = std.testing.allocator;
const fixture = @embedFile("fixtures/EmptyGame.proj");
const table = @embedFile("fixtures/presets.zon");

fn changed(needle: []const u8, replacement: []const u8) ![]u8 {
    try std.testing.expect(std.mem.indexOf(u8, fixture, needle) != null);
    return std.mem.replaceOwned(u8, a, fixture, needle, replacement);
}
fn rejects(needle: []const u8, replacement: []const u8, expected: anyerror, pointer: []const u8) !void {
    const source = try changed(needle, replacement);
    defer a.free(source);
    var d: project.Diagnostic = .{};
    try std.testing.expectError(expected, project.parse(a, source, &d));
    try std.testing.expectEqualStrings(pointer, d.pointer());
}

test "version is inspected before future fields and never inferred" {
    var d: project.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedSchemaVersion, project.parse(a, "{\"schema_version\":4,\"future\":null}", &d));
    try std.testing.expectEqualStrings("/schema_version", d.pointer());
    try std.testing.expectError(error.MissingSchemaVersion, project.parse(a, "{}", &d));
    try rejects("\"schema_version\": 1", "\"schema_version\": \"1\"", error.InvalidField, "/schema_version");
}

test "renderer profiles are mandatory only in v3 and never inferred for legacy schemas" {
    var d: project.Diagnostic = .{};
    const v3 = @embedFile("fixtures/EmptyGameV3.proj");
    const invalid = try std.mem.replaceOwned(u8, a, v3, "\"profile\": \"lite\"", "\"profile\": \"future\"");
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidField, project.parse(a, invalid, &d));
    try std.testing.expectEqualStrings("/renderer/profile", d.pointer());

    const missing = try std.mem.replaceOwned(u8, a, v3, "\"profile\": \"lite\",\n", "");
    defer a.free(missing);
    try std.testing.expectError(error.InvalidField, project.parse(a, missing, &d));
    try std.testing.expectEqualStrings("/renderer/profile", d.pointer());

    const legacy_with_profile = try std.mem.replaceOwned(u8, a, fixture, "\"renderer\": {\n", "\"renderer\": {\n    \"profile\": \"lite\",\n");
    defer a.free(legacy_with_profile);
    try std.testing.expectError(error.InvalidField, project.parse(a, legacy_with_profile, &d));
    try std.testing.expectEqualStrings("/renderer/profile", d.pointer());

    var legacy = try project.parse(a, fixture, &d);
    defer legacy.deinit();
    try std.testing.expect(legacy.value.renderer.profile == null);
}

test "JSON rejects duplicates including escaped equivalent keys" {
    var d: project.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateField, project.parse(a, "{\"schema_version\":1,\"schema_versi\\u006fn\":1}", &d));
    try rejects("\"vsync\": true", "\"vsync\": true, \"vsync\": false", error.DuplicateField, "");
}

test "strict fields and RFC6901 diagnostic pointer escaping" {
    try rejects("\"name\":", "\"x/y~z\":0, \"name\":", error.InvalidField, "/project/x~1y~0z");
    try rejects("\"vsync\": true", "\"vsync\": 1", error.InvalidField, "/renderer/vsync");
    try rejects("\"fixed_tick_hz\": 60", "\"fixed_tick_hz\": \"60\"", error.InvalidField, "/simulation/fixed_tick_hz");
    try rejects("\"graphics_preset\": \"medium\"", "\"graphics_preset\": 1", error.InvalidField, "/renderer/graphics_preset");
    try rejects("\"graphics_preset\": \"medium\"", "\"graphics_preset\": \"ultra\"", error.InvalidField, "/renderer/graphics_preset");
}

test "integers with fractional and exponent notation normalize exactly" {
    const valid = try changed("\"fixed_tick_hz\": 60", "\"fixed_tick_hz\": 6e1");
    defer a.free(valid);
    var d: project.Diagnostic = .{};
    var doc = try project.parse(a, valid, &d);
    defer doc.deinit();
    try std.testing.expectEqual(@as(u32, 60), doc.value.simulation.fixed_tick_hz);
    try rejects("\"fixed_tick_hz\": 60", "\"fixed_tick_hz\": 60.000000000000000001", error.InvalidField, "/simulation/fixed_tick_hz");
    try rejects("\"seed\": 42", "\"seed\": 4294967296", error.InvalidField, "/simulation/seed");
    try rejects("\"seed\": 42", "\"seed\": -1", error.InvalidField, "/simulation/seed");
}

test "script mode combinations and containment are explicit" {
    try rejects("\"cpp_root\":", "\"cpp_module\":\"dynamic\", \"cpp_root\":", error.InvalidField, "/scripts/cpp_library");
    try rejects("\"cpp_root\":", "\"cpp_library\":\"build/gameplay\", \"cpp_root\":", error.InvalidField, "/scripts/cpp_library");
    try rejects("\"lua_root\":", "\"lua_entry\":\"scripts/elsewhere/main.lua\", \"lua_root\":", error.InvalidField, "/scripts/lua_entry");
    try rejects("\"scenes/Main.scene\"", "\"scenes-other/Main.scene\"", error.InvalidField, "/scenes/startup");
}

test "overrides are nullable internally but null is not valid project input" {
    try rejects("\"vsync\":", "\"overrides\":{\"msaa_samples\":null},\"vsync\":", error.InvalidField, "/renderer/overrides/msaa_samples");
    try rejects("\"vsync\":", "\"overrides\":{\"msaa_samples\":3},\"vsync\":", error.InvalidField, "/renderer/overrides/msaa_samples");
    try rejects("\"vsync\":", "\"overrides\":{\"draw_distance_m\":1e-999},\"vsync\":", error.InvalidField, "/renderer/overrides/draw_distance_m");
    try rejects("\"vsync\":", "\"overrides\":null,\"vsync\":", error.InvalidField, "/renderer/overrides");
}

test "serializer omits equivalent empty values and canonicalizes negative zero" {
    const input = try changed("\"vsync\":", "\"overrides\":{},\"vsync\":");
    defer a.free(input);
    var d: project.Diagnostic = .{};
    var doc = try project.parse(a, input, &d);
    defer doc.deinit();
    const empty = try project.serialize(a, doc.value, &d);
    defer a.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "overrides") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "cpp_module") == null);
    doc.value.renderer.overrides.texture_mip_bias = -0.0;
    const negative = try project.serialize(a, doc.value, &d);
    defer a.free(negative);
    doc.value.renderer.overrides.texture_mip_bias = 0.0;
    const positive = try project.serialize(a, doc.value, &d);
    defer a.free(positive);
    try std.testing.expectEqualStrings(positive, negative);
    try std.testing.expect(positive[positive.len - 1] == '\n');
}

test "document owns strings independently from input allocation" {
    var d: project.Diagnostic = .{};
    const input = try a.dupe(u8, fixture);
    var doc = project.parse(a, input, &d) catch |err| {
        a.free(input);
        return err;
    };
    a.free(input);
    defer doc.deinit();
    try std.testing.expectEqualStrings("Empty Game", doc.value.project.name);
    const bytes = try project.serialize(a, doc.value, &d);
    defer a.free(bytes);
}

test "metadata and lexical paths fail without defaults" {
    try rejects("2026-11-01T12:00:00Z", "2026-02-30T12:00:00Z", error.InvalidField, "/project/created_at");
    try rejects("61fe42aa-7bcc-41b1-ae4a-0baa9e324c10", "61fe42aa-7bcc-11b1-ae4a-0baa9e324c10", error.InvalidField, "/project/uuid");
    try rejects("\"root\": \"assets\"", "\"root\": \"../assets\"", error.InvalidPath, "/assets/root");
    try rejects("\"root\": \"assets\"", "\"root\": \"ação\"", error.UnicodePathNormalizationUnavailable, "/assets/root");
}

test "JSON size strings members and array counts are bounded" {
    const huge = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(huge);
    @memset(huge, ' ');
    var d: project.Diagnostic = .{};
    try std.testing.expectError(error.LimitExceeded, project.parse(a, huge, &d));
    const long = try a.alloc(u8, 4097);
    defer a.free(long);
    @memset(long, 'x');
    const string = try std.fmt.allocPrint(a, "\"{s}\"", .{long});
    defer a.free(string);
    try std.testing.expectError(error.LimitExceeded, limits.json(a, string));
    const members = try a.alloc(u8, 6 * 257 + 1);
    defer a.free(members);
    members[0] = '{';
    for (0..257) |i| @memcpy(members[1 + 6 * i ..][0..6], "\"a\":0,");
    members[members.len - 1] = '}';
    try std.testing.expectError(error.LimitExceeded, limits.json(a, members));
    var array: [2 * 257 + 1]u8 = undefined;
    array[0] = '[';
    for (0..257) |i| @memcpy(array[1 + 2 * i ..][0..2], "0,");
    array[array.len - 1] = ']';
    try std.testing.expectError(error.LimitExceeded, limits.json(a, &array));
}

fn rejectTable(needle: []const u8, replacement: []const u8, expected: anyerror) !void {
    const source = try std.mem.replaceOwned(u8, a, table, needle, replacement);
    defer a.free(source);
    try std.testing.expectError(expected, presets.parse(a, source));
}

test "ZON version envelope precedes interpreting a future body" {
    try std.testing.expectError(error.UnsupportedPresetsVersion, presets.parse(a, ".{ .schema_version=2, .renderer_contract_version=1, .future=.{} }"));
}

test "preset parser rejects unknown missing and duplicated fields" {
    try rejectTable(".msaa_samples = 1,", ".unexpected = 1,", error.ParseZon);
    try rejectTable(".msaa_samples = 1,", "", error.ParseZon);
    try rejectTable(".msaa_samples = 1,", ".msaa_samples = 1, .msaa_samples = 2,", error.ParseZon);
}

test "table rejects malformed unselected presets and latent constraints" {
    try rejectTable(".shadow_cascades = 4,", ".shadow_cascades = 5,", error.InvalidGraphicsParameter);
    try rejectTable(".shadow_distance_m = 40.0,", ".shadow_distance_m = 500.0,", error.InvalidGraphicsConfiguration);
    try rejectTable(".ao_depth_bias_m = 0.02,", ".ao_depth_bias_m = 0.5,", error.InvalidGraphicsConfiguration);
    try rejectTable(".msaa_samples = 1,", ".msaa_samples = 3,", error.InvalidGraphicsParameter);
}

test "restricted ZON grammar rejects comments code numeric special forms" {
    try rejectTable(".schema_version = 1,", ".schema_version = 0x1,", error.InvalidZon);
    try rejectTable(".schema_version = 1,", ".schema_version = 1, // comment", error.InvalidZon);
    try rejectTable(".exposure_ev = 0.0,", ".exposure_ev = inf,", error.InvalidZon);
    try rejectTable(".table_revision = \"1.0.0\",", ".table_revision = @import(\"x\"),", error.InvalidZon);
}

test "normalization preserves complete configs across shared consumers" {
    var d: project.Diagnostic = .{};
    var editor = try project.parse(a, fixture, &d);
    defer editor.deinit();
    var t = try presets.parse(a, table);
    defer t.deinit();
    inline for (.{ presets.Name.low, presets.Name.medium, presets.Name.high }) |name| {
        editor.value.renderer.graphics_preset = name;
        const bytes = try project.serialize(a, editor.value, &d);
        defer a.free(bytes);
        var runtime = try project.parse(a, bytes, &d);
        defer runtime.deinit();
        try std.testing.expectEqualDeep(
            try t.value.resolve(name, editor.value.renderer.overrides),
            try t.value.resolve(runtime.value.renderer.graphics_preset, runtime.value.renderer.overrides),
        );
    }
}

test "bounded deterministic mutation smoke test never trusts malformed input" {
    var state: u32 = 0x43585231;
    for (0..256) |_| {
        const bytes = try a.dupe(u8, fixture);
        defer a.free(bytes);
        state = state *% 1664525 +% 1013904223;
        const index = state % bytes.len;
        state = state *% 1664525 +% 1013904223;
        bytes[index] = @truncate(state);
        var d: project.Diagnostic = .{};
        var doc = project.parse(a, bytes, &d) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer doc.deinit();
        const serialized = try project.serialize(a, doc.value, &d);
        defer a.free(serialized);
        var again = try project.parse(a, serialized, &d);
        defer again.deinit();
        try std.testing.expectEqualDeep(doc.value, again.value);
    }
}
