struct VertexInput {
    float3 position : POSITION;
    float4 color    : COLOR;
    float2 uv       : TEXCOORD;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD;
    float4 color    : COLOR;
};

struct CameraState {
    float4x4 view;
    float4x4 proj;
};

#ifdef VULKAN

[[vk::binding(0, 0)]]
ConstantBuffer<CameraState> camera;

struct PushConstants {
    float4x4 model;
    uint textureIndex;
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
    output.position = mul(camera.proj, mul(camera.view, mul(getModel(), float4(input.position, 1.0))));
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
#ifdef VULKAN
    if (pc.textureIndex == 0) {
        return input.color;
    }
    uint idx = NonUniformResourceIndex(pc.textureIndex);
    float4 result = g_textures[idx].Sample(g_sampler, input.uv) * input.color;
#else
    float4 result = u_combinedTexture.Sample(input.uv) * input.color;
#endif
    // Vertex alpha == 0 signals "force opaque" (LOD leaves -- skip alpha test)
    if (input.color.a > 0.0 && result.a < 0.5) discard;
    return result;
}
