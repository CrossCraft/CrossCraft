#version 460 core

layout(location = 0) in vec3 vert_pos;
layout(location = 1) in vec4 vert_color;
layout(location = 2) in vec2 vert_uv;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

// layout(std140, binding = 0) uniform State {
//     mat4 u_view;
//     mat4 u_proj;
//     // TODO: Add more useful variables here
// };

// Per-object push constant
// layout(push_constant) uniform PushConstants {
//     mat4 u_model; // Moved to uniform for simplicity
// } pc;

void main() {
    gl_Position = vec4(vert_pos, 1.0);
    gl_Position.y = -gl_Position.y;
    frag_uv = vert_uv;
    frag_color = vert_color;
}
