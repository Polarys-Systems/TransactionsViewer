#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform BlurPush {
    vec2 direction;
    vec2 texel;
    uint texture_index;
    uint sampler_index;
} pc;

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

vec3 sample_src(vec2 uv) {
    return texture(sampler2D(
        textures[nonuniformEXT(pc.texture_index)],
        samplers[nonuniformEXT(pc.sampler_index)]
    ), uv).rgb;
}

void main() {
    vec2 d = pc.direction * pc.texel;
    vec3 c = sample_src(frag_uv) * 0.227027;
    c += sample_src(frag_uv + d * 1.384615) * 0.316216;
    c += sample_src(frag_uv - d * 1.384615) * 0.316216;
    c += sample_src(frag_uv + d * 3.230769) * 0.070270;
    c += sample_src(frag_uv - d * 3.230769) * 0.070270;
    out_color = vec4(c, 1.0);
}
