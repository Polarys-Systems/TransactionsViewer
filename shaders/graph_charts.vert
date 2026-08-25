#version 460

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out vec4 frag_pos;
layout(location = 3) out vec2 frag_screen_size;

#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 2, std140) uniform WindowData {
    vec2 screen_size;
    vec2 _padding;
} window_buffers[];

layout(push_constant) uniform PushConstants {
    uint window_index;
} pc;

void main() {
	vec2 screen_size = window_buffers[nonuniformEXT(pc.window_index)].screen_size;
	vec2 ndc = (inPos / screen_size) * 2.0 - 1.0;
	gl_Position = vec4(ndc, 0.0, 1.0);
	frag_uv = inUV;
	frag_color = inColor;
	frag_pos = gl_Position;
	frag_screen_size = screen_size;
}
