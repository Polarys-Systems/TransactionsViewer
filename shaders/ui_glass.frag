#version 460

layout(set = 0, binding = 0) uniform sampler2D blur_tex;

layout(push_constant) uniform GlassPush {
    vec2  screen_size;
    float radius_px;
    float border_px;
    float softness_px;
    float tint;
    float distortion;
    float opacity;
    float _0;
} pc;

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 0) out vec4 out_color;

float rounded_rect_sdf(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - (half_size - vec2(radius));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    vec2 frag = gl_FragCoord.xy;
    vec2 screen_uv = frag / max(pc.screen_size, vec2(1.0));

    float wave = sin(frag.y * 0.035) * 0.5 + 0.5;
    vec2 d = vec2((wave - 0.5) * pc.distortion, 0.0);
    vec3 blurred = texture(blur_tex, screen_uv + d).rgb;

    vec3 tint_color = vec3(0.85, 0.92, 1.0);
    vec3 glass = mix(blurred, tint_color, clamp(pc.tint, 0.0, 1.0));

    vec2 px_size = vec2(max(1.0, fwidth(frag_uv.x) > 0.0 ? 1.0 / fwidth(frag_uv.x) : 1.0),
                        max(1.0, fwidth(frag_uv.y) > 0.0 ? 1.0 / fwidth(frag_uv.y) : 1.0));
    vec2 p = (frag_uv - vec2(0.5)) * px_size;
    vec2 half_size = px_size * 0.5;
    float radius = min(pc.radius_px, min(half_size.x, half_size.y) - 0.001);
    float d_sdf = rounded_rect_sdf(p, half_size, max(0.0, radius));

    float mask = 1.0 - smoothstep(0.0, max(0.001, pc.softness_px), d_sdf);
    if (mask <= 0.0) discard;

    if (pc.border_px > 0.0) {
        float inner = 1.0 - smoothstep(-pc.border_px - pc.softness_px, -pc.border_px, d_sdf);
        float border = clamp(mask - inner, 0.0, 1.0);
        glass += border * vec3(0.35);
    }

    out_color = vec4(glass, frag_color.a * pc.opacity * mask);
}
