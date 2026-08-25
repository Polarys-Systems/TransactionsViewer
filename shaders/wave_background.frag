#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    vec4 resolution_time; // xy = resolution, z = time, w = intensity
    vec4 wave_params;     // x = speed, y = amplitude, z = frequency, w = thickness
    vec4 bg_color;
    vec4 wave_color;
} pc;

float wave_line(vec2 uv, float y_offset, float phase, float amp_mul, float freq_mul) {
    float time = pc.resolution_time.z;
    float speed = pc.wave_params.x;
    float amp = pc.wave_params.y * amp_mul;
    float freq = pc.wave_params.z * freq_mul;
    float thickness = pc.wave_params.w;

    float w = 0.0;
    w += sin(uv.x * freq + time * speed + phase) * amp;
    w += sin(uv.x * freq * 1.73 - time * speed * 0.65 + phase * 1.7) * amp * 0.45;
    w += sin(uv.x * freq * 2.41 + time * speed * 1.35 + phase * 0.4) * amp * 0.22;

    float d = abs(uv.y - y_offset - w);

    return smoothstep(thickness, 0.0, d);
}

void main() {
    vec2 uv = v_uv;

    // Aspect correction so waves do not stretch weirdly.
    float aspect = pc.resolution_time.x / pc.resolution_time.y;
    vec2 wave_uv = vec2(uv.x * aspect, uv.y);

    float waves = 0.0;

    waves += wave_line(wave_uv, 0.20, 0.0,  0.70, 1.00);
    waves += wave_line(wave_uv, 0.35, 1.8,  0.85, 0.85);
    waves += wave_line(wave_uv, 0.50, 3.6,  1.00, 1.10);
    waves += wave_line(wave_uv, 0.65, 5.4,  0.80, 0.95);
    waves += wave_line(wave_uv, 0.80, 7.2,  0.65, 1.20);

    waves = clamp(waves * 0.35, 0.0, 1.0);

    // Subtle vertical glow/background gradient.
    float glow = smoothstep(0.0, 1.0, uv.y) * 0.2;

    vec3 color = pc.bg_color.rgb;
    color += glow * pc.wave_color.rgb;
    color = mix(color, pc.wave_color.rgb, waves * pc.resolution_time.w);

    out_color = vec4(color, 1.0);
}