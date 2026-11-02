//! Shared .proj v1/v2/v3 document contract. Editor owns saving; Runtime only reads.
//! This module validates documents, not filesystem resources, ABI, or GPU support.
const std = @import("std");
const validation = @import("validation.zig");
const limits = @import("limits.zig");
const presets = @import("presets.zig");

pub const Error = error{
    OutOfMemory,
    LimitExceeded,
    InvalidJson,
    DuplicateField,
    InvalidField,
    MissingSchemaVersion,
    UnsupportedSchemaVersion,
    InvalidPath,
    UnicodePathNormalizationUnavailable,
};
const DecodeError = error{ OutOfMemory, InvalidField };

// Legacy backend tokens remain for v1 inspection; v2/v3 use the product APIs.
pub const Backend = enum { vulkan, webgpu, d3d12, metal, d3d11, opengl };
pub const RendererProfile = enum { advanced, standard, lite };

pub fn backendAllowedInSchema(version: u32, backend: Backend) bool {
    return switch (version) {
        1 => switch (backend) {
            .vulkan, .webgpu, .d3d12, .metal => true,
            else => false,
        },
        2, 3 => switch (backend) {
            .vulkan, .opengl, .d3d11, .d3d12 => true,
            else => false,
        },
        else => false,
    };
}
pub const CppModule = enum { static, dynamic };
pub const Project = struct {
    schema_version: u32,
    project: struct { name: []const u8, uuid: []const u8, version: []const u8, created_at: []const u8 },
    engine: struct { version: []const u8, graphics_backend: Backend },
    renderer: struct {
        /// Absent in legacy schemas v1/v2; v3 requires an explicit selection.
        profile: ?RendererProfile = null,
        graphics_preset: presets.Name,
        vsync: bool,
        initial_resolution: struct { width: u32, height: u32 },
        overrides: presets.Overrides = .{},
    },
    scenes: struct { root: []const u8, startup: []const u8 },
    scripts: struct {
        cpp_root: []const u8,
        lua_root: []const u8,
        cpp_module: ?CppModule = null,
        cpp_library: ?[]const u8 = null,
        lua_entry: ?[]const u8 = null,
    },
    assets: struct { root: []const u8 },
    simulation: struct { fixed_tick_hz: u32, seed: u32 },
};

/// No allocated messages or borrowed parser buffers. Safe after a failed parse.
/// `pointer` is bounded and may be truncated at a UTF-8 boundary.
pub const Diagnostic = struct {
    storage: [512]u8 = undefined,
    len: usize = 0,

    pub fn pointer(self: *const Diagnostic) []const u8 {
        return self.storage[0..self.len];
    }
    fn set(self: *Diagnostic, path: []const u8) void {
        var n = @min(path.len, self.storage.len);
        while (n > 0 and !std.unicode.utf8ValidateSlice(path[0..n])) n -= 1;
        @memcpy(self.storage[0..n], path[0..n]);
        self.len = n;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: Project,

    /// Invalidates all strings and the value. Document must not be copied/deinitialized twice.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error!Document {
    diagnostic.* = .{};
    if (source.len > 1024 * 1024) return error.LimitExceeded;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    try limits.json(a, source);
    const tree = std.json.parseFromSliceLeaky(std.json.Value, a, source, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
        .max_value_len = 4096,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.DuplicateField,
        else => return error.InvalidJson,
    };
    if (tree != .object) return error.InvalidField;
    const version = tree.object.get("schema_version") orelse {
        diagnostic.set("/schema_version");
        return error.MissingSchemaVersion;
    };
    diagnostic.set("/schema_version");
    if (version != .number_string) return error.InvalidField;
    const v = validation.exactU32(version.number_string) catch return error.InvalidField;
    if (v != 1 and v != 2 and v != 3) return error.UnsupportedSchemaVersion;
    diagnostic.set("");
    const value = try decode(Project, a, tree, "", diagnostic);
    try validate(value, diagnostic);
    diagnostic.set("");
    return .{ .arena = arena, .value = value };
}

fn fail(diagnostic: *Diagnostic, path: []const u8) error{InvalidField} {
    diagnostic.set(path);
    return error.InvalidField;
}

fn pointerChild(a: std.mem.Allocator, parent: []const u8, key: []const u8) error{OutOfMemory}![]const u8 {
    var len = parent.len + 1;
    for (key) |c| len += if (c == '~' or c == '/') @as(usize, 2) else 1;
    const out = try a.alloc(u8, len);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = '/';
    var index = parent.len + 1;
    for (key) |c| {
        if (c == '~' or c == '/') {
            out[index] = '~';
            out[index + 1] = if (c == '~') '0' else '1';
            index += 2;
        } else {
            out[index] = c;
            index += 1;
        }
    }
    return out;
}

/// Strict conversion: unlike permissive JSON helpers, string "60" is not a number,
/// and an enum cannot be supplied as an integer. Unknown fields always fail.
fn decode(comptime T: type, a: std.mem.Allocator, value: std.json.Value, path: []const u8, d: *Diagnostic) DecodeError!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (value != .object) return fail(d, path);
            var iter = value.object.iterator();
            while (iter.next()) |entry| {
                var known = false;
                inline for (info.field_names) |field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, field)) known = true;
                }
                if (!known) return fail(d, try pointerChild(a, path, entry.key_ptr.*));
            }
            var result: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |field, FieldType, attrs| {
                const child = try pointerChild(a, path, field);
                if (value.object.get(field)) |item| {
                    // Overrides use optionals for presence but JSON null is NOT permitted.
                    if (T == presets.Overrides and item == .null) return fail(d, child);
                    @field(result, field) = try decode(FieldType, a, item, child, d);
                } else if (attrs.default_value_ptr) |default| {
                    @field(result, field) = @as(*const FieldType, @ptrCast(@alignCast(default))).*;
                } else return fail(d, child);
            }
            return result;
        },
        .optional => |info| {
            if (value == .null) return null;
            return try decode(info.child, a, value, path, d);
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) @compileError("unsupported document field");
            if (value != .string) return fail(d, path);
            return value.string;
        },
        .bool => {
            if (value != .bool) return fail(d, path);
            return value.bool;
        },
        .int => {
            if (value != .number_string) return fail(d, path);
            const n = validation.exactU32(value.number_string) catch return fail(d, path);
            return std.math.cast(T, n) orelse return fail(d, path);
        },
        .float => {
            if (value != .number_string) return fail(d, path);
            const n = std.fmt.parseFloat(T, value.number_string) catch return fail(d, path);
            if (!std.math.isFinite(n)) return fail(d, path);
            // Canonicalize negative zero. Positive-distance underflow is rejected by ranges.
            return if (n == 0) 0 else n;
        },
        .@"enum" => {
            if (value != .string) return fail(d, path);
            return std.meta.stringToEnum(T, value.string) orelse return fail(d, path);
        },
        else => @compileError("unsupported document field"),
    }
}

fn require(ok: bool, d: *Diagnostic, path: []const u8) !void {
    if (!ok) return fail(d, path);
}
fn pathCheck(path: []const u8, d: *Diagnostic, pointer: []const u8) !void {
    validation.relativePath(path) catch |err| {
        d.set(pointer);
        return err;
    };
}

pub fn validate(p: Project, d: *Diagnostic) Error!void {
    try require(p.schema_version == 1 or p.schema_version == 2 or p.schema_version == 3, d, "/schema_version");
    try require(backendAllowedInSchema(p.schema_version, p.engine.graphics_backend), d, "/engine/graphics_backend");
    // Preserve v1/v2 documents without inventing a profile. V3 is explicit.
    try require((p.schema_version == 3) == (p.renderer.profile != null), d, "/renderer/profile");
    try require(validation.projectName(p.project.name), d, "/project/name");
    try require(validation.uuidV4(p.project.uuid), d, "/project/uuid");
    try require(validation.semver(p.project.version), d, "/project/version");
    try require(validation.utcDate(p.project.created_at), d, "/project/created_at");
    try require(validation.semver(p.engine.version), d, "/engine/version");
    try require(p.renderer.initial_resolution.width >= 64 and p.renderer.initial_resolution.width <= 16384, d, "/renderer/initial_resolution/width");
    try require(p.renderer.initial_resolution.height >= 64 and p.renderer.initial_resolution.height <= 16384, d, "/renderer/initial_resolution/height");
    try require(p.simulation.fixed_tick_hz >= 1 and p.simulation.fixed_tick_hz <= 1000, d, "/simulation/fixed_tick_hz");
    try pathCheck(p.assets.root, d, "/assets/root");
    try pathCheck(p.scenes.root, d, "/scenes/root");
    try pathCheck(p.scenes.startup, d, "/scenes/startup");
    try require(std.mem.endsWith(u8, p.scenes.startup, ".scene") and validation.containedLexically(p.scenes.root, p.scenes.startup), d, "/scenes/startup");
    try pathCheck(p.scripts.cpp_root, d, "/scripts/cpp_root");
    try pathCheck(p.scripts.lua_root, d, "/scripts/lua_root");
    if (p.scripts.lua_entry) |entry| {
        try pathCheck(entry, d, "/scripts/lua_entry");
        try require(std.mem.endsWith(u8, entry, ".lua") and validation.containedLexically(p.scripts.lua_root, entry), d, "/scripts/lua_entry");
    }
    if (p.scripts.cpp_module == .dynamic) {
        const library = p.scripts.cpp_library orelse return fail(d, "/scripts/cpp_library");
        try pathCheck(library, d, "/scripts/cpp_library");
        inline for (.{ ".dll", ".so", ".dylib" }) |suffix| {
            try require(!std.mem.endsWith(u8, library, suffix), d, "/scripts/cpp_library");
        }
    } else try require(p.scripts.cpp_library == null, d, "/scripts/cpp_library");
    try validateOverrides(p.renderer.overrides, d);
}

fn validateOverrides(o: presets.Overrides, d: *Diagnostic) !void {
    // Validate individual ranges here; cross-field constraints need the actual table.
    inline for (@typeInfo(presets.Overrides).@"struct".field_names) |field| {
        if (@field(o, field)) |value| {
            const ok = switch (@field(OverrideField, field)) {
                .shadow_map_size => member(value, .{ 256, 512, 1024, 2048, 4096, 8192 }),
                .shadow_cascades => value >= 1 and value <= 4,
                .shadow_distance_m, .draw_distance_m => std.math.isFinite(value) and value > 0 and value <= 100000,
                .msaa_samples => member(value, .{ 1, 2, 4, 8 }),
                .texture_max_dimension => member(value, .{ 256, 512, 1024, 2048, 4096, 8192, 16384 }),
                .texture_mip_bias => std.math.isFinite(value) and value >= -4 and value <= 4,
                .texture_anisotropy => member(value, .{ 1, 2, 4, 8, 16 }),
                .shadows_enabled, .post_processing_enabled, .bloom_enabled, .ambient_occlusion_enabled, .tone_mapping => true,
            };
            try require(ok, d, "/renderer/overrides/" ++ field);
        }
    }
}
const OverrideField = enum { shadows_enabled, shadow_map_size, shadow_cascades, shadow_distance_m, msaa_samples, draw_distance_m, texture_max_dimension, texture_mip_bias, texture_anisotropy, post_processing_enabled, bloom_enabled, ambient_occlusion_enabled, tone_mapping };
fn member(value: anytype, comptime values: anytype) bool {
    inline for (values) |item| if (value == item) return true;
    return false;
}

/// Canonical JSON in memory. Caller frees the returned bytes with `allocator`.
/// Disk atomic replacement/backup belongs to Editor/platform_ext, NOT this function.
pub fn serialize(allocator: std.mem.Allocator, p: Project, d: *Diagnostic) Error![]u8 {
    try validate(p, d);
    var overrides = p.renderer.overrides;
    inline for (@typeInfo(presets.Overrides).@"struct".field_names, @typeInfo(presets.Overrides).@"struct".field_types) |field, T| {
        if (T == ?f32) {
            if (@field(overrides, field)) |v| if (v == 0) {
                @field(overrides, field) = 0;
            };
        }
    }
    const wire = .{
        .schema_version = p.schema_version,
        .project = p.project,
        .engine = p.engine,
        .renderer = .{
            .profile = p.renderer.profile,
            .graphics_preset = p.renderer.graphics_preset,
            .vsync = p.renderer.vsync,
            .initial_resolution = p.renderer.initial_resolution,
            .overrides = if (overrides.empty()) @as(?presets.Overrides, null) else overrides,
        },
        .scenes = p.scenes,
        .scripts = p.scripts,
        .assets = p.assets,
        .simulation = p.simulation,
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, wire, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(bytes);
    return std.fmt.allocPrint(allocator, "{s}\n", .{bytes});
}

test "Editor serializes and Runtime reads all normalized values" {
    const a = std.testing.allocator;
    var d: Diagnostic = .{};
    var editor = try parse(a, @embedFile("fixtures/EmptyGame.proj"), &d);
    defer editor.deinit();
    editor.value.project.name = "Jogo ação 日本語";
    editor.value.renderer.overrides = .{
        .shadows_enabled = false,
        .shadow_map_size = 1024,
        .shadow_cascades = 3,
        .shadow_distance_m = 100,
        .msaa_samples = 1,
        .draw_distance_m = 2500,
        .texture_max_dimension = 4096,
        .texture_mip_bias = 0,
        .texture_anisotropy = 8,
        .post_processing_enabled = false,
        .bloom_enabled = true,
        .ambient_occlusion_enabled = true,
        .tone_mapping = .none,
    };
    editor.value.scripts.cpp_module = .dynamic;
    editor.value.scripts.cpp_library = "build/gameplay";
    editor.value.scripts.lua_entry = "scripts/lua/main.lua";
    editor.value.simulation.seed = 0;
    const bytes = try serialize(a, editor.value, &d);
    defer a.free(bytes);
    var runtime = try parse(a, bytes, &d);
    defer runtime.deinit();
    try std.testing.expectEqualDeep(editor.value, runtime.value);
    const again = try serialize(a, runtime.value, &d);
    defer a.free(again);
    try std.testing.expectEqualStrings(bytes, again);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var d: Diagnostic = .{};
    var doc = try parse(a, @embedFile("fixtures/EmptyGame.proj"), &d);
    defer doc.deinit();
    const bytes = try serialize(a, doc.value, &d);
    defer a.free(bytes);
}

test "document parsing and serialization release every allocation on failure" {
    try @import("testing_allocator.zig").checkAllFailures(allocationProbe, .{});
}

test "schema v1/v2/v3 backend matrix and serialization round trips" {
    const a = std.testing.allocator;
    var d: Diagnostic = .{};
    var document = try parse(a, @embedFile("fixtures/EmptyGameV2.proj"), &d);
    defer document.deinit();
    for ([_]u32{ 1, 2, 3 }) |version| {
        inline for (std.meta.tags(Backend)) |backend| {
            document.value.schema_version = version;
            document.value.renderer.profile = if (version == 3) .lite else null;
            document.value.engine.graphics_backend = backend;
            const expected = if (version == 1)
                (backend == .vulkan or backend == .webgpu or backend == .d3d12 or backend == .metal)
            else
                (backend == .vulkan or backend == .opengl or backend == .d3d11 or backend == .d3d12);
            try std.testing.expectEqual(expected, backendAllowedInSchema(version, backend));
            if (expected) {
                const text = try serialize(a, document.value, &d);
                defer a.free(text);
                var roundtrip = try parse(a, text, &d);
                defer roundtrip.deinit();
                try std.testing.expectEqual(version, roundtrip.value.schema_version);
                try std.testing.expectEqual(backend, roundtrip.value.engine.graphics_backend);
            } else {
                try std.testing.expectError(error.InvalidField, serialize(a, document.value, &d));
                try std.testing.expectEqualStrings("/engine/graphics_backend", d.pointer());
            }
        }
    }
}

test "schema v3 preserves explicit renderer identity and legacy projects remain unselected" {
    const a = std.testing.allocator;
    var d: Diagnostic = .{};
    var v3 = try parse(a, @embedFile("fixtures/EmptyGameV3.proj"), &d);
    defer v3.deinit();
    try std.testing.expectEqual(@as(u32, 3), v3.value.schema_version);
    try std.testing.expectEqual(RendererProfile.lite, v3.value.renderer.profile.?);

    inline for (std.meta.tags(RendererProfile)) |profile| {
        v3.value.renderer.profile = profile;
        const bytes = try serialize(a, v3.value, &d);
        defer a.free(bytes);
        var roundtrip = try parse(a, bytes, &d);
        defer roundtrip.deinit();
        try std.testing.expectEqual(profile, roundtrip.value.renderer.profile.?);
        try std.testing.expectEqualDeep(v3.value, roundtrip.value);
    }

    inline for (.{ @embedFile("fixtures/EmptyGame.proj"), @embedFile("fixtures/EmptyGameV2.proj") }) |legacy_bytes| {
        var legacy = try parse(a, legacy_bytes, &d);
        defer legacy.deinit();
        try std.testing.expect(legacy.value.renderer.profile == null);
        const serialized = try serialize(a, legacy.value, &d);
        defer a.free(serialized);
        try std.testing.expect(std.mem.indexOf(u8, serialized, "\"profile\"") == null);
        var legacy_roundtrip = try parse(a, serialized, &d);
        defer legacy_roundtrip.deinit();
        try std.testing.expect(legacy_roundtrip.value.renderer.profile == null);
        try std.testing.expectEqualDeep(legacy.value, legacy_roundtrip.value);
    }
}
