#version 460

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color_top;
layout(location = 2) in vec4 frag_color_bottom;
layout(location = 3) in vec2 frag_corner;

layout(location = 0) out vec4 out_color;

float compute_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

	return d;
}

void main() {
	out_color = mix(frag_color_top, frag_color_bottom, frag_corner.y);
}
