#version 460 core

layout(location = 0) out vec4 out_color;

in vec2 frag_uv;
in vec4 frag_color;

layout(binding = 0) uniform sampler2D u_texture;

void main() {
    out_color = texture(u_texture, frag_uv) * frag_color;
}
