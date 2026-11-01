//! Complete renderer quality data. No GPU creation and no switch on preset names.
const std = @import("std");
const validation = @import("validation.zig");
const limits = @import("limits.zig");
pub const GraphicsError = error{ InvalidGraphicsParameter, InvalidGraphicsConfiguration };
pub const Error = GraphicsError || error{ OutOfMemory, LimitExceeded, InvalidZon, ParseZon, UnsupportedPresetsVersion, InvalidTableRevision };
pub const Name = enum { low, medium, high };
pub const ToneMapping = enum { none, reinhard, aces };
pub const Parameters = struct {
    shadows_enabled: bool,
    shadow_map_size: u32,
    shadow_cascades: u8,
    shadow_distance_m: f32,
    shadow_depth_bias: f32,
    shadow_slope_bias: f32,
    shadow_normal_offset_m: f32,
    shadow_cascade_split_lambda: f32,
    shadow_pcf_kernel: u8,
    msaa_samples: u8,
    draw_distance_m: f32,
    texture_max_dimension: u32,
    texture_mip_bias: f32,
    texture_anisotropy: u8,
    post_processing_enabled: bool,
    bloom_enabled: bool,
    bloom_threshold: f32,
    bloom_soft_knee: f32,
    bloom_intensity: f32,
    bloom_levels: u8,
    ambient_occlusion_enabled: bool,
    ao_radius_m: f32,
    ao_depth_bias_m: f32,
    ao_intensity: f32,
    ao_samples: u8,
    tone_mapping: ToneMapping,
    exposure_ev: f32,
};
/// Presence, not truthiness, determines whether an override applies.
pub const Overrides = struct {
    shadows_enabled: ?bool = null,
    shadow_map_size: ?u32 = null,
    shadow_cascades: ?u8 = null,
    shadow_distance_m: ?f32 = null,
    msaa_samples: ?u8 = null,
    draw_distance_m: ?f32 = null,
    texture_max_dimension: ?u32 = null,
    texture_mip_bias: ?f32 = null,
    texture_anisotropy: ?u8 = null,
    post_processing_enabled: ?bool = null,
    bloom_enabled: ?bool = null,
    ambient_occlusion_enabled: ?bool = null,
    tone_mapping: ?ToneMapping = null,

    pub fn empty(self: Overrides) bool {
        inline for (@typeInfo(Overrides).@"struct".field_names) |field| {
            if (@field(self, field) != null) return false;
        }
        return true;
    }
};
pub const Table = struct {
    schema_version: u32,
    renderer_contract_version: u32,
    table_revision: []const u8,
    presets: struct { low: Parameters, medium: Parameters, high: Parameters },

    pub fn resolve(self: Table, name: Name, overrides: Overrides) GraphicsError!Parameters {
        // Enum name lookup occurs ONLY in the shared configuration layer.
        var result: Parameters = undefined;
        inline for (@typeInfo(Name).@"enum".field_names) |field| {
            if (name == @field(Name, field)) result = @field(self.presets, field);
        }
        inline for (@typeInfo(Overrides).@"struct".field_names) |field| {
            if (@field(overrides, field)) |value| @field(result, field) = value;
        }
        try validate(result);
        return result;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: Table,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Document {
    if (source.len > 64 * 1024) return error.LimitExceeded;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupeSentinel(u8, source, 0);
    try limits.zon(owned);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const Envelope = struct { schema_version: u32, renderer_contract_version: u32 };
    const envelope = try std.zon.parse.fromSlice(Envelope, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = owned,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    if (envelope.schema_version != 1 or envelope.renderer_contract_version != 1) return error.UnsupportedPresetsVersion;
    const value = try std.zon.parse.fromSlice(Table, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = owned,
        .diagnostics = &diagnostics,
    });
    if (value.schema_version != 1 or value.renderer_contract_version != 1) return error.UnsupportedPresetsVersion;
    if (!validation.semver(value.table_revision)) return error.InvalidTableRevision;
    inline for (@typeInfo(Name).@"enum".field_names) |field| try validate(@field(value.presets, field));
    return .{ .arena = arena, .value = value };
}

fn oneOf(value: anytype, comptime values: anytype) bool {
    inline for (values) |item| if (value == item) return true;
    return false;
}

pub fn validate(p: Parameters) GraphicsError!void {
    inline for (@typeInfo(Parameters).@"struct".field_names, @typeInfo(Parameters).@"struct".field_types) |field, T| {
        if (T == f32 and !std.math.isFinite(@field(p, field))) return error.InvalidGraphicsParameter;
    }
    if (!oneOf(p.shadow_map_size, .{ 256, 512, 1024, 2048, 4096, 8192 })) return error.InvalidGraphicsParameter;
    if (!oneOf(p.shadow_pcf_kernel, .{ 1, 3, 5 })) return error.InvalidGraphicsParameter;
    if (!oneOf(p.msaa_samples, .{ 1, 2, 4, 8 })) return error.InvalidGraphicsParameter;
    if (!oneOf(p.texture_max_dimension, .{ 256, 512, 1024, 2048, 4096, 8192, 16384 })) return error.InvalidGraphicsParameter;
    if (!oneOf(p.texture_anisotropy, .{ 1, 2, 4, 8, 16 })) return error.InvalidGraphicsParameter;
    if (!oneOf(p.ao_samples, .{ 8, 16, 32, 64 })) return error.InvalidGraphicsParameter;
    if (p.shadow_cascades < 1 or p.shadow_cascades > 4) return error.InvalidGraphicsParameter;
    if (p.shadow_distance_m <= 0 or p.shadow_distance_m > 100000) return error.InvalidGraphicsParameter;
    if (p.shadow_depth_bias < 0 or p.shadow_depth_bias > 0.01) return error.InvalidGraphicsParameter;
    if (p.shadow_slope_bias < 0 or p.shadow_slope_bias > 8) return error.InvalidGraphicsParameter;
    if (p.shadow_normal_offset_m < 0 or p.shadow_normal_offset_m > 1) return error.InvalidGraphicsParameter;
    if (p.shadow_cascade_split_lambda < 0 or p.shadow_cascade_split_lambda > 1) return error.InvalidGraphicsParameter;
    if (p.draw_distance_m <= 0 or p.draw_distance_m > 100000) return error.InvalidGraphicsParameter;
    if (p.texture_mip_bias < -4 or p.texture_mip_bias > 4) return error.InvalidGraphicsParameter;
    if (p.bloom_threshold < 0 or p.bloom_threshold > 64) return error.InvalidGraphicsParameter;
    if (p.bloom_soft_knee < 0 or p.bloom_soft_knee > 1) return error.InvalidGraphicsParameter;
    if (p.bloom_intensity < 0 or p.bloom_intensity > 2) return error.InvalidGraphicsParameter;
    if (p.bloom_levels < 1 or p.bloom_levels > 8) return error.InvalidGraphicsParameter;
    if (p.ao_radius_m <= 0 or p.ao_radius_m > 10) return error.InvalidGraphicsParameter;
    if (p.ao_depth_bias_m < 0 or p.ao_depth_bias_m > 0.5) return error.InvalidGraphicsParameter;
    if (p.ao_intensity < 0 or p.ao_intensity > 4) return error.InvalidGraphicsParameter;
    if (p.exposure_ev < -16 or p.exposure_ev > 16) return error.InvalidGraphicsParameter;
    if (p.shadow_distance_m > p.draw_distance_m or p.ao_depth_bias_m >= p.ao_radius_m) return error.InvalidGraphicsConfiguration;
}

test "complete table resolves each preset before any device exists" {
    var doc = try parse(std.testing.allocator, @embedFile("fixtures/presets.zon"));
    defer doc.deinit();
    const low = try doc.value.resolve(.low, .{});
    const medium = try doc.value.resolve(.medium, .{});
    const high = try doc.value.resolve(.high, .{});
    try std.testing.expect(!low.shadows_enabled and low.msaa_samples == 1);
    try std.testing.expectEqual(@as(u32, 2048), medium.shadow_map_size);
    try std.testing.expectEqual(@as(u8, 4), high.shadow_cascades);
    try std.testing.expectEqual(@as(u8, 16), high.texture_anisotropy);
    const overridden = try doc.value.resolve(.high, .{ .shadows_enabled = false, .texture_mip_bias = 0, .tone_mapping = .none });
    try std.testing.expect(!overridden.shadows_enabled);
    try std.testing.expectEqual(@as(f32, 0), overridden.texture_mip_bias);
    try std.testing.expectEqual(ToneMapping.none, overridden.tone_mapping);
    try std.testing.expectEqual(high.bloom_levels, overridden.bloom_levels);
    try std.testing.expectError(error.InvalidGraphicsConfiguration, doc.value.resolve(.high, .{ .draw_distance_m = 10 }));
    try std.testing.expectError(error.InvalidGraphicsParameter, doc.value.resolve(.low, .{ .msaa_samples = 3 }));
    try std.testing.expectError(error.InvalidGraphicsParameter, doc.value.resolve(.low, .{ .texture_mip_bias = std.math.nan(f32) }));
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var doc = try parse(allocator, @embedFile("fixtures/presets.zon"));
    defer doc.deinit();
    _ = try doc.value.resolve(.medium, .{});
}

test "preset parsing cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
