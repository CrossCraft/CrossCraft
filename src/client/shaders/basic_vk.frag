#version 460 core
#extension GL_EXT_nonuniform_qualifier : enable

layout(set = 1, binding = 0) uniform sampler g_sampler;
layout(set = 1, binding = 1) uniform texture2D g_textures[];

layout(location = 0) out vec4 out_color;
layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(push_constant, std430) uniform PushConstants {
    mat4 u_model;
    uint texture_index;
} pc;

void main() {
    if (pc.texture_index == uint(0)) {
        out_color = frag_color;
    } else {
        uint idx = nonuniformEXT(pc.texture_index);
        out_color = texture(sampler2D(g_textures[idx], g_sampler), frag_uv) * frag_color;
    }
}
