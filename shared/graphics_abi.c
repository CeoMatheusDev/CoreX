#include "graphics_abi.h"
#include <float.h>
#include <math.h>
#include <stddef.h>

static_assert(sizeof(float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128 && FLT_MIN_EXP == -125,
              "graphics ABI requires IEEE-754 binary32");
static_assert(alignof(CoreXGraphicsConfigV1) == 4, "V1 alignment changed");
static_assert(sizeof(CoreXGraphicsConfigV1) == 116, "V1 size changed");
static_assert(offsetof(CoreXGraphicsConfigV1, abi_version) == 0, "header offset");
static_assert(offsetof(CoreXGraphicsConfigV1, struct_size) == 4, "size offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadows_enabled) == 8, "shadows_enabled offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_map_size) == 12, "shadow_map_size offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_cascades) == 16, "shadow_cascades offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_distance_m) == 20, "shadow_distance_m offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_depth_bias) == 24, "shadow_depth_bias offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_slope_bias) == 28, "shadow_slope_bias offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_normal_offset_m) == 32, "shadow_normal_offset_m offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_cascade_split_lambda) == 36, "shadow_cascade_split_lambda offset");
static_assert(offsetof(CoreXGraphicsConfigV1, shadow_pcf_kernel) == 40, "shadow_pcf_kernel offset");
static_assert(offsetof(CoreXGraphicsConfigV1, msaa_samples) == 44, "msaa_samples offset");
static_assert(offsetof(CoreXGraphicsConfigV1, draw_distance_m) == 48, "draw_distance_m offset");
static_assert(offsetof(CoreXGraphicsConfigV1, texture_max_dimension) == 52, "texture_max_dimension offset");
static_assert(offsetof(CoreXGraphicsConfigV1, texture_mip_bias) == 56, "texture_mip_bias offset");
static_assert(offsetof(CoreXGraphicsConfigV1, texture_anisotropy) == 60, "texture_anisotropy offset");
static_assert(offsetof(CoreXGraphicsConfigV1, post_processing_enabled) == 64, "post_processing_enabled offset");
static_assert(offsetof(CoreXGraphicsConfigV1, bloom_enabled) == 68, "bloom_enabled offset");
static_assert(offsetof(CoreXGraphicsConfigV1, bloom_threshold) == 72, "bloom_threshold offset");
static_assert(offsetof(CoreXGraphicsConfigV1, bloom_soft_knee) == 76, "bloom_soft_knee offset");
static_assert(offsetof(CoreXGraphicsConfigV1, bloom_intensity) == 80, "bloom_intensity offset");
static_assert(offsetof(CoreXGraphicsConfigV1, bloom_levels) == 84, "bloom_levels offset");
static_assert(offsetof(CoreXGraphicsConfigV1, ambient_occlusion_enabled) == 88, "ambient_occlusion_enabled offset");
static_assert(offsetof(CoreXGraphicsConfigV1, ao_radius_m) == 92, "ao_radius_m offset");
static_assert(offsetof(CoreXGraphicsConfigV1, ao_depth_bias_m) == 96, "ao_depth_bias_m offset");
static_assert(offsetof(CoreXGraphicsConfigV1, ao_intensity) == 100, "ao_intensity offset");
static_assert(offsetof(CoreXGraphicsConfigV1, ao_samples) == 104, "ao_samples offset");
static_assert(offsetof(CoreXGraphicsConfigV1, tone_mapping) == 108, "tone_mapping offset");
static_assert(offsetof(CoreXGraphicsConfigV1, exposure_ev) == 112, "exposure_ev offset");

uint32_t corex_graphics_size_v1(void) { return (uint32_t)sizeof(CoreXGraphicsConfigV1); }

int32_t corex_graphics_validate_v1(const CoreXGraphicsConfigV1 *p, uint32_t size) {
    if (p == NULL || size != sizeof(*p)) return COREX_GRAPHICS_INVALID_HEADER;
    if (p->abi_version != 1 || p->struct_size != sizeof(*p))
        return COREX_GRAPHICS_INVALID_HEADER;
    if (p->shadows_enabled > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->shadow_distance_m)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->shadow_depth_bias)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->shadow_slope_bias)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->shadow_normal_offset_m)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->shadow_cascade_split_lambda)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->draw_distance_m)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->texture_mip_bias)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->post_processing_enabled > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->bloom_enabled > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->bloom_threshold)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->bloom_soft_knee)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->bloom_intensity)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->ambient_occlusion_enabled > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->ao_radius_m)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->ao_depth_bias_m)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->ao_intensity)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->tone_mapping > 2) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (!isfinite(p->exposure_ev)) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_map_size != 256 && p->shadow_map_size != 512 && p->shadow_map_size != 1024 && p->shadow_map_size != 2048 && p->shadow_map_size != 4096 && p->shadow_map_size != 8192) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_pcf_kernel != 1 && p->shadow_pcf_kernel != 3 && p->shadow_pcf_kernel != 5) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->msaa_samples != 1 && p->msaa_samples != 2 && p->msaa_samples != 4 && p->msaa_samples != 8) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->texture_max_dimension != 256 && p->texture_max_dimension != 512 && p->texture_max_dimension != 1024 && p->texture_max_dimension != 2048 && p->texture_max_dimension != 4096 && p->texture_max_dimension != 8192 && p->texture_max_dimension != 16384) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->texture_anisotropy != 1 && p->texture_anisotropy != 2 && p->texture_anisotropy != 4 && p->texture_anisotropy != 8 && p->texture_anisotropy != 16) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->ao_samples != 8 && p->ao_samples != 16 && p->ao_samples != 32 && p->ao_samples != 64) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_cascades < 1 || p->shadow_cascades > 4) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_distance_m <= 0 || p->shadow_distance_m > 100000) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_depth_bias < 0 || p->shadow_depth_bias > 0.01) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_slope_bias < 0 || p->shadow_slope_bias > 8) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_normal_offset_m < 0 || p->shadow_normal_offset_m > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_cascade_split_lambda < 0 || p->shadow_cascade_split_lambda > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->draw_distance_m <= 0 || p->draw_distance_m > 100000) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->texture_mip_bias < -4 || p->texture_mip_bias > 4) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->bloom_threshold < 0 || p->bloom_threshold > 64) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->bloom_soft_knee < 0 || p->bloom_soft_knee > 1) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->bloom_intensity < 0 || p->bloom_intensity > 2) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->bloom_levels < 1 || p->bloom_levels > 8) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->ao_radius_m <= 0 || p->ao_radius_m > 10) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->ao_depth_bias_m < 0 || p->ao_depth_bias_m > 0.5) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->ao_intensity < 0 || p->ao_intensity > 4) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->exposure_ev < -16 || p->exposure_ev > 16) return COREX_GRAPHICS_INVALID_PARAMETER;
    if (p->shadow_distance_m > p->draw_distance_m || p->ao_depth_bias_m >= p->ao_radius_m)
        return COREX_GRAPHICS_INVALID_CONFIGURATION;
    return COREX_GRAPHICS_OK;
}
