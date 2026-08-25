#version 460

layout(push_constant) uniform PushConstants {
	float alpha;
} pc;

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

void main() {
	vec3 shaded = frag_color.rgb * (0.85 + 0.15 * frag_uv.y);
	if( frag_uv.x == 0 && frag_uv.y == 0 ) { shaded = frag_color.rgb; }
	out_color = vec4(shaded, frag_color.a * pc.alpha);
}
