#version 460

// RectVert2D instance data (one per rect, inputRate = INSTANCE).
layout(location = 0) in vec2 inst_top_left;
layout(location = 1) in vec2 inst_bottom_right;
layout(location = 2) in vec4 inst_color_top;
layout(location = 3) in vec4 inst_color_bottom;
layout(location = 4) in vec2 inst_top_left_uv;
layout(location = 5) in vec2 inst_bottom_right_uv;
layout(location = 6) in float inst_radius;
layout(location = 7) in float inst_edge;
layout(location = 8) in vec4 inst_clip_rect;
layout(location = 9) in uint inst_texture_index;
layout(location = 10) in uint inst_sampler_index;

layout(push_constant) uniform PC {
    float screen_w;
    float screen_h;
} pc;

layout(location = 0) out vec2      frag_local_pos;
layout(location = 1) out flat vec2 frag_half_size;
layout(location = 2) out vec4      frag_color;
layout(location = 3) out vec2      frag_uv;
layout(location = 4) out flat float frag_radius;
layout(location = 5) out flat float frag_edge;
layout(location = 6) out flat vec4 frag_clip_rect;
layout(location = 7) out flat uint frag_texture_index;
layout(location = 8) out flat uint frag_sampler_index;

// Unit quad: two CW triangles covering [0,1]x[0,1].
const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main() {
    vec2 corner = CORNERS[gl_VertexIndex % 6];
    vec2 size = inst_bottom_right - inst_top_left;
    vec2 half_size = size * 0.5;
    vec2 pixel_pos = mix(inst_top_left, inst_bottom_right, corner);

    frag_local_pos = pixel_pos - (inst_top_left + half_size);
    frag_half_size = half_size;
    frag_color     = mix(inst_color_top, inst_color_bottom, corner.y);
    frag_uv        = mix(inst_top_left_uv, inst_bottom_right_uv, corner);
    frag_radius    = inst_radius;
    frag_edge      = inst_edge;
    frag_clip_rect = inst_clip_rect;
    frag_texture_index = inst_texture_index;
    frag_sampler_index = inst_sampler_index;

    // Vulkan coordinates use a top-left origin for this UI pipeline.
    vec2 ndc = (pixel_pos / vec2(pc.screen_w, pc.screen_h)) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
}
