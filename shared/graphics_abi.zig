//! Explicit internal Zig -> C23 translation. Not a core API implementation.
const std = @import("std");
const presets = @import("presets.zig");
// Zig 0.17 uses explicit C declarations here (no @cImport). C static_asserts
// and Zig offset tests independently verify every member against the header.
pub const c = struct {
    pub const CoreXGraphicsConfigV1 = extern struct {
        abi_version: u32,
        struct_size: u32,
        shadows_enabled: u32,
        shadow_map_size: u32,
        shadow_cascades: u32,
        shadow_distance_m: f32,
        shadow_depth_bias: f32,
        shadow_slope_bias: f32,
        shadow_normal_offset_m: f32,
        shadow_cascade_split_lambda: f32,
        shadow_pcf_kernel: u32,
        msaa_samples: u32,
        draw_distance_m: f32,
        texture_max_dimension: u32,
        texture_mip_bias: f32,
        texture_anisotropy: u32,
        post_processing_enabled: u32,
        bloom_enabled: u32,
        bloom_threshold: f32,
        bloom_soft_knee: f32,
        bloom_intensity: f32,
        bloom_levels: u32,
        ambient_occlusion_enabled: u32,
        ao_radius_m: f32,
        ao_depth_bias_m: f32,
        ao_intensity: f32,
        ao_samples: u32,
        tone_mapping: u32,
        exposure_ev: f32,
    };
    pub const COREX_GRAPHICS_OK: i32 = 0;
    pub const COREX_GRAPHICS_INVALID_HEADER: i32 = -1;
    pub const COREX_GRAPHICS_INVALID_PARAMETER: i32 = -2;
    pub const COREX_GRAPHICS_INVALID_CONFIGURATION: i32 = -3;
    pub extern fn corex_graphics_validate_v1(config: ?*const CoreXGraphicsConfigV1, buffer_size: u32) callconv(.c) i32;
    pub extern fn corex_graphics_size_v1() callconv(.c) u32;
};

pub fn translate(p: presets.Parameters) !c.CoreXGraphicsConfigV1 {
    try presets.validate(p);
    var dto: c.CoreXGraphicsConfigV1 = undefined;
    dto.abi_version = 1;
    dto.struct_size = @sizeOf(c.CoreXGraphicsConfigV1);
    inline for (@typeInfo(presets.Parameters).@"struct".field_names, @typeInfo(presets.Parameters).@"struct".field_types) |name, T| {
        const value = @field(p, name);
        @field(dto, name) = if (T == bool) @intFromBool(value) else if (T == presets.ToneMapping) switch (value) {
            .none => @as(u32, 0),
            .reinhard => @as(u32, 1),
            .aces => @as(u32, 2),
        } else value;
    }
    return dto;
}

test "C23 DTO layout and all presets cross the C ABI with explicit conversion" {
    try std.testing.expectEqual(@as(u32, 116), c.corex_graphics_size_v1());
    try std.testing.expectEqual(@as(usize, 116), @sizeOf(c.CoreXGraphicsConfigV1));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(c.CoreXGraphicsConfigV1));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.CoreXGraphicsConfigV1, "abi_version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(c.CoreXGraphicsConfigV1, "struct_size"));
    inline for (@typeInfo(presets.Parameters).@"struct".field_names, 0..) |field, i| {
        try std.testing.expectEqual(8 + 4 * i, @offsetOf(c.CoreXGraphicsConfigV1, field));
    }
    var table = try presets.parse(std.testing.allocator, @embedFile("fixtures/presets.zon"));
    defer table.deinit();
    inline for (.{ presets.Name.low, presets.Name.medium, presets.Name.high }) |name| {
        var dto = try translate(try table.value.resolve(name, .{}));
        try std.testing.expectEqual(c.COREX_GRAPHICS_OK, c.corex_graphics_validate_v1(&dto, @sizeOf(@TypeOf(dto))));
    }
}

test "C23 boundary rejects invalid headers flags enums nonfinite and cross-field values" {
    var table = try presets.parse(std.testing.allocator, @embedFile("fixtures/presets.zon"));
    defer table.deinit();
    const original = try translate(try table.value.resolve(.high, .{}));
    var dto = original;
    const size = @sizeOf(@TypeOf(dto));
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_HEADER, c.corex_graphics_validate_v1(null, size));
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_HEADER, c.corex_graphics_validate_v1(&dto, size - 1));
    dto.abi_version = 2;
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_HEADER, c.corex_graphics_validate_v1(&dto, size));
    dto = original;
    dto.shadows_enabled = 2;
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_PARAMETER, c.corex_graphics_validate_v1(&dto, size));
    dto = original;
    dto.tone_mapping = 3;
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_PARAMETER, c.corex_graphics_validate_v1(&dto, size));
    dto = original;
    dto.msaa_samples = 3;
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_PARAMETER, c.corex_graphics_validate_v1(&dto, size));
    dto = original;
    dto.texture_mip_bias = std.math.nan(f32);
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_PARAMETER, c.corex_graphics_validate_v1(&dto, size));
    dto = original;
    dto.draw_distance_m = 10;
    try std.testing.expectEqual(c.COREX_GRAPHICS_INVALID_CONFIGURATION, c.corex_graphics_validate_v1(&dto, size));
}
