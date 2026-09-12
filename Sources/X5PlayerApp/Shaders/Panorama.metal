#include <metal_stdlib>
using namespace metal;

struct Out { float4 position [[position]]; float2 uv; };
struct ViewUniforms { float yaw; float pitch; float fov; float aspect; uint hasFrame; uint3 padding; };

vertex Out fullscreenVertex(uint id [[vertex_id]]) {
    float2 points[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    Out out; out.position = float4(points[id], 0.0, 1.0); out.uv = points[id] * 0.5 + 0.5; return out;
}

fragment float4 x5FisheyeFragment(Out in [[stage_in]], texture2d<float> lensA [[texture(0)]], texture2d<float> lensB [[texture(1)]], constant ViewUniforms& view [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    if (view.hasFrame == 0) return float4(0.025, 0.03, 0.03, 1.0);
    float2 screen = (in.uv * 2.0 - 1.0) * float2(view.aspect, 1.0);
    float3 ray = normalize(float3(screen * tan(view.fov * 0.5), 1.0));
    float cy = cos(view.yaw), sy = sin(view.yaw), cp = cos(view.pitch), sp = sin(view.pitch);
    ray = float3(cy * ray.x + sy * ray.z, ray.y, -sy * ray.x + cy * ray.z);
    ray = float3(ray.x, cp * ray.y - sp * ray.z, sp * ray.y + cp * ray.z);
    // First-light approximation: replace with the X5 capture calibration from its INSV trailer.
    bool front = ray.z >= 0.0;
    float3 lensRay = front ? ray : float3(-ray.x, ray.y, -ray.z);
    float theta = acos(clamp(lensRay.z, -1.0, 1.0));
    float radius = theta / 2.12;
    float2 direction = normalize(lensRay.xy + float2(0.00001));
    float2 uv = 0.5 + direction * radius * float2(1.0, -1.0);
    float edge = smoothstep(0.70, 0.88, length(uv - 0.5) * 2.0);
    float4 color = front ? lensA.sample(linearSampler, uv) : lensB.sample(linearSampler, uv);
    return mix(color, float4(0.015, 0.02, 0.018, 1.0), edge);
}
