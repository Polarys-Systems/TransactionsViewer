#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(push_constant) uniform PushConstants {
    uint texture_index;
    uint sampler_index;
} pc;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 sample_color = texture(sampler2D(
        textures[nonuniformEXT(pc.texture_index)],
        samplers[nonuniformEXT(pc.sampler_index)]
    ), frag_uv);
    out_color = sample_color * frag_color;
}
