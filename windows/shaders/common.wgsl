// Shared WGSL for every module: uniform layouts, noise, direction encoding.
// Ported from Sources/DeepField/Rendering/Shaders/ShaderCommon.swift. Each struct mirrors the one
// of the same name in src/gpu_types.rs field for field; change both together.
// Nothing here declares a binding, so every module (bake, frame, bloom) can include it.

const PI: f32 = 3.14159265358979;

struct BakeParams {
    width: f32, height: f32, camDist: f32, camElev: f32,
    tanHalfFov: f32, diskIn: f32, diskOut: f32, roll: f32,
    shellR0: f32, shellR1: f32, throat: f32, starDensity: f32,
    lensing: f32, galaxies: f32, lookX: f32, lookY: f32,   // lensing: 0 none, 1 black hole, 2 wormhole
    milkyWay: f32, nebulaType: f32, nebulaSeed: f32, shells: f32,   // shells: 1 = record planet shell crossings
    skySeed: f32,   // 0 = the original sky; otherwise the star field is turned to a new orientation
    pad0: f32, pad1: f32, pad2: f32,
}

struct FrameParams {
    time: f32, levels: f32, diskIn: f32, diskOut: f32,
    exposure: f32, diskSpeed: f32, flowPeriod: f32, planetCount: f32,
    shellR0: f32, shellR1: f32, saturation: f32, scene: f32,
    dither: f32, twinkle: f32, pulsars: f32, skyBrightness: f32,
    pixelAngle: f32, starCount: f32, lightCount: f32, ringStrength: f32,   // pixelAngle: radians per drawable pixel
    nebulaType: f32, screenScale: f32,   // screenScale: screen-space scenes' units per half height
    twinkleBrightness: f32, twinkleSpeed: f32,
    camPos: vec4<f32>, camRight: vec4<f32>, camUp: vec4<f32>,   // camRight.w / camUp.w = drawable width / height
    image: vec4<f32>,    // contrast, black point, highlight rolloff, vignette
    bloom: vec4<f32>,    // amount, threshold, 1 = the scene pass writes linear light for the bloom passes, radius
}

struct Palette {
    receding: vec4<f32>, approaching: vec4<f32>, core: vec4<f32>, ring: vec4<f32>,
    nebulaA: vec4<f32>, nebulaB: vec4<f32>, farA: vec4<f32>, farB: vec4<f32>,
    starWarm: vec4<f32>, starCool: vec4<f32>, galaxy: vec4<f32>,
}

// Occasional phenomena, scheduled on the CPU (see events.rs).
struct Events {
    snDir: vec4<f32>,       // supernova sky direction, w = core brightness
    snParams: vec4<f32>,    // halo brightness, echo radius (rad), echo brightness, cooling 0..1
    cometHead: vec4<f32>,   // sky direction, w = brightness
    cometTail: vec4<f32>,   // tail-end direction, w = head width (rad)
    farSn: vec4<f32>,       // far-universe supernova direction, w = core brightness
    farSnParams: vec4<f32>, // halo, cooling
    flare: vec4<f32>,       // rim angle, brightness, angular spread
    obj: vec4<f32>,         // infalling/emerging object: pixel x, y, brightness, size
    objDir: vec4<f32>,      // screen velocity direction, tangential stretch
    throat: vec4<f32>,      // throat center (pixels), radius (pixels)
}

struct Planet {
    center: vec4<f32>,   // xyz position, w = shell index
    colorA: vec4<f32>,   // rgb, w = radius
    colorB: vec4<f32>,   // rgb, w = noise seed
    misc: vec4<f32>,     // x = spin angle, y = band frequency, z = atmosphere strength
}

struct Star {
    pos: vec4<f32>,      // xyz, w = radius
    color: vec4<f32>,    // rgb, w = glow scale
    misc: vec4<f32>,     // x = spin angle, y = seed, z = spot activity
}

struct Light {
    pos: vec4<f32>,      // xyz, w = intensity
    color: vec4<f32>,
}

// Per-scene slots; each fragment shader documents its own use of them.
struct SceneParams {
    a: vec4<f32>, b: vec4<f32>, c: vec4<f32>, d: vec4<f32>,
    e: vec4<f32>, f: vec4<f32>, g: vec4<f32>, h: vec4<f32>,
    i: vec4<f32>, j: vec4<f32>, k: vec4<f32>, l: vec4<f32>,
    m: vec4<f32>, n: vec4<f32>, o: vec4<f32>, p: vec4<f32>,
}

struct Galaxy {
    shape: vec4<f32>,    // type (0 spiral, 1 barred, 2 elliptical, 3 irregular, 4 ring), arms, tan(pitch), bar length
    motion: vec4<f32>,   // pattern angle, velocity scale, dark matter, flow period (s)
    core: vec4<f32>, arms: vec4<f32>, nebula: vec4<f32>, dust: vec4<f32>,
    misc: vec4<f32>,     // radius, solid-body angle
}

struct VOut { @builtin(position) pos: vec4<f32>, }

@vertex
fn fullscreenVertex(@builtin(vertex_index) vid: u32) -> VOut {
    let p = vec2<f32>(f32((vid << 1u) & 2u), f32(vid & 2u));
    var o: VOut;
    o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// x squared. (pow(x, 2.0) is undefined for negative x.)
fn sq(x: f32) -> f32 { return x * x; }

// ---------- noise ----------

fn hash13(p_in: vec3<f32>) -> f32 {
    var p = fract(p_in * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

fn noise3(x: vec3<f32>) -> f32 {
    let i = floor(x);
    var f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    let n000 = hash13(i);
    let n100 = hash13(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = hash13(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = hash13(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = hash13(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = hash13(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = hash13(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = hash13(i + vec3<f32>(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

fn fbm(p_in: vec3<f32>) -> f32 {
    var p = p_in;
    var s = 0.0;
    var a = 0.5;
    for (var i = 0; i < 4; i++) {
        s += a * noise3(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return s / 0.9375;
}

// fbm that fades out octaves finer than the pixel footprint `fp` (in units of p), to avoid aliasing
fn fbmLOD(p_in: vec3<f32>, fp: f32) -> f32 {
    var p = p_in;
    var s = 0.0;
    var a = 0.5;
    var f = 1.0;
    for (var i = 0; i < 4; i++) {
        let keep = 1.0 - smoothstep(0.25, 0.6, fp * f);
        // fully faded octaves cost nothing
        if (keep > 0.0) { s += a * mix(0.5, noise3(p), keep); } else { s += a * 0.5; }
        p = p * 2.03 + 17.1;
        f *= 2.03;
        a *= 0.5;
    }
    return s / 0.9375;
}

// ---------- octahedral direction encoding ----------

fn signNonNeg2(v: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(select(-1.0, 1.0, v.x >= 0.0), select(-1.0, 1.0, v.y >= 0.0));
}

fn octEncode(n_in: vec3<f32>) -> vec2<f32> {
    let n = n_in / (abs(n_in.x) + abs(n_in.y) + abs(n_in.z));
    var e = n.xz;
    if (n.y < 0.0) { e = (1.0 - abs(e.yx)) * signNonNeg2(e); }
    return e;
}

fn octDecode(e: vec2<f32>) -> vec3<f32> {
    var n = vec3<f32>(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
    if (n.y < 0.0) {
        let xz = (1.0 - abs(n.zx)) * signNonNeg2(n.xz);
        n = vec3<f32>(xz.x, n.y, xz.y);
    }
    return normalize(n);
}

// ---------- dither thresholds ----------

fn bayer8(p: vec2<u32>) -> f32 {
    let x = p.x & 7u;
    let y = p.y & 7u;
    let xy = x ^ y;
    let v = ((xy & 1u) << 5u) | ((x & 1u) << 4u) | ((xy & 2u) << 2u)
          | ((x & 2u) << 1u) | ((xy & 4u) >> 1u) | ((x & 4u) >> 2u);
    return (f32(v) + 0.5) / 64.0;
}

fn bayer4(p: vec2<u32>) -> f32 {
    let x = p.x & 3u;
    let y = p.y & 3u;
    let xy = x ^ y;
    let v = ((xy & 1u) << 3u) | ((x & 1u) << 2u) | (xy & 2u) | ((x & 2u) >> 1u);
    return (f32(v) + 0.5) / 16.0;
}

fn bayer2(p: vec2<u32>) -> f32 {
    let x = p.x & 1u;
    let y = p.y & 1u;
    return (f32(((x ^ y) << 1u) | y) + 0.5) / 4.0;
}

// Clustered-dot halftone on a 45 degree screen, like print: thresholds follow a spot function,
// so dots grow from each cell's center and merge into a checkerboard at mid tones.
fn halftone(p: vec2<u32>) -> f32 {
    let q = (vec2<f32>(p) + 0.5) * (PI / 3.0);     // a dot every 3 pixels along each diagonal
    let spot = cos(q.x + q.y) + cos(q.x - q.y);      // -2 (between dots) .. 2 (dot center)
    return 0.5 - 0.245 * spot;
}

// A diagonal line screen in a 4x4 tile: each line's center row fills first, then the rows on
// either side, so tones become stripes of varying weight.
fn diagonalLines(p: vec2<u32>) -> f32 {
    let across = (p.x + p.y) & 3u;                   // 0 = line center
    let acrossRank = select(select(select(3u, 2u, across == 3u), 1u, across == 1u), 0u, across == 0u);
    let along = p.x & 3u;
    let alongRank = (along & 1u) * 2u + (along >> 1u);   // 0, 2, 1, 3: spread along the line
    return (f32(acrossRank * 4u + alongRank) + 0.5) / 16.0;
}

// Uncorrelated per-pixel noise, fixed in place: film-grain-like, with visible clumps.
fn whiteNoise(p: vec2<u32>) -> f32 {
    var h = (p.x * 0x8da6b343u) ^ (p.y * 0xd8163841u);
    h ^= h >> 15u; h *= 0x2c1b3c6du; h ^= h >> 12u; h *= 0x297a2d39u; h ^= h >> 15u;
    return (f32(h >> 8u) + 0.5) / 16777216.0;
}

// ---------- shared geometry (used by several scenes) ----------

// Where a ray (origin ro, unit direction rd) enters and leaves a sphere of radius r at the
// origin; (1, 0) when it misses. From ShaderPlanetary.swift.
fn sphereSpan(ro: vec3<f32>, rd: vec3<f32>, r: f32) -> vec2<f32> {
    let b = dot(ro, rd);
    let disc = b * b - (dot(ro, ro) - r * r);
    if (disc <= 0.0) { return vec2<f32>(1.0, 0.0); }
    let q = sqrt(disc);
    return vec2<f32>(-b - q, -b + q);
}

// v turned by angle a about the unit axis k (Rodrigues). From ShaderPulsar.swift.
fn rotateAbout(v: vec3<f32>, k: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a);
    let s = sin(a);
    return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
}
