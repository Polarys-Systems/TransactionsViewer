#version 460

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

void main() {
	gl_Position = vec4(inPos, 0.0, 1.0);
	frag_uv = inUV;
	frag_color = inColor;
}
