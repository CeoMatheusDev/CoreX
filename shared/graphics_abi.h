#ifndef COREX_APP_GRAPHICS_ABI_H
#define COREX_APP_GRAPHICS_ABI_H

#include <stdint.h>

/* Internal application DTO, NOT engine_api.h and NOT an implemented core API.
 * Native-endian, same-process C ABI only; never a file/network wire format.
 * Caller owns config; callee neither retains pointers nor allocates memory.
 * All logical flags are uint32_t (0/1); enums use documented numeric constants.
 * tone_mapping: 0=none, 1=reinhard, 2=aces. Units/ranges: PRESETS_SCHEMA_V1.md.
 * V1 size and field offsets are tested on both sides. No Zig internal struct
 * or enum is passed directly across this boundary.
 */
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CoreXGraphicsConfigV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t shadows_enabled;
    uint32_t shadow_map_size;
    uint32_t shadow_cascades;
    float shadow_distance_m;
    float shadow_depth_bias;
    float shadow_slope_bias;
    float shadow_normal_offset_m;
    float shadow_cascade_split_lambda;
    uint32_t shadow_pcf_kernel;
    uint32_t msaa_samples;
    float draw_distance_m;
    uint32_t texture_max_dimension;
    float texture_mip_bias;
    uint32_t texture_anisotropy;
    uint32_t post_processing_enabled;
    uint32_t bloom_enabled;
    float bloom_threshold;
    float bloom_soft_knee;
    float bloom_intensity;
    uint32_t bloom_levels;
    uint32_t ambient_occlusion_enabled;
    float ao_radius_m;
    float ao_depth_bias_m;
    float ao_intensity;
    uint32_t ao_samples;
    uint32_t tone_mapping;
    float exposure_ev;
} CoreXGraphicsConfigV1;

#define COREX_GRAPHICS_OK INT32_C(0)
#define COREX_GRAPHICS_INVALID_HEADER INT32_C(-1)
#define COREX_GRAPHICS_INVALID_PARAMETER INT32_C(-2)
#define COREX_GRAPHICS_INVALID_CONFIGURATION INT32_C(-3)

/* Returns a fixed-width status; no exceptions, longjmp or hidden ownership.
 * Null or a buffer of any length other than the V1 size is rejected before
 * dereferencing config. Pointer must be aligned and refer to readable memory
 * of at least buffer_size bytes; this API cannot validate arbitrary addresses.
 * Header version and struct_size must match exactly. No GPU work is performed.
 */
int32_t corex_graphics_validate_v1(const CoreXGraphicsConfigV1 *config,
                                  uint32_t buffer_size);
uint32_t corex_graphics_size_v1(void);

#ifdef __cplusplus
}
#endif
#endif
