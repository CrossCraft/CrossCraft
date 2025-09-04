#version 460 core

layout(location = 0) out vec4 out_color;

in vec2 frag_uv;
in vec4 frag_color;

void main() {
    // TODO: Texture sampling
    out_color = frag_color;
}
