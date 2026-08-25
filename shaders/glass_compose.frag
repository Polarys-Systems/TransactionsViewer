#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform ComposePush {
    float tint;
    uint texture_index;
    uint sampler_index;
} pc;

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec4 c = texture(sampler2D(
        textures[nonuniformEXT(pc.texture_index)],
        samplers[nonuniformEXT(pc.sampler_index)]
    ), frag_uv);
    out_color = vec4(c.rgb * (1.0 + pc.tint), c.a);
}
