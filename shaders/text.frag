#version 450

#extension GL_EXT_nonuniform_qualifier : require

layout(push_constant) uniform PushConstants {
    vec4 color;
    uint texture_index;
    uint sampler_index;
} pc;

layout(location = 0) in vec2 fragUV;

layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];

void main() {
    float alpha = texture(sampler2D(
        textures[nonuniformEXT(pc.texture_index)],
        samplers[nonuniformEXT(pc.sampler_index)]
    ), fragUV).r;
    outColor = vec4(pc.color.rgb, pc.color.a * alpha);
}
