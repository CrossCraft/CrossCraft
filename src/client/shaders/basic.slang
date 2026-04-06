struct VertexInput {
    float3 position : POSITION;
    float4 color    : COLOR;
    float2 uv       : TEXCOORD;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD;
    float4 color    : COLOR;
    float viewDepth : VIEWDEPTH;
};

struct CameraState {
    float4x4 view;
    float4x4 proj;
#ifndef VULKAN
    uint fogEnabled;
    float fogStart;
    float fogEnd;
    uint _pad;
    float3 fogColor;
    uint _pad2;
#endif
};

#ifdef VULKAN

[[vk::binding(0, 0)]]
ConstantBuffer<CameraState> camera;

struct PushConstants {
    float4x4 model;
    uint textureIndex;
    uint fogEnabled;
    float fogStart;
    float fogEnd;
    float3 fogColor;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> pc;

[[vk::binding(0, 1)]]
SamplerState g_sampler;

[[vk::binding(1, 1)]]
Texture2D g_textures[];

float4x4 getModel() { return pc.model; }

#else

[[vk::binding(0, 0)]]
ConstantBuffer<CameraState> camera;

struct PerObject {
    float4x4 model;
};

[[vk::binding(1, 0)]]
ConstantBuffer<PerObject> perObject;

[[vk::binding(2, 0)]]
Sampler2D u_combinedTexture;

float4x4 getModel() { return perObject.model; }

#endif

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float4 viewPos = mul(camera.view, mul(getModel(), float4(input.position, 1.0)));
    output.position = mul(camera.proj, viewPos);
    output.viewDepth = -viewPos.z;
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
#ifdef VULKAN
    float4 color;
    if (pc.textureIndex == 0) {
        color = input.color;
    } else {
        uint idx = NonUniformResourceIndex(pc.textureIndex);
        color = g_textures[idx].Sample(g_sampler, input.uv) * input.color;
    }
#else
    float4 color = u_combinedTexture.Sample(input.uv) * input.color;
#endif
    // Vertex alpha == 0 signals "force opaque" (LOD leaves -- skip alpha test)
    if (input.color.a > 0.0 && color.a < 0.5) discard;
#ifdef VULKAN
    if (pc.fogEnabled != 0) {
        float factor = clamp((pc.fogEnd - input.viewDepth) / (pc.fogEnd - pc.fogStart), 0.0, 1.0);
        color.rgb = lerp(pc.fogColor, color.rgb, factor);
    }
#else
    if (camera.fogEnabled != 0) {
        float factor = clamp((camera.fogEnd - input.viewDepth) / (camera.fogEnd - camera.fogStart), 0.0, 1.0);
        color.rgb = lerp(camera.fogColor, color.rgb, factor);
    }
#endif
    return color;
}
