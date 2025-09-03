#version 460 core

layout(location = 0) in vec3 vert_pos;
layout(location = 1) in vec4 vert_color;
layout(location = 2) in vec2 vert_uv;

out vec2 frag_uv;
out vec4 frag_color;

layout(std140, binding = 0) uniform State {
    mat4 u_view;
    mat4 u_proj;
    // TODO: Add more useful variables here
};

// Per-object data
uniform mat4 u_model;

void main() {
    gl_Position = u_proj * u_view * u_model * vec4(vert_pos, 1.0);
    frag_uv = vert_uv;
    frag_color = vert_color;
}
