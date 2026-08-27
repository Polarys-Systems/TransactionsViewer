#version 460
#extension GL_EXT_buffer_reference : require

struct Vertex {
    vec2 top_left;
	vec2 bottom_right;
	vec4 color_top;
	vec4 color_bottom; 
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Vertex_Buffer {
    Vertex vertices[];
};

layout(push_constant) uniform Push {
    Vertex_Buffer vertex_buffer;
} pc;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color_top;
layout(location = 2) out vec4 frag_color_bottom;
layout(location = 3) out vec2 frag_corner;

const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main()
{
	vec2 corner = CORNERS[gl_VertexIndex % 6];
    Vertex vertex = pc.vertex_buffer.vertices[gl_InstanceIndex];

    vec2 position = vertex.top_left + corner * (vertex.bottom_right - vertex.top_left);

    gl_Position = vec4(position, 0.0, 1.0);

    frag_uv    = vec2(0, 0);
    frag_color_top = vertex.color_top;
    frag_color_bottom = vertex.color_bottom;
    frag_corner = corner;
}