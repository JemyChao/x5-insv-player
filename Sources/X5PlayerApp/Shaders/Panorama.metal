#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 view;        // quaternion (xyz, w): view direction -> capture space
    float4 lensARot;
    float4 lensBRot;
    float4 lensAGeom;   // cx, cy, radiusX, radiusY
    float4 lensBGeom;
    float4 lensAOpt;    // halfFov (rad), gain, mirrorU, mirrorV
    float4 lensBOpt;
    float4 lensAPoly;   // k1..k4
    float4 lensBPoly;
    float4 render;      // fov (rad), aspect, blend (rad), exposure
    float4 flags;       // mode, hasFrame, guides, seam debug
    float4 color;       // matrix (0 = 709, 1 = 2020), hlg, reserved, reserved
    float4 horizonUp;   // measured world up in VIEW space (xyz), line half width in dot units (w)
    float4 overlay;     // draw horizon, draw screen level, screen line half width in ndc, unused
};

struct Varying {
    float4 position [[position]];
    float2 uv;
};

constant float3 kBackground = float3(0.020, 0.024, 0.027);

static inline float3 quatRotate(float4 q, float3 v) {
    float3 axis = q.xyz;
    return v + 2.0 * cross(axis, cross(axis, v) + q.w * v);
}

static inline float4 quatConjugate(float4 q) {
    return float4(-q.xyz, q.w);
}

// BT.2100 HLG inverse OETF, followed by a compact roll-off so 10-bit HLG
// captures land somewhere sane on an SDR display.
static inline float hlgInverse(float value) {
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    return (value <= 0.5) ? (value * value / 3.0) : ((exp((value - c) / a) + b) / 12.0);
}

static inline float3 hlgToDisplay(float3 encoded) {
    float3 scene = float3(hlgInverse(encoded.r), hlgInverse(encoded.g), hlgInverse(encoded.b));
    float luma = dot(scene, float3(0.2627, 0.6780, 0.0593));
    scene *= pow(max(luma, 1e-5), 0.2);
    scene = scene / (1.0 + scene);
    return pow(clamp(scene * 1.75, 0.0, 1.0), float3(1.0 / 2.2));
}

static inline float3 decodeYUV(texture2d<float> luma,
                               texture2d<float> chroma,
                               float2 uv,
                               constant Uniforms &u) {
    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);
    float y = (luma.sample(bilinear, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
    float2 c = (chroma.sample(bilinear, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);

    float3 rgb;
    if (u.color.x > 0.5) {
        rgb = float3(y + 1.47460 * c.y,
                     y - 0.16455 * c.x - 0.57135 * c.y,
                     y + 1.88140 * c.x);
    } else {
        rgb = float3(y + 1.57480 * c.y,
                     y - 0.18733 * c.x - 0.46813 * c.y,
                     y + 1.85560 * c.x);
    }
    rgb = clamp(rgb, 0.0, 4.0);
    if (u.color.y > 0.5) {
        rgb = hlgToDisplay(rgb);
    }
    return clamp(rgb * u.render.w, 0.0, 1.0);
}

// Maps a direction in lens space (optical axis along +z) onto the fisheye
// circle, and reports how far off-axis the sample was so the caller can fade
// the two lenses into each other.
static inline float2 lensCoordinate(float3 direction,
                                    float4 geom,
                                    float4 opt,
                                    float4 poly,
                                    thread float &theta) {
    theta = acos(clamp(direction.z, -1.0, 1.0));
    float t = theta / max(opt.x, 1e-4);
    float t2 = t * t;
    float radius = poly.x * t + poly.y * t2 + poly.z * t2 * t + poly.w * t2 * t2;
    float2 planar = direction.xy;
    float len = length(planar);
    float2 unit = (len > 1e-6) ? (planar / len) : float2(1.0, 0.0);
    return geom.xy + float2(unit.x * opt.z * geom.z, unit.y * opt.w * geom.w) * radius;
}

vertex Varying fullscreenVertex(uint id [[vertex_id]]) {
    float2 points[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    Varying out;
    out.position = float4(points[id], 0.0, 1.0);
    out.uv = points[id] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

fragment float4 panoramaFragment(Varying in [[stage_in]],
                                 texture2d<float> lumaA [[texture(0)]],
                                 texture2d<float> chromaA [[texture(1)]],
                                 texture2d<float> lumaB [[texture(2)]],
                                 texture2d<float> chromaB [[texture(3)]],
                                 constant Uniforms &u [[buffer(0)]]) {
    if (u.flags.y < 0.5) {
        return float4(kBackground, 1.0);
    }

    int mode = int(u.flags.x + 0.5);
    float aspect = max(u.render.y, 1e-4);

    // Raw lens inspector: the two source circles side by side, with the
    // calibration centre and radius drawn on top so they can be dialled in.
    if (mode == 3) {
        bool second = in.uv.x > 0.5;
        float2 pane = float2(second ? (in.uv.x - 0.5) * 2.0 : in.uv.x * 2.0, in.uv.y);
        float paneAspect = aspect * 0.5;
        float2 t = pane;
        if (paneAspect > 1.0) {
            t.x = (pane.x - 0.5) * paneAspect + 0.5;
        } else {
            t.y = (pane.y - 0.5) / paneAspect + 0.5;
        }
        if (t.x < 0.0 || t.x > 1.0 || t.y < 0.0 || t.y > 1.0) {
            return float4(kBackground, 1.0);
        }
        float3 rgb = second ? decodeYUV(lumaB, chromaB, t, u) : decodeYUV(lumaA, chromaA, t, u);
        if (u.flags.z > 0.5) {
            float4 geom = second ? u.lensBGeom : u.lensAGeom;
            float2 relative = (t - geom.xy) / max(geom.zw, float2(1e-4));
            float ring = 1.0 - smoothstep(0.0, 0.005, abs(length(relative) - 1.0));
            float vertical = 1.0 - smoothstep(0.0, 0.0018, abs(t.x - geom.x));
            float horizontal = 1.0 - smoothstep(0.0, 0.0018, abs(t.y - geom.y));
            float guide = max(ring, max(vertical, horizontal) * 0.7);
            rgb = mix(rgb, float3(0.82, 1.0, 0.30), guide);
        }
        return float4(rgb, 1.0);
    }

    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float3 ray;
    float3 viewRay;

    if (mode == 1) {
        // Equirectangular, letterboxed to 2:1 inside whatever the window is.
        float2 e = (aspect >= 2.0) ? float2(ndc.x * aspect * 0.5, ndc.y)
                                   : float2(ndc.x, ndc.y * 2.0 / aspect);
        if (abs(e.x) > 1.0 || abs(e.y) > 1.0) {
            return float4(kBackground, 1.0);
        }
        float longitude = e.x * M_PI_F;
        float latitude = e.y * M_PI_F * 0.5;
        ray = float3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude));
    } else if (mode == 2) {
        // Little planet: stereographic projection centred on the nadir.
        float2 p = float2(ndc.x * aspect, ndc.y) * (u.render.x / 1.4);
        float r = length(p);
        float theta = 2.0 * atan(r * 0.5);
        float phi = atan2(p.y, p.x);
        ray = float3(sin(theta) * cos(phi), -cos(theta), sin(theta) * sin(phi));
    } else {
        float halfPlane = tan(clamp(u.render.x, 0.05, 3.0) * 0.5);
        ray = normalize(float3(ndc.x * aspect * halfPlane, ndc.y * halfPlane, 1.0));
    }

    viewRay = normalize(ray);
    ray = normalize(quatRotate(u.view, ray));

    float3 directionA = quatRotate(quatConjugate(u.lensARot), ray);
    float3 directionB = quatRotate(quatConjugate(u.lensBRot), ray);

    float thetaA = 0.0;
    float thetaB = 0.0;
    float2 uvA = lensCoordinate(directionA, u.lensAGeom, u.lensAOpt, u.lensAPoly, thetaA);
    float2 uvB = lensCoordinate(directionB, u.lensBGeom, u.lensBOpt, u.lensBPoly, thetaB);

    // Feather each lens out as it approaches its own rim, so the overlap band
    // the two 190-plus degree lenses share becomes a cross-fade instead of a cut.
    float blend = max(u.render.z, 0.002);
    float weightA = 1.0 - smoothstep(u.lensAOpt.x - blend, u.lensAOpt.x, thetaA);
    float weightB = 1.0 - smoothstep(u.lensBOpt.x - blend, u.lensBOpt.x, thetaB);
    if (weightA + weightB < 1e-3) {
        // Outside both lens models: fall back to whichever is looking closer.
        if (thetaA <= thetaB) { weightA = 1.0; } else { weightB = 1.0; }
    }

    float3 rgb = float3(0.0);
    if (weightA > 0.0) {
        rgb += decodeYUV(lumaA, chromaA, uvA, u) * u.lensAOpt.y * weightA;
    }
    if (weightB > 0.0) {
        float3 sampled = decodeYUV(lumaB, chromaB, uvB, u) * u.lensBOpt.y;
        if (u.flags.w > 0.5) {
            sampled = mix(sampled, float3(sampled.r, sampled.g * 0.35, sampled.b * 0.35), 0.65);
        }
        rgb += sampled * weightB;
    }
    rgb /= max(weightA + weightB, 1e-4);

    // Where gravity says the horizon is, drawn in the view's own space so it
    // moves exactly as much as the stabilisation fails to hold it still.
    if (u.overlay.x > 0.5) {
        float height = dot(viewRay, u.horizonUp.xyz);
        float line = 1.0 - smoothstep(0.0, max(u.horizonUp.w, 1e-5), abs(height));
        rgb = mix(rgb, float3(1.0, 0.28, 0.28), line * 0.85);
    }
    // A fixed line through the middle of the window to judge it against.
    if (u.overlay.y > 0.5) {
        float half = max(u.overlay.z, 1e-5);
        float level = 1.0 - smoothstep(0.0, half, abs(ndc.y));
        float centre = 1.0 - smoothstep(0.0, half, abs(ndc.x));
        rgb = mix(rgb, float3(0.82, 1.0, 0.30), max(level, centre * 0.55) * 0.7);
    }

    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
