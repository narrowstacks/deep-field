extension ShaderSource {
    static let common = """
#include <metal_stdlib>
using namespace metal;

// Uniform layouts; each mirrors its Swift counterpart in Rendering/GPUTypes.swift.

struct BakeParams {
    float width; float height; float camDist; float camElev;
    float tanHalfFov; float diskIn; float diskOut; float roll;
    float shellR0; float shellR1; float throat; float starDensity;
    float lensing; float galaxies; float lookX; float lookY;   // lensing: 0 none, 1 black hole, 2 wormhole
    float milkyWay; float nebulaType; float nebulaSeed; float shells;   // shells: 1 = record planet shell crossings
    float skySeed;   // 0 = the original sky; otherwise the star field is turned to a new orientation
};

struct FrameParams {
    float time; float levels; float diskIn; float diskOut;
    float exposure; float diskSpeed; float flowPeriod; float planetCount;
    float shellR0; float shellR1; float saturation; float scene;
    float dither; float twinkle; float pulsars; float skyBrightness;
    float pixelAngle; float starCount; float lightCount; float ringStrength;   // pixelAngle: radians per drawable pixel
    float nebulaType; float screenScale;   // screenScale: screen-space scenes' units per half height
    float twinkleBrightness; float twinkleSpeed;
    float4 camPos; float4 camRight; float4 camUp;   // camRight.w / camUp.w = drawable width / height
    float4 image;    // contrast, black point, highlight rolloff, vignette
    float4 bloom;    // amount, threshold, 1 = the scene pass writes linear light for the bloom passes, radius (glow scale in imageFragment)
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
struct SceneParams { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; float4 g; float4 h; float4 i; float4 j; float4 k; float4 l; float4 m; float4 n; float4 o; float4 p; };

struct Galaxy {
    float4 shape;    // type (0 spiral, 1 barred, 2 elliptical, 3 irregular, 4 ring), arms, tan(pitch), bar length
    float4 motion;   // pattern angle, velocity scale, dark matter, flow period (s)
    float4 core; float4 arms; float4 nebula; float4 dust;
    float4 misc;     // radius, solid-body angle
};

// x squared. (pow(x, 2.0) is undefined for negative x in Metal.)
static float sq(float x) { return x * x; }

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

// Slots a scene doesn't use are bound to a 1x1 placeholder, so kernels only write the slots
// their scene allocates (see Renderer.Slot).
#define BAKE_OUTPUTS \\
    texture2d<float, access::write> hitA     [[texture(0)]], \\
    texture2d<float, access::write> hitB     [[texture(1)]], \\
    texture2d<float, access::write> shell0P  [[texture(3)]], \\
    texture2d<float, access::write> shell0D  [[texture(4)]], \\
    texture2d<float, access::write> shell1P  [[texture(5)]], \\
    texture2d<float, access::write> shell1D  [[texture(6)]], \\
    texture2d<float, access::write> dirTex   [[texture(7)]], \\
    texture2d<float, access::write> infoTex  [[texture(8)]], \\
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
    texture2d<float> dirTex   [[texture(7)]], \\
    texture2d<float> infoTex  [[texture(8)]], \\
    texture2d<uint>  idTex    [[texture(9)]], \\
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

// The image controls, on light already scaled by the exposure: contrast around a mid gray,
// highlight rolloff and vignette, then the tone map and black point. Each is skipped at its
// neutral value, so the defaults leave the output exactly as it was.
static float3 toneMapped(float3 x, uint2 p, constant FrameParams& F) {
    float4 im = F.image;
    if (im.x != 1.0) x = 0.18 * pow(x / 0.18, im.x);
    if (im.z > 0.0) x = x / (1.0 + im.z * x);
    if (im.w > 0.0) {
        float2 uv = (float2(p) + 0.5) / float2(F.camRight.w, F.camUp.w) * 2.0 - 1.0;
        x *= 1.0 - im.w * smoothstep(0.2, 1.6, dot(uv, uv));
    }
    float3 col = 1.0 - exp(-x);
    if (im.y > 0.0) {
        float b = pow(im.y, 2.2);      // the black point is set in display (gamma) terms
        col = max(col - b, 0.0) / (1.0 - b);
    }
    return col;
}

// Saturate, gamma encode, and posterize with the ordered dither.
static float4 quantized(float3 col, uint2 p, constant FrameParams& F) {
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = max(mix(float3(luma), col, F.saturation), 0.0);
    col = pow(col, float3(1.0 / 2.2));
    float L = F.levels - 1.0;
    float d = F.dither < 0.5 ? bayer8(p) : (F.dither < 1.5 ? bayer4(p) : 0.5);
    col = floor(col * L + d) / L;
    return float4(saturate(col), 1.0);
}

// Every scene ends here. With bloom on, the scene pass instead writes its linear light to a
// float target, and imageFragment finishes it (with the glow added) after the bloom passes.
static float4 finalize(float3 col, uint2 p, constant FrameParams& F) {
    if (F.bloom.z > 0.5) return float4(col, 1.0);
    return quantized(toneMapped(max(col, 0.0) * F.exposure, p, F), p, F);
}

// ---------- bloom: bright pass at quarter size, separable blur, composite ----------

// Linear light above the threshold (on the tone-mapped luminance), soft-kneed, in exposed units.
// Each pixel's light is capped first: a star (and more so a twinkling one) is a pixel or two far
// brighter than anything around it, and uncapped it would spread into a wide square halo.
static float3 brightPart(float3 col, constant FrameParams& F) {
    float3 x = max(col, 0.0) * F.exposure;
    float l = dot(x, float3(0.2126, 0.7152, 0.0722));
    if (l > 2.5) x *= 2.5 / l;
    float lum = 1.0 - exp(-min(l, 2.5));
    return x * smoothstep(F.bloom.y, F.bloom.y + 0.3, lum);
}

// Each output texel covers 4x4 scene pixels. They're averaged with weights that fall with
// brightness (a Karis average): an even bright region keeps its plain mean, while a lone hot
// pixel among dark ones counts for much less, so it can't light up a halo on its own.
kernel void bloomBright(texture2d<float> hdr [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant FrameParams& F [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 size = uint2(hdr.get_width(), hdr.get_height());
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (uint y = 0; y < 4; y++) {
        for (uint x = 0; x < 4; x++) {
            uint2 q = min(gid * 4u + uint2(x, y), size - 1u);
            float3 b = brightPart(hdr.read(q).rgb, F);
            float w = 1.0 / (1.0 + dot(b, float3(0.2126, 0.7152, 0.0722)));
            sum += b * w;
            wsum += w;
        }
    }
    dst.write(float4(sum / wsum, 1.0), gid);
}

// Halves the bright pass for wide glows: each output texel is the mean of the 4x4 texels round
// its center, read as four bilinear taps. Blurring a smaller copy keeps the blur's taps about a
// texel apart; spread wider, they copy a sharp edge (Earth's limb) into rings and streaks.
kernel void bloomDown(texture2d<float> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 c = float2(gid) * 2.0 + 1.0;
    float3 sum = src.sample(s, c + float2(-1.0, -1.0)).rgb + src.sample(s, c + float2(1.0, -1.0)).rgb
               + src.sample(s, c + float2(-1.0, 1.0)).rgb + src.sample(s, c + float2(1.0, 1.0)).rgb;
    dst.write(float4(sum * 0.25, 1.0), gid);
}

// A 17-tap Gaussian along `dir`, sigma in texels; taps spread to cover about 2.7 sigma. The
// renderer keeps sigma at 3 texels or less (see bloomDown), so the taps stay a texel apart.
kernel void bloomBlur(texture2d<float> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float4& B [[buffer(0)]],      // direction xy, sigma
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float sigma = max(B.z, 0.5);
    float step_ = sigma / 3.0;
    float2 c = float2(gid) + 0.5;
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int i = -8; i <= 8; i++) {
        float o = float(i) * step_;
        float w = exp(-0.5 * o * o / (sigma * sigma));
        sum += src.sample(s, c + B.xy * o).rgb * w;
        wsum += w;
    }
    dst.write(float4(sum / wsum, 1.0), gid);
}

// The glow read with a cubic B-spline (four bilinear taps) instead of plain bilinear, so a glow
// blurred on a small texture comes back smooth instead of in visible diamonds and patches.
// `pos` is in the texture's pixels.
static float3 smoothGlow(texture2d<float> t, float2 pos) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 tc = pos - 0.5;
    float2 i = floor(tc), f = tc - i;
    float2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    float2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    float2 w3 = f * f * f / 6.0;
    float2 w2 = 1.0 - w0 - w1 - w3;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 p0 = i - 0.5 + w1 / g0, p1 = i + 1.5 + w3 / g1;
    return g0.y * (g0.x * t.sample(s, float2(p0.x, p0.y)).rgb + g1.x * t.sample(s, float2(p1.x, p0.y)).rgb)
         + g1.y * (g0.x * t.sample(s, float2(p0.x, p1.y)).rgb + g1.x * t.sample(s, float2(p1.x, p1.y)).rgb);
}

fragment float4 imageFragment(VOut in [[stage_in]],
                              texture2d<float> hdr [[texture(0)]],
                              texture2d<float> glow [[texture(1)]],
                              constant FrameParams& F [[buffer(0)]]) {
    uint2 p = uint2(in.pos.xy);
    // F.bloom.w here is the glow texture's size relative to the frame (the renderer sets it)
    float3 x = max(hdr.read(p).rgb, 0.0) * F.exposure + smoothGlow(glow, (float2(p) + 0.5) * F.bloom.w) * F.bloom.x;
    return quantized(toneMapped(x, p, F), p, F);
}

// ---------- scene transitions between two finished frames ----------
// T[0] = progress (eased, 0..1), seed, style, -; T[1] = levels and dither of the outgoing and
// incoming looks. Positions are in units of the frame's height, x running 0..aspect.

static float ditherAt(uint2 p, float kind) { return kind < 0.5 ? bayer8(p) : (kind < 1.5 ? bayer4(p) : 0.5); }

// Dithers a blended color back onto the levels, so a transition stays on the wallpaper's
// palette. A color already on a level comes back unchanged (the 0.02 margin absorbs its 8-bit
// rounding), so the parts of a frame that aren't moving or mixing keep their exact pixels.
static float3 requantize(float3 c, uint2 p, float levels, float dither) {
    float L = max(levels - 1.0, 1.0);
    return saturate(floor(c * L + 0.02 + 0.96 * ditherAt(p, dither)) / L);
}

// Bilinear, so a moved or scaled frame is smoothed before it's dithered again; mirrored, so a
// soft edge that reaches past the frame shows something plausible rather than a smear.
static float3 sampleAt(texture2d<float> tex, float2 pos, float aspect) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    return tex.sample(s, pos / float2(aspect, 1.0)).rgb;
}

// A moved or scaled frame, averaged over a disk of `radius` source pixels first. Resampled as it
// is, its dither cells beat against the new dither into blocky checks; averaged, the dither is
// smoothed back toward the light it stood for. Radius 0 is a plain sample, so the end of a
// transition lands on the exact frame.
static float3 sampleSoft(texture2d<float> tex, float2 pos, float aspect, float radius) {
    float3 sum = sampleAt(tex, pos, aspect);
    if (radius < 0.05) return sum;
    float px = radius / float(tex.get_height());
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.785398 + 0.39;
        sum += sampleAt(tex, pos + float2(cos(a), sin(a)) * px * (i % 2 == 0 ? 1.0 : 0.55), aspect);
    }
    return sum / 9.0;
}

fragment float4 transitionFragment(VOut in [[stage_in]],
                                   texture2d<float> from [[texture(0)]],
                                   texture2d<float> to [[texture(1)]],
                                   constant float4* T [[buffer(0)]]) {
    uint2 p = uint2(in.pos.xy);
    float t = T[0].x, seed = T[0].y, style = T[0].z;
    float2 size = float2(from.get_width(), from.get_height());
    float aspect = size.x / size.y;
    float2 q = (float2(p) + 0.5) / size.y;
    float2 c = float2(aspect * 0.5, 0.5);

    if (style < 0.5) {
        // Dissolve: each pixel switches once the progress passes its own threshold, mostly a
        // broad noise field (the new scene grows in from soft patches) plus a Bayer term that
        // turns each patch's edge into a dithered gradient instead of a line.
        float n = smoothstep(0.25, 0.75, fbm(float3(q * 2.2, seed)));
        float threshold = 0.65 * n + 0.35 * bayer8(p);
        return threshold < t * 1.02 - 0.01 ? to.read(p) : from.read(p);
    }

    float3 a, b;     // outgoing and incoming light at this pixel
    float w;         // how much of the incoming look shows
    if (style < 1.5) {
        // Crossfade
        a = from.read(p).rgb; b = to.read(p).rgb; w = t;
    } else if (style < 2.5) {
        // Pan: the camera slides along a strip with the old frame, a soft band, then the new
        // frame, so the two meet in a wide blend rather than at a seam. The seed picks the side.
        float band = 0.35, dir = fract(seed * 0.37) < 0.5 ? 1.0 : -1.0;
        float u = q.x / aspect;
        if (dir < 0.0) u = 1.0 - u;
        float X = u + t * (1.0 + band);
        float uo = X, un = X - (1.0 + band);
        if (dir < 0.0) { uo = 1.0 - uo; un = 1.0 - un; }
        float soft = 1.5 * sin(3.14159 * t);
        a = sampleSoft(from, float2(uo * aspect, q.y), aspect, soft);
        b = sampleSoft(to, float2(un * aspect, q.y), aspect, soft);
        // past each frame's edge the mirrored sampling would show a reflection; it fades to the
        // dark of space instead, so the gap between the scenes reads as empty sky
        a *= 1.0 - smoothstep(1.0, 1.0 + 0.6 * band, X);
        b *= smoothstep(1.0 + 0.4 * band, 1.0 + band, X);
        w = smoothstep(1.0, 1.0 + band, X);
    } else if (style < 3.5) {
        // Drift away: the old scene recedes, shrinking toward a far corner, while its dark sky
        // fades out first, so its bright objects float away over the new scene, which settles in
        // from slightly closer as the camera arrives.
        float ang = seed * 2.4;
        float2 dir = float2(cos(ang) * aspect * 0.45, sin(ang) * 0.4);
        float sc = mix(1.0, 0.25, t);
        float2 P = c + (q - c - dir * t) / sc;
        a = sampleSoft(from, P, aspect, min(t * 8.0, 1.0) * max(1.5, 0.8 / sc));
        float edge = min(min(P.x, aspect - P.x), min(P.y, 1.0 - P.y));
        float luma = dot(a, float3(0.2126, 0.7152, 0.0722));
        float keep = max(smoothstep(0.08, 0.35, luma), 1.0 - smoothstep(0.0, 0.45, t));
        // the frame's border softens only once it starts to shrink, so the first frame is exact
        float border = mix(1.0, smoothstep(0.0, 0.08, edge), min(t * 10.0, 1.0));
        float alpha = keep * border * (1.0 - smoothstep(0.6, 1.0, t));
        b = sampleSoft(to, c + (q - c) * mix(0.85, 1.0, t), aspect, 2.0 * (1.0 - t));
        w = 1.0 - alpha;
    } else if (style < 4.5) {
        // Warp: flying forward, the old scene streaks outward and a hole opens at the center onto
        // the new one, which settles from a closer view.
        float zoom = 1.0 + 2.5 * t * t;
        a = float3(0.0);
        float soft = min(t * 8.0, 1.0) * 1.5;
        for (int i = 0; i < 4; i++) a += sampleSoft(from, c + (q - c) / (zoom * (1.0 + 0.05 * float(i) * t)), aspect, soft);
        a *= 0.25;
        b = sampleSoft(to, c + (q - c) * mix(0.7, 1.0, t), aspect, 2.0 * (1.0 - t));
        float R = mix(-0.4, length(c), t);
        w = 1.0 - smoothstep(R, R + 0.4, length(q - c));
    } else {
        // Black hole: a point mass sweeps across, and the new scene lies behind its path. Each
        // pixel sees the source position of the lens equation, beta = theta - thetaE^2 theta/|theta|^2,
        // so the boundary between the scenes bends into an Einstein ring around it.
        float thE = 0.2 * sin(3.14159 * t);
        float2 L = float2(mix(-0.5, aspect + 0.5, t), 0.5 + 0.12 * sin(seed * 1.7));
        float2 d = q - L;
        float r2 = max(dot(d, d), 1e-6), r = sqrt(r2);
        float2 src = q - thE * thE * d / r2;
        float soft = 1.5 * sin(3.14159 * t);
        a = sampleSoft(from, src, aspect, soft);
        b = sampleSoft(to, src, aspect, soft);
        w = smoothstep(-0.15, 0.15, L.x - src.x);
        float3 col = mix(a, b, w);
        col *= smoothstep(0.45 * thE, 0.8 * thE, r);                                   // shadow
        col += 0.25 * (thE / 0.2) * exp(-sq((r - thE) / (0.06 * thE + 0.002))) * float3(1.0, 0.85, 0.7);   // photon ring
        bool late = w > 0.5;
        return float4(requantize(col, p, late ? T[1].z : T[1].x, late ? T[1].w : T[1].y), 1.0);
    }
    bool late = w > 0.5;
    return float4(requantize(mix(a, b, w), p, late ? T[1].z : T[1].x, late ? T[1].w : T[1].y), 1.0);
}
"""
}
