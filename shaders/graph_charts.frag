#version 460

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec4 frag_pos;
layout(location = 3) in vec2 frag_screen_size;

layout(location = 0) out vec4 out_color;

float compute_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

	return d;
}

void main() {
#if 0
	vec2 frag_half_size = frag_screen_size / 2;
	vec2 screen_pos = (frag_pos.xy - 0.5) * frag_screen_size;
	float d = compute_sdf(screen_pos, frag_half_size, 10);

	float alpha = 1.0 - smoothstep(-1.0, 1.0, d);
    out_color = vec4(frag_color.rgb, frag_color.a * alpha);
#else 
	out_color = frag_color;
#endif 
}
