#version 460

layout(push_constant) uniform PushConstants {
    float alpha;
    float radius_px;
    float border_px;
    float softness_px;
    int   enable_round;
    int   _0;
    int   _1;
    int   _2;
} pc;

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

float rounded_rect_sdf(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - (half_size - vec2(radius));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    vec3 shaded = frag_color.rgb * (0.85 + 0.15 * frag_uv.y);

    if (pc.enable_round == 0) {
        out_color = vec4(shaded, frag_color.a * pc.alpha);
        return;
    }

    vec2 px_size = vec2(max(1.0, fwidth(frag_uv.x) > 0.0 ? 1.0 / fwidth(frag_uv.x) : 1.0),
                        max(1.0, fwidth(frag_uv.y) > 0.0 ? 1.0 / fwidth(frag_uv.y) : 1.0));
    vec2 p = (frag_uv - vec2(0.5)) * px_size;
    vec2 half_size = px_size * 0.5;
    float radius = min(pc.radius_px, min(half_size.x, half_size.y) - 0.001);
    float d = rounded_rect_sdf(p, half_size, max(0.0, radius));

    float alpha_mask = 1.0 - smoothstep(0.0, max(0.001, pc.softness_px), d);
    if (alpha_mask <= 0.0) {
        discard;
    }

    vec3 final_rgb = shaded;
    if (pc.border_px > 0.0) {
        float inner = 1.0 - smoothstep(-pc.border_px - pc.softness_px, -pc.border_px, d);
        float border = clamp(alpha_mask - inner, 0.0, 1.0);
        final_rgb = mix(final_rgb, vec3(1.0), border * 0.35);
    }

    out_color = vec4(final_rgb, frag_color.a * pc.alpha * alpha_mask);
}
