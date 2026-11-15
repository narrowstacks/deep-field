extension ShaderSource {
    static let common = """
#include <metal_stdlib>
using namespace metal;

// Uniform layouts; each mirrors its Swift counterpart in Rendering/GPUTypes.swift.

struct BakeParams {
    float width; float height; float camDist; float camElev;
    float tanHalfFov; float diskIn; float diskOut; float roll;
    float shellR0; float shellR1; float throat; float starDensity;
    float scene; float galaxies; float lookX; float lookY;
    float milkyWay; float nebulaType; float nebulaSeed;
};

struct FrameParams {
    float time; float levels; float diskIn; float diskOut;
    float exposure; float diskSpeed; float flowPeriod; float planetCount;
    float shellR0; float shellR1; float saturation; float scene;
    float dither; float twinkle; float pulsars; float skyBrightness;
    float pixelAngle; float starCount; float lightCount; float ringStrength;   // pixelAngle: radians per drawable pixel
    float4 camPos; float4 camRight; float4 camUp;   // camRight.w / camUp.w = drawable width / height
};

struct Palette {
    float4 receding; float4 approaching; float4 core; float4 ring;
    float4 nebulaA; float4 nebulaB; float4 farA; float4 farB;
    float4 starWarm; float4 starCool; float4 galaxy;
};

// Occasional phenomena, scheduled on the CPU (see EventSchedule).
struct Events {
    float4 snDir;      // supernova sky direction, w = core brightness
    float4 snParams;   // halo brightness, echo radius (rad), echo brightness, cooling 0..1
    float4 cometHead;  // sky direction, w = brightness
    float4 cometTail;  // tail-end direction, w = head width (rad)
    float4 farSn;      // far-universe supernova direction, w = core brightness
    float4 farSnParams;// halo, cooling
    float4 flare;      // rim angle, brightness, angular spread
    float4 obj;        // infalling/emerging object: pixel x, y, brightness, size
    float4 objDir;     // screen velocity direction, tangential stretch
    float4 throat;     // throat center (pixels), radius (pixels)
};

struct Planet {
    float4 center;   // xyz position, w = shell index
    float4 colorA;   // rgb, w = radius
    float4 colorB;   // rgb, w = noise seed
    float4 misc;     // x = spin angle, y = band frequency, z = atmosphere strength
};

struct Star {
    float4 pos;      // xyz, w = radius
    float4 color;    // rgb, w = glow scale
    float4 misc;     // x = spin angle, y = seed, z = spot activity
};

struct Light {
    float4 pos;      // xyz, w = intensity
    float4 color;
};

// Per-scene slots; each fragment shader documents its own use of them.
struct SceneParams { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; };

struct Galaxy {
    float4 shape;    // type (0 spiral, 1 barred, 2 elliptical, 3 irregular, 4 ring), arms, tan(pitch), bar length
    float4 motion;   // pattern angle, velocity scale, dark matter, flow period (s)
    float4 core; float4 arms; float4 nebula; float4 dust;
    float4 misc;     // radius, solid-body angle
};

// ---------- noise ----------

static float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static float noise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + float3(1, 0, 0));
    float n010 = hash13(i + float3(0, 1, 0));
    float n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1));
    float n101 = hash13(i + float3(1, 0, 1));
    float n011 = hash13(i + float3(0, 1, 1));
    float n111 = hash13(i + float3(1, 1, 1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

static float fbm(float3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        s += a * noise3(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return s / 0.9375;
}

// fbm that fades out octaves finer than the pixel footprint `fp` (in units of p), to avoid aliasing
static float fbmLOD(float3 p, float fp) {
    float s = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 4; i++) {
        float keep = 1.0 - smoothstep(0.25, 0.6, fp * f);
        s += a * (keep > 0.0 ? mix(0.5, noise3(p), keep) : 0.5);   // fully faded octaves cost nothing
        p = p * 2.03 + 17.1;
        f *= 2.03;
        a *= 0.5;
    }
    return s / 0.9375;
}

// ---------- octahedral direction encoding ----------

static float2 octEncode(float3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    float2 e = n.xz;
    if (n.y < 0.0) e = (1.0 - abs(e.yx)) * float2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
    return e;
}

static float3 octDecode(float2 e) {
    float3 n = float3(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
    if (n.y < 0.0) n.xz = (1.0 - abs(n.zx)) * float2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

// ---------- entry point signatures ----------

#define BAKE_OUTPUTS \\
    texture2d<float, access::write> hitA     [[texture(0)]], \\
    texture2d<float, access::write> hitB     [[texture(1)]], \\
    texture2d<float, access::write> skyTex   [[texture(2)]], \\
    texture2d<float, access::write> shell0P  [[texture(3)]], \\
    texture2d<float, access::write> shell0D  [[texture(4)]], \\
    texture2d<float, access::write> shell1P  [[texture(5)]], \\
    texture2d<float, access::write> shell1D  [[texture(6)]], \\
    texture2d<float, access::write> extraTex [[texture(7)]], \\
    constant BakeParams& P [[buffer(0)]], \\
    uint2 gid [[thread_position_in_grid]]

struct VOut { float4 pos [[position]]; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

#define FRAME_INPUTS \\
    VOut in [[stage_in]], \\
    texture2d<float> hitA     [[texture(0)]], \\
    texture2d<float> hitB     [[texture(1)]], \\
    texture2d<float> skyTex   [[texture(2)]], \\
    texture2d<float> shell0P  [[texture(3)]], \\
    texture2d<float> shell0D  [[texture(4)]], \\
    texture2d<float> shell1P  [[texture(5)]], \\
    texture2d<float> shell1D  [[texture(6)]], \\
    texture2d<float> extraTex [[texture(7)]], \\
    constant FrameParams& F   [[buffer(0)]], \\
    constant Planet* planets  [[buffer(1)]], \\
    constant Events& E        [[buffer(2)]], \\
    constant Palette& Pal     [[buffer(3)]], \\
    constant Star* stars      [[buffer(4)]], \\
    constant Light* lights    [[buffer(5)]], \\
    constant Galaxy& G        [[buffer(6)]], \\
    constant SceneParams& S   [[buffer(7)]]

// ---------- per-frame output: tone map, saturate, posterize with ordered dither ----------

static float bayer8(uint2 p) {
    uint x = p.x & 7u, y = p.y & 7u;
    uint xy = x ^ y;
    uint v = ((xy & 1u) << 5) | ((x & 1u) << 4) | ((xy & 2u) << 2)
           | ((x & 2u) << 1) | ((xy & 4u) >> 1) | ((x & 4u) >> 2);
    return (float(v) + 0.5) / 64.0;
}

static float bayer4(uint2 p) {
    uint x = p.x & 3u, y = p.y & 3u;
    uint xy = x ^ y;
    uint v = ((xy & 1u) << 3) | ((x & 1u) << 2) | (xy & 2u) | ((x & 2u) >> 1);
    return (float(v) + 0.5) / 16.0;
}

static float4 finalize(float3 col, uint2 p, constant FrameParams& F) {
    col = 1.0 - exp(-max(col, 0.0) * F.exposure);
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = max(mix(float3(luma), col, F.saturation), 0.0);
    col = pow(col, float3(1.0 / 2.2));
    float L = F.levels - 1.0;
    float d = F.dither < 0.5 ? bayer8(p) : (F.dither < 1.5 ? bayer4(p) : 0.5);
    col = floor(col * L + d) / L;
    return float4(saturate(col), 1.0);
}
"""
}
