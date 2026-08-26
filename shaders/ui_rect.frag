#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2       frag_local_pos;
layout(location = 1) in flat vec2  frag_half_size;
layout(location = 2) in vec4       frag_color;
layout(location = 3) in vec2       frag_uv;
layout(location = 4) in flat float frag_radius;
layout(location = 5) in flat float frag_edge;
layout(location = 6) in flat vec4 frag_clip_rect;
layout(location = 7) in flat uint frag_texture_index;
layout(location = 8) in flat uint frag_sampler_index;

layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];

const uint NO_TEXTURE = 0xffffffffu;

float rounded_rect_sdf(vec2 p, vec2 half_size, float radius)
{
    vec2 q = abs(p) - (half_size - vec2(radius));

    return length(max(q, vec2(0.0)))
         + min(max(q.x, q.y), 0.0)
         - radius;
}

void main()
{
    if (gl_FragCoord.x < frag_clip_rect.x || gl_FragCoord.y < frag_clip_rect.y ||
        gl_FragCoord.x >= frag_clip_rect.z || gl_FragCoord.y >= frag_clip_rect.w) {
        discard;
    }

    if (frag_texture_index != NO_TEXTURE) {
        float glyph_alpha = texture(sampler2D(
            textures[nonuniformEXT(frag_texture_index)],
            samplers[nonuniformEXT(frag_sampler_index)]
        ), frag_uv).r;
        if (glyph_alpha <= 0.0) {
            discard;
        }
        out_color = vec4(frag_color.rgb, frag_color.a * glyph_alpha);
        return;
    }

    float max_radius = min(frag_half_size.x, frag_half_size.y);
    float radius = clamp(frag_radius, 0.0, max_radius);

    float distance = rounded_rect_sdf(
        frag_local_pos,
        frag_half_size,
        radius
    );

    // Antialiased outer edge
    float edge = max(frag_edge, fwidth(distance));

    float alpha_mask = 1.0 - smoothstep(0.0, edge, distance);

    if (alpha_mask <= 0.0)
        discard;

    // ------------------------------------------------
    // Bevel
    // ------------------------------------------------

    float bevel_width = 5.0;

    float dist_inside = max(-distance, 0.0);

    // 1 at outer edge, 0 after bevel_width pixels
    float bevel = 1.0 - smoothstep(0.0, bevel_width, dist_inside);

    // ------------------------------------------------
    // Surface normal from SDF
    // ------------------------------------------------

    vec2 gradient = vec2(
        dFdx(distance),
        dFdy(distance)
    );

    float gradient_length = length(gradient);
    if (gradient_length > 0.0) {
        gradient /= gradient_length;
    }

    // Only tilt the surface around the bevel.
    float bevel_strength = 0.7;

    vec3 normal = normalize(vec3(gradient * bevel * bevel_strength, 1.0));

    // Your UI coordinates have +Y downward,
    // so negative Y means light from above.
    vec3 light_dir = normalize(vec3(
        -0.4,
        -0.6,
         1.0
    ));

    float diffuse = max(dot(normal, light_dir), 0.0);

    // ------------------------------------------------
    // Lighting
    // ------------------------------------------------

    // Keep enough ambient lighting that the button
    // doesn't become too dark.
    float ambient          = 0.65;
    float diffuse_strength = 0.35;

    float lighting = ambient + diffuse * diffuse_strength;
    vec3 color     = frag_color.rgb * lighting;

    out_color = vec4(color, frag_color.a * alpha_mask);
}
