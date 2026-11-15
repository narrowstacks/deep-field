// Metal source compiled at runtime, so the build needs no Metal toolchain download.
//
// Two stages:
//  1. A bake kernel (runs once per resize or scene change) traces one light ray per pixel.
//     The camera never moves, so ray paths never change. It stores where each ray crosses
//     the disk and the planet orbit shells, and which piece of sky it ends up seeing (as
//     scalars, so colors can be changed live without re-tracing).
//       bakeBlackHole: Schwarzschild geodesics
//       bakeWormhole:  Ellis wormhole geodesics (rays through the throat reach another universe)
//       bakeFlat:      straight rays, for star systems
//  2. A fragment shader per frame reads those lookups, animates on top of them, applies the
//     palette, tone maps, and dithers.
//       lensedFragment: black hole and wormhole
//       systemFragment: binary/trinary stars (direct ray-sphere tests, no lensing)
//
// Texture slots, shared by every scene:
//   0 hitA, 1 hitB  disk crossings (radius, angle, redshift, event index + 1)
//   2 sky           star brightness, star tint (>1 = distant galaxy), nebula A, nebula B
//   3,4 / 5,6       planet shell 0 / 1 crossings (position, direction)
//   7 extra         octahedral sky direction (xy), star id, info (see bake kernels)

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct BakeParams {
    float width; float height; float camDist; float camElev;
    float tanHalfFov; float diskIn; float diskOut; float roll;
    float shellR0; float shellR1; float throat; float starDensity;
    float scene; float galaxies; float lookX; float lookY;
    float milkyWay; float nebulaType; float nebulaSeed; float pad2;
};

struct FrameParams {
    float time; float levels; float diskIn; float diskOut;
    float exposure; float diskSpeed; float flowPeriod; float planetCount;
    float shellR0; float shellR1; float saturation; float scene;
    float dither; float twinkle; float pulsars; float skyBrightness;
    float throat; float starCount; float lightCount; float ringStrength;
    float4 camPos; float4 camRight; float4 camUp; float4 camFwd;   // camRight.w / camUp.w = drawable width / height
};

struct Palette {
    float4 receding; float4 approaching; float4 core; float4 ring;
    float4 nebulaA; float4 nebulaB; float4 farA; float4 farB;
    float4 starWarm; float4 starCool; float4 galaxy; float4 pad;
};

// Occasional phenomena, scheduled on the CPU (see Events.swift).
struct Events {
    float4 snDir;      // supernova sky direction, w = core brightness
    float4 snParams;   // halo brightness, echo radius (rad), echo brightness, cooling 0..1
    float4 cometHead;  // sky direction, w = brightness
    float4 cometTail;  // tail-end direction, w = head width (rad)
    float4 misc;       // x = pixel angle (rad)
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

struct SceneParams { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; float4 g; float4 h; };

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
        s += a * mix(0.5, noise3(p), keep);
        p = p * 2.03 + 17.1;
        f *= 2.03;
        a *= 0.5;
    }
    return s / 0.9375;
}

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

// ---------- bake: shared ----------

static float3 cameraRay(constant BakeParams& P, uint2 gid, thread float3& camPos) {
    float aspect = P.width / P.height;
    float2 uv = (float2(gid) + 0.5) / float2(P.width, P.height) * 2.0 - 1.0;
    uv.y = -uv.y;
    uv.x *= aspect;
    float cr = cos(P.roll), sr = sin(P.roll);
    uv = float2(cr * uv.x - sr * uv.y, sr * uv.x + cr * uv.y);
    float ce = cos(P.camElev), se = sin(P.camElev);
    camPos = float3(0.0, se, -ce) * P.camDist;
    float3 fwd = normalize(float3(P.lookX, P.lookY, 0.0) - camPos);
    float3 right = normalize(cross(float3(0, 1, 0), fwd));
    float3 up = cross(fwd, right);
    return normalize(fwd + (uv.x * right + uv.y * up) * P.tanHalfFov);
}

// Sky as scalars: (star brightness, star tint, nebula A, nebula B) and a star id.
// `fp` is the angular footprint of this pixel on the sky; where lensing squeezes a lot of sky
// into one pixel, detail is filtered instead of aliasing into moire.
static float4 skyScalars(float3 d, float fp, constant BakeParams& P, float seed, thread float& id) {
    float pixelAngle = 2.0 * P.tanHalfFov / P.height;
    float k = max(fp / pixelAngle, 1.0);           // > 1 where the sky is compressed
    float cells = 0.9 / pixelAngle;
    float3 p = d * cells;
    float3 c = floor(p) + seed * 131.0;
    float h = hash13(c);
    // galactic band: a tilted great circle of dense stars, glow and dark dust lanes
    float band = 0.0, dust = 0.0;
    if (P.milkyWay > 0.5 && seed == 0.0) {
        float lat = dot(d, normalize(float3(0.42, 0.9, 0.08)));
        float wobble = 0.05 * (fbmLOD(d * 3.0 + 11.0, fp * 3.0) - 0.5);
        band = exp(-pow((lat + wobble) / 0.09, 2.0));
        dust = smoothstep(0.42, 0.72, fbmLOD(d * 7.0 + 4.0, fp * 7.0)) * exp(-pow((lat + wobble * 1.5) / 0.035, 2.0));
    }
    float density = P.starDensity * (seed > 0.0 ? 3.0 : 1.0);    // the other universe is richer
    float thresh = 1.0 - 0.01 * density * (1.0 + 4.0 * band * (1.0 - dust));
    float bright = 0.0, tint = 0.0;
    id = 0.0;
    if (h > thresh) {
        // a small sphere inside the cell keeps stars round where the unit sphere slices the grid
        float3 center = floor(p) + 0.5 + (float3(hash13(c + 3.1), hash13(c + 7.7), hash13(c + 11.3)) - 0.5) * 0.5;
        if (distance(p, center) < 0.42) {
            float b = (h - thresh) / (1.0 - thresh);
            bright = (0.12 + 1.3 * b * b * b) / (k * k);    // a sub-pixel star spreads over k^2 pixels
            tint = hash13(c + 17.0);
            id = 0.001 + 0.999 * hash13(c + 29.0);
        }
    }
    // the average light of all the unresolved stars
    bright += 0.0015 * P.starDensity * smoothstep(1.5, 4.0, k);

    // rare distant galaxies: tiny tilted smudges on a coarser grid
    if (P.galaxies > 0.5 && id == 0.0 && k < 2.0) {
        float gcells = cells / 30.0;
        float3 g = floor(d * gcells);
        float gh = hash13(g + 71.0 + seed);
        if (gh > 0.992) {
            float3 gc = normalize(g + 0.5 + (float3(hash13(g + 1.0), hash13(g + 2.0), hash13(g + 3.0)) - 0.5) * 0.6);
            float3 t1 = normalize(cross(gc, float3(0.3, 1.0, 0.1)));
            float3 t2 = cross(gc, t1);
            float2 q = float2(dot(d, t1), dot(d, t2)) / (pixelAngle * (2.0 + 3.0 * hash13(g + 5.0)));
            float ang = hash13(g + 6.0) * 6.283;
            q = float2(cos(ang) * q.x - sin(ang) * q.y, sin(ang) * q.x + cos(ang) * q.y);
            q.y /= 0.35 + 0.6 * hash13(g + 7.0);
            float r = length(q);
            float arms = 0.6 + 0.4 * cos(2.0 * (atan2(q.y, q.x) - log(r + 0.05) * 2.5));
            float gal = exp(-r * r * 2.0) * (0.35 + 0.65 * arms * smoothstep(0.1, 0.6, r)) + exp(-r * r * 30.0) * 0.6;
            if (gal > 0.02 && dot(d, gc) > 0.0) { bright = gal * (0.2 + 0.25 * gh); tint = 1.0 + hash13(g + 9.0); }
        }
    }
    float nA = smoothstep(0.50, 0.90, fbmLOD(d * 2.2 + 5.0 + seed * 7.0, fp * 2.2));
    float nB = smoothstep(0.65, 0.95, fbmLOD(d * 4.5 - 3.0 + seed * 7.0, fp * 4.5));
    float clouds = 0.55 + 0.45 * fbmLOD(d * 9.0 - 2.0, fp * 9.0);
    nA += band * clouds * (1.0 - dust) * 0.35;      // cool glow of unresolved stars
    nB += band * band * clouds * (1.0 - dust) * 0.6; // warmer core of the band
    bright *= 1.0 - 0.8 * dust;
    return float4(bright, tint, nA, nB);
}

// The other universe seen through the wormhole: denser nebula and one big spiral galaxy.
static float4 farSkyScalars(float3 d, float fp, float3 galaxyDir, constant BakeParams& P, thread float& id) {
    float4 s = skyScalars(d, fp, P, 3.0, id);
    float3 t1 = normalize(cross(galaxyDir, float3(0.2, 1.0, 0.0)));
    float3 t2 = cross(galaxyDir, t1);
    float2 q = float2(dot(d, t1), dot(d, t2)) / 0.55;
    q = float2(0.8 * q.x - 0.6 * q.y, 0.6 * q.x + 0.8 * q.y);
    q.y /= 0.38;                                    // inclined disk
    float fq = fp / 0.55 / 0.38;                    // footprint in galaxy coordinates
    float r = length(q);
    float th = atan2(q.y, q.x);
    float arms = smoothstep(0.1, 1.0, cos(2.0 * (th - log(r + 0.02) * 1.3)));
    arms = mix(0.35, arms, 1.0 - smoothstep(0.3, 1.0, fq * 6.0 / (r + 0.05)));
    float clumps = fbmLOD(float3(q * 4.0, 1.0), fq * 4.0);
    float gal = dot(d, galaxyDir) > 0.0 ? 1.0 : 0.0;
    float core = exp(-r * r * 14.0) * 3.0 * gal;
    float lane = 1.0 - 0.75 * smoothstep(0.55, 0.8, fbmLOD(float3(q * 2.5, 7.0), fq * 2.5)) * exp(-pow(q.y * 3.0, 2.0));
    float armDensity = exp(-r * 1.1) * arms * (0.3 + clumps) * gal * smoothstep(3.5, 2.0, r) * lane;
    s.z = saturate(s.z * 0.7 + 0.08 * fbmLOD(d * 1.3, fp * 1.3)) + armDensity * 0.5;
    s.w = saturate(s.w * 0.9) + armDensity * 0.7;
    // the galaxy's bright core and the brighter arm stars glow in the galaxy color
    float glowAmt = core * 0.6 + armDensity * 0.12;
    if (glowAmt > s.x) { s.x = glowAmt; s.y = 1.0; }
    return s;
}

struct ShellRec {
    float4 pos = float4(-1.0);
    float4 dir = float4(0.0);
    int n = 0;
};

// Up to two crossings of a sphere of radius R: where (theta, phi) and which way the ray was
// heading. Theta is offset by 4*eventIndex so the frame shader knows what is in front of what.
static void recordShell(thread ShellRec& s, float3 hp, float3 hv, float R, int ev) {
    if (s.n >= 2) return;
    float3 nrm = hp / R;
    float theta = acos(clamp(nrm.y, -1.0, 1.0)) + 4.0 * float(ev);
    float phi = atan2(nrm.z, nrm.x);
    float2 d = octEncode(normalize(hv));
    if (s.n == 0) { s.pos.xy = float2(theta, phi); s.dir.xy = d; }
    else          { s.pos.zw = float2(theta, phi); s.dir.zw = d; }
    s.n++;
}

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

// ---------- bake: black hole ----------

// Photon in Schwarzschild spacetime (Schwarzschild radius = 1), written as a
// Newtonian-looking ODE: a = -1.5 h^2 r / |r|^5, with h = |r x v| conserved.
static float3 accel(float3 p, float h2) {
    float r2 = dot(p, p);
    return -1.5 * h2 * p / (r2 * r2 * sqrt(r2));
}

// extra.w = closest approach radius (0 = fell into the hole)
kernel void bakeBlackHole(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 dir = cameraRay(P, gid, camPos);

    float3 pos = camPos;
    float3 vel = dir;
    float h2 = length_squared(cross(pos, vel));

    float4 A = float4(0.0), B = float4(0.0);
    int hits = 0;
    int ev = 0;
    ShellRec s0, s1;
    float minR = 1e9;
    bool captured = false;
    float gCam = sqrt(1.0 - 1.0 / P.camDist);

    for (int i = 0; i < 1500; i++) {
        float r = length(pos);
        minR = min(minR, r);
        if (r < 1.0) { captured = true; break; }
        if (r > P.camDist * 1.6 && dot(pos, vel) > 0.0) break;

        float dt = clamp(0.03 * r, 0.004, 1.0);
        float3 a0 = accel(pos, h2);
        float3 np = pos + vel * dt + 0.5 * a0 * dt * dt;
        float3 a1 = accel(np, h2);
        float3 nv = vel + 0.5 * (a0 + a1) * dt;
        float nr = length(np);

        if ((r - P.shellR0) * (nr - P.shellR0) < 0.0) {
            float t = (r - P.shellR0) / (r - nr);
            recordShell(s0, mix(pos, np, t), mix(vel, nv, t), P.shellR0, ev++);
        }
        if ((r - P.shellR1) * (nr - P.shellR1) < 0.0) {
            float t = (r - P.shellR1) / (r - nr);
            recordShell(s1, mix(pos, np, t), mix(vel, nv, t), P.shellR1, ev++);
        }

        if (pos.y * np.y < 0.0 && hits < 2) {
            float t = pos.y / (pos.y - np.y);
            float3 hp = mix(pos, np, t);
            float rh = length(hp.xz);
            if (rh > P.diskIn * 0.85 && rh < P.diskOut * 1.1) {
                float phi = atan2(hp.z, hp.x);
                // circular orbit speed seen by a static observer
                float beta = min(sqrt(0.5 / max(rh - 1.0, 0.05)), 0.95);
                float gam = rsqrt(1.0 - beta * beta);
                float3 tang = float3(-sin(phi), 0.0, cos(phi));
                float3 k = -normalize(mix(vel, nv, t));
                float dop = 1.0 / (gam * (1.0 - beta * dot(tang, k)));
                float g = dop * sqrt(max(1.0 - 1.0 / rh, 0.0)) / gCam;
                float4 h = float4(rh, phi, g, float(ev++) + 1.0);
                if (hits == 0) A = h; else B = h;
                hits++;
            }
        }
        pos = np;
        vel = nv;
    }

    float3 outDir = normalize(vel);
    hitA.write(A, gid);
    hitB.write(B, gid);
    shell0P.write(s0.pos, gid);
    shell0D.write(s0.dir, gid);
    shell1P.write(s1.pos, gid);
    shell1D.write(s1.dir, gid);
    extraTex.write(float4(octEncode(outDir), 0.0, captured ? 0.0 : minR), gid);
}

// ---------- bake: wormhole ----------

// Ellis wormhole: ds^2 = -dt^2 + dl^2 + (b0^2 + l^2) dOmega^2. Each ray stays in the plane
// through the camera and the throat, so we integrate (l, phi) in that plane with the
// conserved impact parameter B:  dl/ds = p,  dp/ds = B^2 l / r^4,  dphi/ds = B / r^2.
// Rays with B < b0 pass through the throat into the other universe (l < 0).
// extra.w = side (+1 ours, -1 the other universe) * (impact parameter B / b0 + 0.001);
// B / b0 = 1 marks rays that just graze the throat.
kernel void bakeWormhole(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 d = cameraRay(P, gid, camPos);
    float b0 = P.throat;
    float D = P.camDist;
    float3 e1 = camPos / D;
    float cosA = dot(d, e1);
    float3 perp = d - e1 * cosA;
    float sinA = length(perp);
    float3 e2 = sinA > 1e-6 ? perp / sinA : normalize(cross(e1, float3(1, 0, 0)));
    float B = D * sinA;

    float l = sqrt(max(D * D - b0 * b0, 0.0));
    float p = cosA;
    float phi = 0.0;
    int ev = 0;
    ShellRec s0, s1;

    for (int i = 0; i < 2500; i++) {
        float r = sqrt(b0 * b0 + l * l);
        if (abs(l) > D * 3.0 && l * p > 0.0) break;
        float ds = clamp(0.02 * r, 0.005, 1.0);
        float a0 = B * B * l / (r * r * r * r);
        float nl = l + p * ds + 0.5 * a0 * ds * ds;
        float nr = sqrt(b0 * b0 + nl * nl);
        float a1 = B * B * nl / (nr * nr * nr * nr);
        float np = p + 0.5 * (a0 + a1) * ds;
        float nphi = phi + 0.5 * (B / (r * r) + B / (nr * nr)) * ds;

        if (l > 0.0 && nl > 0.0) {
            for (int k = 0; k < 2; k++) {
                float R = k == 0 ? P.shellR0 : P.shellR1;
                if ((r - R) * (nr - R) < 0.0) {
                    float t = (r - R) / (r - nr);
                    float lt = mix(l, nl, t), pt = mix(p, np, t), ph = mix(phi, nphi, t);
                    float3 radial = cos(ph) * e1 + sin(ph) * e2;
                    float3 tang = -sin(ph) * e1 + cos(ph) * e2;
                    float3 hv = (lt / R) * pt * radial + (B / R) * tang;
                    if (k == 0) recordShell(s0, R * radial, hv, R, ev++);
                    else        recordShell(s1, R * radial, hv, R, ev++);
                }
            }
        }
        l = nl; p = np; phi = nphi;
    }

    float r = sqrt(b0 * b0 + l * l);
    float3 radial = cos(phi) * e1 + sin(phi) * e2;
    float3 tang = -sin(phi) * e1 + cos(phi) * e2;
    float3 outDir = normalize((l / r) * p * radial + (B / r) * tang);
    bool far = l < 0.0;
    hitA.write(float4(0.0), gid);
    hitB.write(float4(0.0), gid);
    shell0P.write(s0.pos, gid);
    shell0D.write(s0.dir, gid);
    shell1P.write(s1.pos, gid);
    shell1D.write(s1.dir, gid);
    extraTex.write(float4(octEncode(outDir), 0.0, (far ? -1.0 : 1.0) * (B / b0 + 0.001)), gid);
}

// ---------- bake: flat space (star systems) ----------

// extra.w = 1000 (no lensing features); extra.xy doubles as the camera ray direction.
kernel void bakeFlat(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 d = cameraRay(P, gid, camPos);
    hitA.write(float4(0.0), gid);
    hitB.write(float4(0.0), gid);
    shell0P.write(float4(-1.0), gid);
    shell0D.write(float4(0.0), gid);
    shell1P.write(float4(-1.0), gid);
    shell1D.write(float4(0.0), gid);
    extraTex.write(float4(octEncode(d), 0.0, 1000.0), gid);
}

// ---------- bake: sky pass (all scenes) ----------

// black hole scenes (0, 5) have a shadow with no sky in it
static bool hasSky(float info, float scene) { return (scene > 0.5 && abs(scene - 5.0) > 0.5) || info >= 1.0; }
static bool sameSide(float a, float b) { return (a < 0.0) == (b < 0.0); }

// Runs after the ray bake. Works out each pixel's sky footprint from its neighbours' ray
// directions, then evaluates the sky with matching detail. Star id is packed into .y:
// y = 4 * idQuantized + tint, so tint (0..2) and id (1/4096 steps) share one channel.
kernel void skyPass(texture2d<float, access::read> extraTex [[texture(0)]],
                    texture2d<float, access::write> skyTex  [[texture(1)]],
                    constant BakeParams& P [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint W = uint(P.width), H = uint(P.height);
    if (gid.x >= W || gid.y >= H) return;
    float4 X = extraTex.read(gid);
    if (!hasSky(X.w, P.scene)) { skyTex.write(float4(0.0), gid); return; }
    float3 d = octDecode(X.xy);

    float pixelAngle = 2.0 * P.tanHalfFov / P.height;
    float fp = pixelAngle;
    uint2 nb[4] = { uint2(min(gid.x + 1, W - 1), gid.y), uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y),
                    uint2(gid.x, min(gid.y + 1, H - 1)), uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0) };
    for (int i = 0; i < 4; i++) {
        float4 Y = extraTex.read(nb[i]);
        if (!hasSky(Y.w, P.scene) || !sameSide(X.w, Y.w)) continue;
        fp = max(fp, length(octDecode(Y.xy) - d));
    }

    float id = 0.0;
    float4 sky;
    if (P.scene > 0.5 && P.scene < 1.5 && X.w < 0.0) {
        float ce = cos(P.camElev), se = sin(P.camElev);
        float3 e1 = float3(0.0, se, -ce);
        sky = farSkyScalars(d, fp, normalize(e1 + float3(0.06, 0.08, 0.0)), P, id);
    } else {
        sky = skyScalars(d, fp, P, 0.0, id);
    }
    float idq = id > 0.0 ? 1.0 + floor(id * 4094.0) : 0.0;
    sky.y = idq * 4.0 + sky.y;
    skyTex.write(sky, gid);
}

// ---------- per-frame: shared ----------

struct VOut { float4 pos [[position]]; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

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

// Background sky with its occasional phenomena. `far` = the wormhole's other universe.
static float3 skyColor(float4 sky, float4 X, bool far, constant FrameParams& F,
                       constant Events& E, constant Palette& Pal) {
    float3 col = float3(0.0);
    float idq = floor(sky.y / 4.0);
    float bright = sky.x, tint = sky.y - idq * 4.0, id = idq / 4096.0;
    if (bright > 0.0) {
        if (tint > 1.0) {
            col = mix(Pal.galaxy.rgb, Pal.starCool.rgb, 0.5 * (tint - 1.0)) * bright;
        } else {
            col = mix(Pal.starWarm.rgb, Pal.starCool.rgb, tint) * bright;
            if (id > 0.0) {
                // occasional twinkle: each star rolls the dice every ~5 s
                float slotPos = F.time * 0.2 + id * 97.0;
                float roll = hash13(float3(id * 1000.0, floor(slotPos), 7.0));
                if (roll > 1.0 - 0.06 * F.twinkle) {
                    float env = sin(3.14159 * fract(slotPos));
                    float flick = 0.5 + 0.5 * sin(F.time * 23.0 + id * 61.0) * sin(F.time * 9.0 + id * 17.0);
                    col *= 1.0 + env * env * (1.0 + 3.0 * flick);
                }
                if (F.pulsars > 0.5 && fract(id * 7919.0) < 0.004) {
                    col *= 0.25 + 3.5 * pow(0.5 + 0.5 * sin(F.time * 5.71 + id * 10.0), 12.0);
                }
            }
        }
    }
    if (far) {
        col += (Pal.farA.rgb * pow(sky.z, 1.5) * 0.55 + Pal.farB.rgb * pow(sky.w, 1.5) * 0.5) * F.skyBrightness;
        if (E.farSn.w > 0.0) {
            float c = length(octDecode(X.xy) - E.farSn.xyz);
            float3 hot = mix(float3(0.75, 0.88, 1.0), float3(1.0, 0.5, 0.25), E.farSnParams.y);
            col += hot * (E.farSn.w * exp(-pow(c / 0.05, 2.0)) + E.farSnParams.x * exp(-c / 0.15));
        }
        return col;
    }
    col += (Pal.nebulaA.rgb * sky.z * 0.02 + Pal.nebulaB.rgb * sky.w * 0.012) * F.skyBrightness;

    // sky events live in sky-direction space, so lensing applies to them like everything else
    float3 dir = octDecode(X.xy);
    float pa = E.misc.x;
    if (E.snDir.w > 0.0) {
        float c = length(dir - E.snDir.xyz);
        float core = E.snDir.w * exp(-pow(c / (1.3 * pa), 2.0));
        float halo = E.snParams.x * exp(-c / (4.0 * pa));
        float echo = E.snParams.z * exp(-pow((c - E.snParams.y) / (1.6 * pa), 2.0));
        float3 hot = mix(float3(0.70, 0.85, 1.00), float3(1.00, 0.45, 0.20), E.snParams.w);
        col += hot * (core + halo) + float3(0.70, 0.55, 1.00) * echo;
    }
    if (E.cometHead.w > 0.0) {
        float3 H = E.cometHead.xyz;
        float3 seg = E.cometTail.xyz - H;
        float tt = saturate(dot(dir - H, seg) / dot(seg, seg));
        float dseg = length(dir - (H + seg * tt));
        float w = E.cometTail.w * (1.0 + tt * 5.0);
        float tail = exp(-pow(dseg / w, 2.0)) * pow(1.0 - tt, 1.5);
        float head = exp(-pow(length(dir - H) / (E.cometTail.w * 1.1), 2.0));
        col += E.cometHead.w * (float3(0.80, 0.95, 1.00) * head * 2.0 + float3(0.35, 0.65, 1.00) * tail * 0.6);
    }
    return col;
}

// Planet surface at normal N, seen along v, lit by every light.
static float3 shadePlanetSurface(Planet pl, float3 N, float3 v, float3 P,
                                 constant Light* lights, int lightCount) {
    float sa = pl.misc.x, cs = cos(sa), sn = sin(sa);
    float3 q = float3(cs * N.x - sn * N.z, N.y, sn * N.x + cs * N.z);
    float seed = pl.colorB.w;
    float bands = fbm(float3(q.x * 1.6, q.y * pl.misc.y, q.z * 1.6) + seed);
    float storms = noise3(q * 5.0 + seed * 2.0);
    float3 surf = mix(pl.colorB.rgb, pl.colorA.rgb, smoothstep(0.3, 0.7, bands + (storms - 0.5) * 0.35));

    float3 lit = float3(0.0);
    float day = 0.0;
    for (int i = 0; i < lightCount; i++) {
        float3 L = normalize(lights[i].pos.xyz - P);
        float nl = dot(N, L);
        lit += lights[i].color.rgb * lights[i].pos.w * saturate(nl);
        day = max(day, saturate(nl * 0.5 + 0.5));
    }
    float3 col = surf * (lit * 1.25 + 0.02);
    col += surf * float3(0.08, 0.14, 0.35) * pow(1.0 - day, 2.0) * 0.25;
    float rim = pow(1.0 - saturate(dot(N, -v)), 3.0);
    col += float3(0.35, 0.60, 1.00) * rim * pl.misc.z * (0.25 + day);
    return col;
}

// ---------- per-frame: black hole and wormhole ----------

static float diskNoise(float r, float ang, float seed) {
    float3 p = float3(cos(ang) * 2.6, sin(ang) * 2.6, r * 3.2 + seed);
    float n = fbm(p);
    float3 q = float3(cos(ang) * 7.0, sin(ang) * 7.0, r * 9.0 - seed);
    return n * 0.75 + noise3(q) * 0.25;
}

static float4 shadeDisk(float4 h, constant FrameParams& F, constant Palette& Pal) {
    float r = h.x, phi = h.y, g = h.z;
    float x = (r - F.diskIn) / (F.diskOut - F.diskIn);
    float prof = smoothstep(-0.02, 0.05, x) * (1.0 - smoothstep(0.45, 1.0, x));
    if (prof <= 0.0) return float4(0.0);

    // Differential rotation; two phases cross-faded so the shear never winds the texture up.
    float omega = F.diskSpeed * pow(r, -1.5);
    float T = F.flowPeriod;
    float ph = fract(F.time / T);
    float t0 = ph * T;
    float t1 = fract(ph + 0.5) * T;
    float w0 = 1.0 - abs(2.0 * ph - 1.0);
    float n = diskNoise(r, phi - omega * t0, 0.0) * w0
            + diskNoise(r, phi - omega * t1, 41.0) * (1.0 - w0);
    float dens = smoothstep(0.28, 0.80, n);

    float heat = 1.0 - saturate(x);
    float3 rec = Pal.receding.rgb, app = Pal.approaching.rgb;
    float3 warm = mix(rec * rec * 0.5, rec, smoothstep(0.0, 0.6, heat));
    warm = mix(warm, Pal.core.rgb, smoothstep(0.7, 1.0, heat) * 0.6);
    float3 cool = mix(app * app * 0.85, mix(app, float3(1.0), 0.35), smoothstep(0.2, 1.0, heat));
    float shift = smoothstep(0.95, 1.30, g);
    float3 col = mix(warm, cool, shift);

    float beaming = pow(clamp(g, 0.35, 1.8), 2.2);
    float radial = pow(F.diskIn / r, 1.3);
    float emit = prof * radial * beaming * (0.30 + 1.1 * dens);
    float alpha = saturate(prof * (0.55 + 0.7 * dens) * 1.25);
    return float4(col * emit * 2.2, alpha);
}

// A ray crossing a planet's orbit shell at X heading v; treat it as straight near the planet
// and intersect each planet's sphere. Only the half-chord on this side of the shell counts.
static float4 shadePlanetsOnShell(float3 X, float3 v, int shell, constant Planet* planets, int count,
                                  constant Light* lights, int lightCount) {
    float best = 1e9;
    float4 out = float4(0.0);
    float halfChord = abs(dot(X, v));
    bool inbound = dot(X, v) < 0.0;
    for (int i = 0; i < count; i++) {
        Planet pl = planets[i];
        if (int(pl.center.w) != shell) continue;
        float3 C = pl.center.xyz;
        float rp = pl.colorA.w;
        float3 oc = X - C;
        float b = dot(oc, v);
        float c = dot(oc, oc) - rp * rp;
        float disc = b * b - c;
        if (disc <= 0.0) continue;
        float t = -b - sqrt(disc);
        if (inbound ? (t < -rp || t > halfChord + rp) : (t > rp || t < -halfChord - rp)) continue;
        float key = inbound ? t : -t;
        if (key >= best) continue;
        best = key;
        float3 P = X + v * t;
        out = float4(shadePlanetSurface(pl, normalize(P - C), v, P, lights, lightCount), 1.0);
    }
    return out;
}

// Tidal disruption: the star's debris in the disk plane. S.a = (orbit angle, pericenter,
// eccentricity, stream progress tau), S.b = (stream brightness, disk amount, disk inner edge, flare).
static float4 shadeTDE(float4 h, constant FrameParams& F, constant Palette& Pal, constant SceneParams& S) {
    float r = h.x, phi = h.y, g = h.z;
    float omegaO = S.a.x, rp = S.a.y, ecc = S.a.z, tau = S.a.w;
    float nu = phi - omegaO;
    nu -= 6.2831853 * floor(nu / 6.2831853 + 0.5);
    float denom = 1.0 + ecc * cos(nu);
    float rOrb = denom > 0.03 ? rp * (1.0 + ecc) / denom : 1e4;
    float3 starCol = S.e.rgb;
    float beaming = pow(clamp(g, 0.35, 1.8), 2.0);

    // the stream: debris strung out along the orbit, the bound head swinging round the hole
    // first while the unbound tail stretches back out the way the star came in
    float stream = 0.0;
    if (S.b.x > 0.0) {
        float nuHead = min(-0.35 + 3.4 * pow(tau, 0.6), 2.9);
        float nuTail = -0.35 - 1.6 * pow(tau, 0.8);
        float inRange = smoothstep(nuTail - 0.05, nuTail + 0.1, nu) * (1.0 - smoothstep(nuHead - 0.15, nuHead, nu));
        float w = 0.3 + 0.045 * rOrb + 0.7 * tau;
        float along = saturate((nu - nuTail) / max(nuHead - nuTail, 0.01));
        float flow = fbm(float3(nu * 9.0 - F.time * 0.4, (r - rOrb) / w * 1.5, 3.0));
        stream = exp(-pow((r - rOrb) / w, 2.0)) * inRange * (0.35 + 0.65 * along) * (0.5 + 0.9 * flow) * S.b.x;
    }

    // the debris that falls back circularizes into a fresh, hot disk that creeps inward
    float disk = 0.0;
    float3 diskCol = float3(0.0);
    if (S.b.y > 0.0) {
        float rin = S.b.z, rout = 2.4 * rp;
        float prof = smoothstep(rin * 0.85, rin * 1.1, r) * (1.0 - smoothstep(rout * 0.8, rout * 1.4, r));
        float omega = F.diskSpeed * pow(r, -1.5);
        float n = diskNoise(r, phi - omega * fract(F.time / 30.0) * 30.0, 0.0);
        disk = prof * (0.4 + 0.9 * smoothstep(0.3, 0.8, n)) * S.b.y;
        float heat = 1.0 - saturate((r - rin) / (rout - rin));
        float3 warm = mix(Pal.receding.rgb * 0.6, Pal.core.rgb, heat);
        diskCol = mix(warm, mix(Pal.approaching.rgb, float3(1.0), 0.3), smoothstep(0.95, 1.3, g));
    }
    float3 streamCol = mix(starCol, Pal.receding.rgb, 0.35 + 0.4 * tau);
    float3 emit = (streamCol * stream * 1.6 + diskCol * disk * (0.6 + S.b.w)) * beaming;
    return float4(emit, saturate(stream * 1.4 + disk * 0.9));
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

fragment float4 lensedFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    bool wormhole = F.scene > 0.5 && F.scene < 1.5;
    bool tde = F.scene > 4.5;
    int lightCount = int(F.lightCount);

    // Layers indexed by event order along the ray (0 = nearest), composited back to front.
    float4 layers[6] = { float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0) };
    if (!wormhole) {
        float4 A = hitA.read(p);
        float4 B = hitB.read(p);
        if (A.w > 0.0) layers[min(int(A.w) - 1, 5)] = tde ? shadeTDE(A, F, Pal, S) : shadeDisk(A, F, Pal);
        if (B.w > 0.0) layers[min(int(B.w) - 1, 5)] = tde ? shadeTDE(B, F, Pal, S) : shadeDisk(B, F, Pal);
    }
    int count = int(F.planetCount);
    if (count > 0) {
        float4 sp[2] = { shell0P.read(p), shell1P.read(p) };
        float4 sd[2] = { shell0D.read(p), shell1D.read(p) };
        float radii[2] = { F.shellR0, F.shellR1 };
        for (int s = 0; s < 2; s++) {
            for (int k = 0; k < 2; k++) {
                float2 tp = k == 0 ? sp[s].xy : sp[s].zw;
                if (tp.x < 0.0) continue;
                float ev = floor(tp.x / 4.0);
                float theta = tp.x - ev * 4.0;
                float3 Xs = radii[s] * float3(sin(theta) * cos(tp.y), cos(theta), sin(theta) * sin(tp.y));
                float3 v = octDecode(k == 0 ? sd[s].xy : sd[s].zw);
                float4 pc = shadePlanetsOnShell(Xs, v, s, planets, count, lights, lightCount);
                if (pc.a > 0.0) layers[min(int(ev), 5)] = pc;
            }
        }
    }

    float3 col = float3(0.0);
    float info = X.w;
    if (!wormhole) {
        if (info >= 1.0) {
            col = skyColor(sky, X, false, F, E, Pal);
            col += Pal.ring.rgb * exp(-(info - 1.5) * 40.0) * 1.2 * F.ringStrength;  // photon ring
        }
    } else {
        bool far = info < 0.0;
        col = skyColor(sky, X, far, F, E, Pal);
        // thin rim where rays graze the throat, pulsing slowly, with occasional flares running along it
        float graze = abs(abs(info) - 1.0);
        float pulse = 0.8 + 0.2 * sin(F.time * 0.5);
        float2 rel = float2(p) + 0.5 - E.throat.xy;
        float flare = 0.0;
        if (E.flare.y > 0.0) {
            float dAng = atan2(rel.y, rel.x) - E.flare.x;
            dAng -= 6.2831853 * floor(dAng / 6.2831853 + 0.5);
            flare = E.flare.y * exp(-pow(dAng / E.flare.z, 2.0));
        }
        col += Pal.ring.rgb * exp(-graze * 90.0) * (0.35 * pulse + 2.5 * flare) * F.ringStrength;
        col += Pal.ring.rgb * flare * 0.25 * exp(-graze * 8.0);       // the flare's glow spills inward
        if (E.obj.z > 0.0) {
            // an object crossing between universes, smeared tangentially near the rim
            float2 d = float2(p) + 0.5 - E.obj.xy;
            float2 radial = normalize(E.obj.xy - E.throat.xy + 1e-4);
            float2 tang = float2(-radial.y, radial.x);
            float sz = E.obj.w;
            float a = dot(d, radial), b = dot(d, tang) / E.objDir.z;
            float head = exp(-(a * a + b * b) / (sz * sz));
            float2 v = E.objDir.xy;
            float along = dot(d, -v), across = dot(d, float2(-v.y, v.x));
            float trail = along > 0.0 ? exp(-along / (sz * 7.0)) * exp(-across * across / (sz * sz * 0.6)) : 0.0;
            col += (float3(1.0, 0.85, 0.6) * head * 2.5 + float3(0.55, 0.75, 1.0) * trail * 0.7) * E.obj.z;
        }
    }
    for (int i = 5; i >= 0; i--) col = col * (1.0 - layers[i].a) + layers[i].rgb;
    if (tde && S.c.w > 0.0) {
        // the incoming star, stretched along its orbit as tides pull it apart
        float2 d = float2(p) + 0.5 - S.c.xy;
        float2 u = S.d.xy, v = float2(-u.y, u.x);
        float a = dot(d, u) / S.d.z, b = dot(d, v);
        float q = (a * a + b * b) / (S.c.z * S.c.z);
        col += S.e.rgb * (exp(-q * 2.0) * 3.0 + exp(-q * 0.6) * 0.08) * S.c.w;
    }
    return finalize(col, p, F);
}

// ---------- per-frame: star systems ----------

static float3 shadeStar(Star st, float3 N, float3 rd, float time) {
    float mu = saturate(dot(N, -rd));
    float limb = 0.35 + 0.65 * pow(mu, 0.6);
    float sa = st.misc.x, cs = cos(sa), sn = sin(sa);
    float3 q = float3(cs * N.x - sn * N.z, N.y, sn * N.x + cs * N.z);
    float seed = st.misc.y;
    float gran = fbm(q * 7.0 + seed + float3(0.0, 0.0, time * 0.04));
    float spots = smoothstep(0.70, 0.80, fbm(q * 2.2 + seed * 3.0)) * st.misc.z;
    return st.color.rgb * 0.8 * limb * (0.7 + 0.6 * gran) * (1.0 - 0.7 * spots);
}

fragment float4 systemFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 rd = octDecode(X.xy);
    float3 ro = F.camPos.xyz;
    int starCount = int(F.starCount);
    int planetCount = int(F.planetCount);
    int lightCount = int(F.lightCount);

    float tBest = 1e9;
    int hitStar = -1, hitPlanet = -1;
    for (int i = 0; i < starCount; i++) {
        float3 oc = ro - stars[i].pos.xyz;
        float R = stars[i].pos.w;
        float b = dot(oc, rd);
        float disc = b * b - (dot(oc, oc) - R * R);
        if (disc > 0.0) {
            float t = -b - sqrt(disc);
            if (t > 0.0 && t < tBest) { tBest = t; hitStar = i; hitPlanet = -1; }
        }
    }
    for (int i = 0; i < planetCount; i++) {
        float3 oc = ro - planets[i].center.xyz;
        float R = planets[i].colorA.w;
        float b = dot(oc, rd);
        float disc = b * b - (dot(oc, oc) - R * R);
        if (disc > 0.0) {
            float t = -b - sqrt(disc);
            if (t > 0.0 && t < tBest) { tBest = t; hitPlanet = i; hitStar = -1; }
        }
    }

    float3 col;
    if (hitStar >= 0) {
        Star st = stars[hitStar];
        float3 P = ro + rd * tBest;
        col = shadeStar(st, normalize(P - st.pos.xyz), rd, F.time);
    } else if (hitPlanet >= 0) {
        Planet pl = planets[hitPlanet];
        float3 P = ro + rd * tBest;
        col = shadePlanetSurface(pl, normalize(P - pl.center.xyz), rd, P, lights, lightCount);
    } else {
        col = skyColor(sky, X, false, F, E, Pal);
    }

    // coronas, hidden by anything solid in front of the star
    for (int i = 0; i < starCount; i++) {
        Star st = stars[i];
        float3 oc = st.pos.xyz - ro;
        float tc = dot(oc, rd);
        if (tc <= 0.0) continue;
        if (tBest < tc - st.pos.w && hitStar != i) continue;
        float3 w = ro + rd * tc - st.pos.xyz;
        float dperp = length(w);
        float R = st.pos.w;
        float scale = R * 0.9 * st.color.w;
        float ang = atan2(dot(w, F.camUp.xyz), dot(w, F.camRight.xyz));
        float rays = 0.7 + 0.45 * noise3(float3(cos(ang) * 3.0, sin(ang) * 3.0, F.time * 0.08 + st.misc.y));
        float x = max(dperp - R, 0.0);
        float glow = (0.55 * exp(-x / (scale * 0.3)) + 0.12 * exp(-x / scale)) * rays;
        col += st.color.rgb * glow;
    }
    return finalize(col, p, F);
}

// ---------- per-frame: galaxy ----------

// Mirrors GalaxyModel in Galaxy.swift: flat rotation curve with a dark matter halo,
// falling (Keplerian) curve from visible mass alone.
static float galaxyVelocity(float r, bool darkMatter) {
    if (darkMatter) return 1.0 - exp(-r / 0.12);
    float a = 0.08;
    return r / pow(r * r + a * a, 0.75) * sqrt(a) / 0.6204;
}

// Stellar texture of the disk, carried around at each radius's own angular speed.
// Two phases cross-fade so differential rotation never shears it into streaks.
static float flowingDisk(float r, float phi, float omega, float time, float T, float scale, float fp) {
    float ph = fract(time / T);
    float w0 = 1.0 - abs(2.0 * ph - 1.0);
    float a0 = phi - omega * ph * T;
    float a1 = phi - omega * fract(ph + 0.5) * T;
    float n0 = fbmLOD(float3(cos(a0) * r * scale, sin(a0) * r * scale, 1.0), fp);
    float n1 = fbmLOD(float3(cos(a1) * r * scale, sin(a1) * r * scale, 9.0), fp);
    return n0 * w0 + n1 * (1.0 - w0);
}

fragment float4 galaxyFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 rd = octDecode(X.xy);
    float3 ro = F.camPos.xyz;
    float3 col = skyColor(sky, X, false, F, E, Pal);

    int type = int(G.shape.x);
    float R = G.misc.x;
    bool dm = G.motion.z > 0.5;
    float pixelAngle = E.misc.x;

    // Bulge (or the whole body of an elliptical): an ellipsoid glow integrated along the ray.
    float flat_ = type == 2 ? 0.72 : 0.5;
    float re = (type == 2 ? 0.2 : 0.09) * R;
    float3 o2 = ro / float3(1.0, flat_, 1.0);
    float3 d2 = normalize(rd / float3(1.0, flat_, 1.0));
    float s = length(o2 + d2 * max(-dot(o2, d2), 0.0)) / re;
    float bulgeAmt = type == 3 ? 0.15 : (type == 2 ? 1.6 : 1.0);
    float3 bulge = G.core.rgb * (exp(-3.2 * pow(s, 0.65)) * 1.8 + exp(-s * 0.35) * 0.04) * bulgeAmt;
    if (type == 2) {
        // faint shells left over from swallowed companions
        float shells = 0.0;
        for (int k = 0; k < 3; k++) {
            float rs = 2.2 + 1.3 * float(k);
            shells += exp(-pow((s - rs) / 0.15, 2.0)) * pow(0.5 + 0.5 * cos(atan2(d2.y, d2.x) + float(k) * 2.3), 4.0);
        }
        bulge += G.core.rgb * shells * 0.02;
    }

    // stellar halo and globular clusters, scattered in 3D around the galaxy
    float tClose = -dot(ro, rd);
    float dPerp = length(ro + rd * tClose) / R;
    col += G.core.rgb * exp(-dPerp / 0.45) * 0.025;
    {
        float3 cell = floor(rd / pixelAngle * 0.7);
        float h = hash13(cell + 41.0);
        float halo = exp(-dPerp / 0.5);
        if (h > 1.0 - 0.006 * halo) col += mix(G.core.rgb, float3(1.0), 0.4) * (0.5 + 2.0 * fract(h * 97.0));
    }

    float3 emission = float3(0.0);
    float dustOpacity = 0.0;
    float frontFrac = 1.0;          // share of the bulge's light that sits in front of the disk here
    float t = -ro.y / rd.y;
    if (type != 2 && t > 0.0) {
        float3 P = ro + rd * t;
        float r = length(P.xz) / R;
        float phi = atan2(P.z, P.x);
        frontFrac = smoothstep(-1.0, 1.0, clamp((t - tClose) / (1.2 * re), -1.0, 1.0));   // (tanh overflows to NaN under fast math)
        // light and dust pile up along longer paths through a tilted disk
        float path = clamp(0.3 / abs(rd.y), 1.0, 4.0);
        float fp = pixelAngle * t / (R * max(abs(rd.y), 0.08));
        if (r < 1.4) {
            float omega = G.motion.y * galaxyVelocity(r, dm) / max(r, 0.01);
            float a = phi - G.motion.x;                 // angle in the pattern's rotating frame
            float tanp = G.shape.z, m = G.shape.y;
            float clumps = flowingDisk(r, phi, omega, F.time, G.motion.w, 9.0, fp * 9.0);
            float fine = flowingDisk(r, phi, omega, F.time, G.motion.w, 26.0, fp * 26.0);
            float smoothDisk = exp(-r / 0.24) * (1.0 - smoothstep(0.7, 1.1, r));

            float arm = 0.0, ring = 0.0, bar = 0.0, knotsBand = 0.0;
            if (type == 0 || type == 1) {
                float r0 = type == 1 ? G.shape.w : 0.12;
                float psi = m * (a - log(max(r, 0.02) / r0) / tanp);
                float env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
                // feathery spurs along the arms
                float spurs = 0.55 + 0.75 * fine;
                arm = pow(0.5 + 0.5 * cos(psi), 3.0) * env * spurs;
                // density-wave order across an arm: dust lane on the inside, then star-forming knots, then young stars
                float lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * smoothstep(r0, r0 * 1.8, r) * (1.0 - smoothstep(0.7, 1.05, r));
                knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
                float filaments = 0.35 + 0.9 * fine;
                dustOpacity = lane * (0.4 + 0.6 * clumps) * filaments * 0.95
                            + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12;      // flocculent inter-arm dust
                if (type == 1) {
                    float bx = r * cos(a), by = r * sin(a);
                    bar = exp(-pow(abs(bx) / G.shape.w, 4.0)) * exp(-pow(by / 0.05, 2.0));
                    // dust lanes along the bar's leading edges
                    dustOpacity += exp(-pow(abs(bx) / (G.shape.w * 1.1), 6.0)) * exp(-pow((abs(by) - 0.045) / 0.012, 2.0)) * 0.5;
                }
            } else if (type == 4) {
                ring = exp(-pow((r - 0.62) / 0.07, 2.0)) * (0.6 + 0.6 * fine);
                knotsBand = ring;
                dustOpacity = exp(-pow((r - 0.55) / 0.03, 2.0)) * 0.5 * (0.4 + 0.8 * fine);
                smoothDisk *= 0.25;
            } else if (type == 3) {
                // Dwarf irregular. The lopsided envelope turns slowly, but the gas inside flows:
                // a rising rotation curve (inner parts turn faster than solid-body at the edge),
                // a turbulent warp that keeps changing, and clumps that form and dissolve.
                float env_a = phi - G.misc.y * 0.25;
                float2 e = float2(cos(env_a), sin(env_a)) * r;
                float envelope = exp(-length(e / float2(0.75, 0.45)) * 2.2)
                               * (0.7 + 0.6 * fbmLOD(float3(e * 1.8, 2.0 + F.time * 0.003), fp * 2.0))
                               * (1.0 - smoothstep(0.85, 1.3, r));
                float omIrr = G.motion.y * min(r / 0.45, 1.0) * 0.8 / max(r, 0.05);
                float T = G.motion.w;
                float ph = fract(F.time / T);
                float w0 = 1.0 - abs(2.0 * ph - 1.0);
                float lumps = 0.0;
                for (int k = 0; k < 2; k++) {
                    float tk = (k == 0 ? ph : fract(ph + 0.5)) * T;
                    float ak = phi - omIrr * tk;
                    float3 qk = float3(cos(ak) * r, sin(ak) * r, 0.0) * 3.2 + float3(0.0, 0.0, F.time * 0.006 + float(k) * 7.0);
                    float3 warp = float3(fbm(qk * 0.7 + 3.0), fbm(qk * 0.7 - 5.0), 0.0) - 0.5;
                    float v = fbmLOD(qk + warp * 1.6, fp * 3.2);
                    lumps += v * (k == 0 ? w0 : 1.0 - w0);
                }
                smoothDisk = envelope * smoothstep(0.3, 0.7, lumps) * 1.2;
                arm = smoothstep(0.55, 0.8, lumps) * envelope * 3.0;
                // star-forming bursts: knots brighten and fade on their own clocks
                float burst = 0.5 + 0.5 * sin(F.time * 0.15 + hash13(floor(float3(e * 14.0, 1.0))) * 6.283);
                knotsBand = arm * (0.3 + 1.2 * burst * burst);
                dustOpacity = smoothDisk * smoothstep(0.62, 0.8, fine) * 0.35;
            }

            float young = arm + ring;
            float knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            float3 diskLight = G.core.rgb * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                             + G.core.rgb * bar * 1.3
                             + G.arms.rgb * young * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 1.1
                             + G.nebula.rgb * knots * 1.3;
            emission = diskLight * mix(1.0, path, 0.35);

            // resolved bright stars, each ring of cells orbiting at its own omega
            float ri = floor(r * 160.0);
            float rc = (ri + 0.5) / 160.0;
            float om = G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
            float cellAng = (phi - om * F.time) * rc * 160.0;
            float h = hash13(float3(ri, floor(cellAng), 5.0));
            if (h > 0.985 - 0.05 * young) emission += mix(G.core.rgb, G.arms.rgb, saturate(young * 2.0)) * (0.5 + young) * smoothDisk * 3.0;

            dustOpacity = saturate(dustOpacity * path);
        }
    }
    // The back half of the bulge (and the sky) is seen through the disk's dust; the front half isn't.
    float3 dusty = mix(float3(1.0), G.dust.rgb, dustOpacity);
    col = (col + bulge * (1.0 - frontFrac)) * dusty + emission * (1.0 - 0.8 * dustOpacity) + bulge * frontFrac;
    return finalize(col, p, F);
}

// ---------- per-frame: pulsar ----------
// S.a = magnetic axis, beam half-width; S.b = spin axis, flash; S.c = beam color, nebula on;
// S.d = nebula color, field lines on; S.e = a vector perpendicular to the magnetic axis.

fragment float4 pulsarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 rd = octDecode(X.xy);
    float3 ro = F.camPos.xyz;
    float3 col = skyColor(sky, X, false, F, E, Pal);

    float3 m = S.a.xyz, spin = S.b.xyz, b1 = S.e.xyz, b2 = cross(m, b1);
    float w = S.a.w;
    float3 beamCol = S.c.rgb, nebCol = S.d.rgb;
    float tc = -dot(ro, rd);
    float dmin = length(ro + rd * tc);
    const float Rv = 14.0;
    if (dmin < Rv) {
        float half_ = sqrt(Rv * Rv - dmin * dmin);
        const int N = 48;
        float dt = 2.0 * half_ / float(N);
        float3 acc = float3(0.0);
        for (int i = 0; i < N; i++) {
            float3 x = ro + rd * (tc - half_ + (float(i) + 0.5) * dt);
            float r = length(x);
            if (r < 0.3) continue;
            float3 xn = x / r;
            float c = dot(xn, m);
            // two lighthouse beams along the magnetic axis
            float ang = acos(min(abs(c), 1.0));
            float beam = exp(-pow(ang / w, 2.0)) / (1.0 + r * 0.35) * smoothstep(0.35, 1.2, r);
            acc += beamCol * beam * 0.55;
            if (S.d.w > 0.5) {
                // dipole field lines: r = L sin^2(theta), in three planes around the magnetic axis
                float s2 = max(1.0 - c * c, 1e-3);
                float L = r / s2;
                float lines = 0.0;
                for (int k = 0; k < 3; k++) {
                    float Lk = 2.0 + 1.6 * float(k);
                    lines += exp(-pow((L - Lk) / (0.06 * Lk), 2.0));
                }
                float az = atan2(dot(x, b2), dot(x, b1));
                lines *= pow(0.5 + 0.5 * cos(az * 3.0), 24.0) * smoothstep(0.3, 0.6, r);
                acc += mix(beamCol, float3(1.0), 0.3) * lines * 0.12;
            }
            if (S.c.w > 0.5) {
                // pulsar wind nebula: an equatorial torus and two polar jets, both churning
                float hgt = dot(x, spin);
                float perp = length(x - spin * hgt);
                float churn = noise3(x * 0.9 + float3(0.0, F.time * 0.15, 0.0));
                float torus = exp(-(pow(perp - 4.2, 2.0) + hgt * hgt * 3.0) / 0.9) * (0.4 + 0.9 * churn);
                float jets = exp(-pow(perp / (0.25 + 0.06 * abs(hgt)), 2.0)) * exp(-abs(hgt) / 5.0)
                           * smoothstep(0.6, 1.6, abs(hgt)) * (0.4 + 0.9 * noise3(x * 1.4 - float3(0.0, F.time * 0.6 * sign(hgt), 0.0)));
                acc += nebCol * (torus * 0.07 + jets * 0.22);
            }
        }
        col += acc * dt;
        // the neutron star: tiny, white-hot, brightest at its magnetic poles
        float b = dot(ro, rd), disc = b * b - (dot(ro, ro) - 0.09);
        if (disc > 0.0) {
            float3 P = ro + rd * (-b - sqrt(disc));
            float pole = pow(abs(dot(normalize(P), m)), 8.0);
            col = float3(0.85, 0.92, 1.0) * (2.0 + 4.0 * pole);
        }
        col += float3(0.8, 0.9, 1.0) * exp(-dmin / 0.35) * 1.2;
    }
    // the lighthouse flash when a beam sweeps past us
    col += beamCol * S.b.w * (exp(-dmin / 2.5) * 1.5 + 0.03);
    return finalize(col, p, F);
}

// ---------- nebula ----------

static float fbmN(float3 p, int octaves) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * noise3(p);
        norm += amp;
        p = p * 2.03 + 17.1;
        amp *= 0.5;
    }
    return sum / norm;
}

static float sdCapsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - r;
}

static float sdEllipse(float2 p, float2 c, float2 radii, float angle) {
    float2 d = p - c;
    float cs = cos(angle), sn = sin(angle);
    d = float2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y);
    return (length(d / radii) - 1.0) * min(radii.x, radii.y);
}

// Signed distance (negative inside) of the dust silhouette, in the xy plane.
static float dustShape(float2 xy, int type, float seed) {
    if (type == 3) {
        // pillars: tapering columns rising from the bottom, rounded tops, small fingers
        float d = 1e3;
        int count = 2 + int(hash13(float3(seed, 0.0, 9.0)) * 2.99);
        for (int i = 0; i < 4; i++) {
            if (i >= count) break;
            float fi = float(i);
            float cx = -9.0 + 18.0 * (fi + 0.5) / float(count) + (hash13(float3(seed, fi, 1.0)) - 0.5) * 3.0;
            float top = -1.0 + 7.5 * hash13(float3(seed, fi, 2.0));
            float lean = (hash13(float3(seed, fi, 3.0)) - 0.5) * 0.35;
            float w0 = 1.6 + 1.1 * hash13(float3(seed, fi, 4.0));
            float2 base = float2(cx - lean * 14.0, -14.0), tip = float2(cx, top);
            float h = saturate((xy.y - base.y) / (tip.y - base.y));
            float col = sdCapsule(xy, base, tip, mix(w0, w0 * 0.45, h));
            // small evaporating fingers near the tip
            for (int k = 0; k < 2; k++) {
                float fk = float(k);
                float2 fbase = mix(base, tip, 0.75 + 0.1 * fk) + float2((fk - 0.5) * w0 * 0.7, 0.0);
                float2 ftip = fbase + float2((hash13(float3(seed, fi, 5.0 + fk)) - 0.5) * 2.0, 1.5 + 1.5 * hash13(float3(seed, fi, 7.0 + fk)));
                col = min(col, sdCapsule(xy, fbase, ftip, 0.25 + 0.15 * hash13(float3(seed, fi, 9.0 + fk))));
            }
            d = min(d, col);
        }
        return d;
    }
    // dark nebula: a cloud bank along the bottom with a neck and head rising out of it
    float bank = xy.y - (-4.0 + 1.6 * (fbmN(float3(xy.x * 0.12, 0.0, seed), 4) - 0.5) * 2.0);
    float hx = (hash13(float3(seed, 1.0, 1.0)) - 0.5) * 8.0;
    float dir = hash13(float3(seed, 2.0, 1.0)) < 0.5 ? -1.0 : 1.0;
    float hy = 1.5 + 2.5 * hash13(float3(seed, 3.0, 1.0));
    float neck = sdCapsule(xy, float2(hx - dir * 0.6, -4.5), float2(hx + dir * 0.4, hy - 1.0), 1.15);
    float head = sdEllipse(xy, float2(hx + dir * 1.1, hy), float2(1.9, 1.2), dir * 0.35);
    float snout = sdEllipse(xy, float2(hx + dir * 2.7, hy - 0.9), float2(1.0, 0.75), dir * 0.9);
    float ear = sdCapsule(xy, float2(hx + dir * 0.2, hy + 0.6), float2(hx - dir * 0.3, hy + 1.9), 0.3);
    float k = 0.6;   // smooth union, so the parts blend like one cloud
    float d = neck;
    for (int i = 0; i < 3; i++) {
        float o = i == 0 ? head : (i == 1 ? snout : ear);
        float hh = saturate(0.5 + 0.5 * (o - d) / k);
        d = mix(o, d, hh) - k * hh * (1.0 - hh);
    }
    return min(min(d, bank), 1e3);
}

// Emission (Ha, OIII, SII) and dust for each nebula type, at slice k. Two slices are baked and
// cross-faded per pixel so the glowing gas seems to flow; the dust silhouettes stay put.
static void nebulaSample(float3 p, int type, float seed, float k, thread float3& em, thread float& dust) {
    float3 sd = float3(seed * 17.3, seed * 5.1, seed * 11.7);
    float r = length(p);
    em = float3(0.0);
    dust = 0.0;
    if (type == 0) {
        float3 q = p * 0.11 + sd;
        float3 warp = float3(fbmN(q, 4), fbmN(q + 5.2, 4), fbmN(q - 3.7, 4)) - 0.5;
        float3 qf = q + float3(0.0, 0.0, k * 0.25);
        float env = exp(-dot(p, p) / 60.0) * smoothstep(12.0, 7.0, r);
        float ridge = 1.0 - abs(2.0 * fbmN(qf * 1.6 + warp * 1.6, 6) - 1.0);
        float glow = fbmN(qf * 1.2 + warp, 5);
        em.x = (pow(ridge, 4.0) * 2.5 + smoothstep(0.45, 0.8, glow) * 1.2) * env;
        em.y = smoothstep(0.5, 0.85, fbmN(qf * 2.0 + 4.0 + warp, 5)) * exp(-dot(p, p) / 25.0) * 2.4;
        em.z = pow(1.0 - abs(2.0 * fbmN(qf * 2.4 - 2.0 + warp, 6) - 1.0), 6.0) * env * 2.0;
        // dust lanes with crisp edges, and a bright ionization rim where they meet the glow
        float lanes = fbmN(q * 2.2 + 9.0 + warp * 1.2, 6);
        dust = smoothstep(0.54, 0.58, lanes) * env * 6.0;
        em.x += exp(-pow((lanes - 0.54) / 0.02, 2.0)) * env * 2.5;
    } else if (type == 1) {
        float3 axis = normalize(float3(0.35 + 0.3 * hash13(sd), 1.0, 0.25));
        float ct = dot(p / max(r, 1e-3), axis);
        float R = 4.2 * (1.0 + 0.9 * pow(abs(ct), 4.0)) * (0.9 + 0.2 * hash13(sd + 2.0));
        float fil = 0.45 + 0.9 * fbm(p * 0.65 + sd + float3(k * 0.3, 0.0, 0.0));
        float shell = exp(-pow((r - R) / 0.85, 2.0));
        em.x = shell * fil * 1.4 + exp(-r / 5.5) * 0.04 * smoothstep(12.0, 8.0, r);
        em.y = exp(-pow(r / (R * 0.8), 2.0)) * 0.55 * (0.6 + 0.6 * fil);
        em.z = exp(-pow((r - R * 1.08) / 0.5, 2.0)) * fil * 0.7;
        dust = smoothstep(0.72, 0.86, fbm(p * 1.4 + sd + 4.0)) * shell * 3.0;   // cometary knots
    } else if (type == 2) {
        float shellR = 7.0 + (fbm(p * 0.18 + sd) - 0.5) * 3.5;
        float shell = exp(-pow((r - shellR) / 0.7, 2.0));
        float ridge = 1.0 - abs(2.0 * fbm(p * 0.38 + sd + float3(0.0, k * 0.25, 0.0)) - 1.0);
        float ridge2 = 1.0 - abs(2.0 * fbm(p * 0.55 + sd + 3.0) - 1.0);
        em.x = shell * pow(ridge, 4.0) * 2.2;
        em.y = shell * pow(ridge2, 5.0) * 1.8;
        em.z = shell * pow(ridge, 6.0) * 0.8;
    }
}

// Pillars (3) and dark nebula (4) are silhouettes, so they're drawn as layers: a glowing wall of
// gas behind, and a crisp dust layer in front whose edge glows where starlight (from above)
// is eating into it. Returns (Ha, OIII, SII, transmittance).
static float4 nebulaLayers(float3 camPos, float3 d, int type, float seed, float k) {
    float3 sd = float3(seed * 17.3, seed * 5.1, seed * 11.7);
    // glowing wall at z = 8
    float tw = (8.0 - camPos.z) / d.z;
    float2 w = (camPos + d * tw).xy;
    float3 qw = float3(w.x * 0.22, w.y * (type == 4 ? 0.05 : 0.12), seed) + sd + float3(0.0, k * 0.15, 0.0);
    float clouds = fbmN(qw, 7);
    float wisps = pow(1.0 - abs(2.0 * fbmN(qw * 1.8 + 3.0, 7) - 1.0), 6.0);
    float topLight = smoothstep(-16.0, 10.0, w.y);
    float3 wall;
    wall.x = (0.05 + 1.3 * pow(smoothstep(0.42, 0.82, clouds), 2.0) + 0.12 * wisps) * (0.12 + 1.1 * topLight * topLight);
    wall.y = pow(smoothstep(0.45, 0.8, fbmN(qw * 1.3 + 6.0, 6)), 1.4) * pow(topLight, 2.0) * (type == 3 ? 2.0 : 0.6);
    wall.z = wisps * 0.12 + pow(smoothstep(0.55, 0.85, clouds), 2.0) * 0.35;
    float wallT = 1.0 - saturate(dot(wall, float3(0.5)));          // the dimmest gaps let stars through

    // dust layer at z = 0
    float t0 = -camPos.z / d.z;
    float2 xy = (camPos + d * t0).xy;
    float edgeNoise = (fbmN(float3(xy * 0.9, seed) + sd, 7) - 0.5) * 1.0 + (fbmN(float3(xy * 4.0, seed + 3.0), 5) - 0.5) * 0.3;
    float sdf = dustShape(xy, type, seed) + edgeNoise;
    float alpha = smoothstep(0.06, -0.06, sdf);
    float up = dustShape(xy + float2(0.0, 0.4), type, seed) + edgeNoise;
    float lit = saturate((up - sdf) * 2.5 + 0.15);                  // faces turned toward the light
    float rim = exp(-pow(sdf / 0.1, 2.0)) * lit;
    float haze = exp(-max(sdf, 0.0) / 0.5) * step(0.0, sdf) * 0.12;
    // inside the dust: almost black, a little light seeping in near the lit edge
    float seep = exp(min(sdf, 0.0) / 0.5) * step(sdf, 0.0) * lit * 0.12 * (0.6 + 0.8 * fbmN(float3(xy * 1.5, seed + 9.0), 5));

    float3 em = wall * (1.0 - alpha) * 0.4;
    em += float3(1.6, type == 3 ? 1.2 : 0.35, 0.3) * rim + float3(1.0, 0.4, 0.2) * haze + float3(1.0, 0.3, 0.2) * seep;
    return float4(em, wallT * (1.0 - alpha));
}

// Bake: march each pixel's ray through the nebula volume twice (two slices of its slow flow).
// hitA / hitB = (Ha, OIII, SII, transmittance); shell0P.x = central star glow.
kernel void bakeNebula(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 d = cameraRay(P, gid, camPos);
    int type = int(P.nebulaType);
    float seed = P.nebulaSeed;
    float tc = -dot(camPos, d);
    float dmin = length(camPos + d * tc);
    // pillars and dark clouds stretch across the whole view, so they get a bigger volume
    float Rv = type >= 3 ? 1e4 : 13.0;
    float4 outs[2] = { float4(0.0, 0.0, 0.0, 1.0), float4(0.0, 0.0, 0.0, 1.0) };
    if (dmin < Rv) {
        float half_ = sqrt(Rv * Rv - dmin * dmin);
        const int N = 88;
        float dt = 2.0 * half_ / float(N);
        for (int k = 0; k < 2; k++) {
            if (type >= 3) { outs[k] = nebulaLayers(camPos, d, type, seed, float(k)); continue; }
            float3 col = float3(0.0);
            float T = 1.0;
            float jitter = hash13(float3(float2(gid), 3.0));   // breaks up banding from the fixed step
            for (int i = 0; i < N; i++) {
                float3 x = camPos + d * (tc - half_ + (float(i) + jitter) * dt);
                float3 em; float dust;
                nebulaSample(x, type, seed, float(k), em, dust);
                col += T * em * dt * 0.08;
                T *= exp(-dust * dt * 0.35);
                if (T < 0.01) break;
            }
            outs[k] = float4(col, T);
        }
    }
    hitA.write(outs[0], gid);
    hitB.write(outs[1], gid);
    float star = type == 1 ? exp(-dmin / 0.18) : 0.0;
    shell0P.write(float4(star, 0.0, 0.0, 0.0), gid);
    shell0D.write(float4(0.0), gid);
    shell1P.write(float4(-1.0), gid);
    shell1D.write(float4(0.0), gid);
    extraTex.write(float4(octEncode(d), 0.0, 1000.0), gid);
}

// S.a.x = flow period (s); S.b/c/d = colors for Ha, OIII, SII
fragment float4 nebulaFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float4 A = hitA.read(p), B = hitB.read(p);
    // each region morphs between the two baked slices on its own phase, so the gas seems to drift
    float phase = fbm(float3(float2(p) * 0.004, 2.0)) * 6.2831853;
    float w = 0.5 + 0.5 * sin(F.time * 6.2831853 / S.a.x + phase * 2.0);
    float4 v = mix(A, B, w);
    float shimmer = 0.9 + 0.1 * sin(F.time * 0.3 + phase * 3.0);
    float3 col = skyColor(sky, X, false, F, E, Pal) * v.w;
    col += (S.b.rgb * v.x + S.c.rgb * v.y + S.d.rgb * v.z) * shimmer;
    col += float3(0.85, 0.92, 1.0) * shell0P.read(p).x * 2.5;     // the central white dwarf
    return finalize(col, p, F);
}

// ---------- comet ----------
// Screen-space, in units of half the screen height (y up). S.a = head xy, activity, tail length;
// S.b = ion tail direction, dust curvature, outburst; S.c = ion color, disconnection position;
// S.d = dust color, disconnection strength; S.e = aspect, jet angle.

fragment float4 cometFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 col = skyColor(sky, X, false, F, E, Pal);
    float W = F.camRight.w, H = F.camUp.w;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    float2 v = q - S.a.xy;
    float act = S.a.z, L = S.a.w;
    float burst = S.b.w;
    float2 u = S.b.xy, n = float2(-u.y, u.x);

    // ion tail: straight, narrow, blue, combed into streamers by the solar wind
    float a = dot(v, u), b = dot(v, n);
    float ion = 0.0;
    if (a > -0.03) {
        float width = 0.012 + 0.05 * max(a, 0.0);
        float streak = fbm(float3(a * 3.0 - F.time * 0.22, b / width * 2.2, F.time * 0.03));
        float rays = pow(streak, 3.0) * 3.0;
        float kink = sin(a * 6.0 - F.time * 0.5) * 0.008 * a;
        float bb = (b - kink) / width;
        ion = exp(-bb * bb) * exp(-max(a, 0.0) / (1.4 * L)) * (0.35 + rays) * smoothstep(-0.03, 0.04, a);
        if (S.c.w > 0.0) {
            // a disconnection event: the tail snaps and the loose piece drifts away
            float gap = exp(-pow((a - S.c.w) / 0.04, 2.0));
            ion *= 1.0 - S.d.w * gap * 0.9 * step(a, S.c.w + 0.02);
            ion *= mix(1.0, 1.0 + 1.5 * S.d.w * smoothstep(S.c.w, S.c.w + 0.15, a) * (1.0 - smoothstep(S.c.w + 0.15, S.c.w + 0.45, a)), step(S.c.w, a));
        }
    }

    // dust tail: broader, curved, yellow-white, with striations
    float2 ud = normalize(u + n * 0.45), nd = float2(-ud.y, ud.x);
    float ad = dot(v, ud), bd = dot(v, nd) + S.b.z * ad * ad;
    float dustT = 0.0;
    if (ad > -0.03) {
        float width = 0.02 + 0.16 * max(ad, 0.0);
        float bb = bd / width;
        float striae = 0.75 + 0.25 * sin(bd * 40.0 + ad * 8.0 - F.time * 0.05) * fbm(float3(ad * 2.0 - F.time * 0.04, bb, 9.0));
        dustT = exp(-bb * bb * 0.8) * exp(-max(ad, 0.0) / (1.1 * L)) * striae * smoothstep(-0.03, 0.06, ad);
    }

    // coma, nucleus, and rotating jets
    float rr = length(v);
    float ang = atan2(v.y, v.x);
    float jets = pow(0.5 + 0.5 * cos(ang * 2.0 - S.e.y), 10.0) * exp(-rr / 0.035) * 0.8;
    float coma = exp(-rr / 0.028) * 1.4 + exp(-rr / 0.1) * 0.35;
    float nucleus = exp(-pow(rr / 0.005, 2.0)) * 5.0;
    float k = act * (1.0 + 2.5 * burst);
    col += S.c.rgb * ion * 0.9 * act;
    col += S.d.rgb * dustT * 0.6 * act;
    col += mix(S.d.rgb, float3(0.7, 1.0, 0.85), 0.5) * (coma + jets) * k + float3(1.0) * nucleus;
    return finalize(col, p, F);
}

// ---------- star close-up ----------
// Screen-space, units of half the screen height. S.a = disk center xy, radius, rotation;
// S.b = star color, spot amount; S.c = flare position xy, brightness, size; S.d = coronal mass
// ejection angle, radius, brightness, thickness; S.f = flare angle, brightness.

static float2 hash22(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

// Granulation: Voronoi cells (bright tops, dark intergranular lanes) whose centers wander.
static float granules(float2 x, float time) {
    float2 i = floor(x), f = fract(x);
    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++)
    for (int xk = -1; xk <= 1; xk++) {
        float2 g = float2(xk, y);
        float2 h = hash22(i + g);
        float2 o = 0.5 + 0.38 * sin(time * 0.12 + 6.2831 * h);
        float d = length(g + o - f);
        if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
    }
    return smoothstep(0.0, 0.6, f2 - f1) * (0.7 + 0.3 * (1.0 - f1));
}

fragment float4 stellarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 col = skyColor(sky, X, false, F, E, Pal) * 0.6;
    float W = F.camRight.w, H = F.camUp.w;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    float2 C = S.a.xy;
    float R = S.a.z;
    float2 d = q - C;
    float dist = length(d);
    float3 starCol = S.b.rgb;
    starCol = max(mix(float3(dot(starCol, float3(0.3, 0.55, 0.15))), starCol, 1.8), 0.0);   // richer surface color
    float spotAmt = S.b.w;
    float ang = atan2(d.y, d.x);

    if (dist < R) {
        float2 n2 = d / R;
        float3 N = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
        float mu = N.z;
        float lon = atan2(N.x, N.z) + S.a.w, lat = asin(clamp(N.y, -1.0, 1.0));
        float2 surf = float2(lon * cos(lat), lat);
        float limb = 0.28 + 0.72 * pow(mu, 0.55);
        float gran = mix(granules(surf * 48.0, F.time), fbm(float3(surf * 90.0, F.time * 0.01)), 0.35) * 0.45 + 0.68;
        float superg = 0.92 + 0.08 * fbm(float3(surf * 9.0, F.time * 0.002));
        // sunspots: each lives a while, then fades, and drifts with the rotation
        float spot = 1.0;
        float facula = 0.0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float life = 240.0 + 120.0 * hash13(float3(fi, 1.0, 3.0));
            float cyc = F.time / life + hash13(float3(fi, 2.0, 3.0));
            float gen = floor(cyc);
            float age = fract(cyc);
            float vis = smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.75, 1.0, age));
            if (hash13(float3(fi, gen, 4.0)) > spotAmt * 0.9) continue;
            float2 sc = float2((hash13(float3(fi, gen, 5.0)) - 0.5) * 2.4, (hash13(float3(fi, gen, 6.0)) - 0.3) * 0.9);
            float size = (0.025 + 0.05 * hash13(float3(fi, gen, 7.0))) * vis;
            float2 dd = surf - sc;
            dd.x -= 6.2831853 * floor(dd.x / 6.2831853 + 0.5);
            float sd = length(dd);
            float fil = 0.7 + 0.3 * sin(atan2(dd.y, dd.x) * 40.0 + fbm(float3(dd * 60.0, fi)) * 4.0);
            float umbra = smoothstep(size * 0.45, size * 0.3, sd);
            float pen = smoothstep(size, size * 0.6, sd);
            spot *= mix(1.0, 0.55 * fil, pen) * mix(1.0, 0.25, umbra);
            facula += smoothstep(size * 3.0, size, sd) * (1.0 - pen) * 0.25;
        }
        float bright = limb * gran * superg * spot * (1.0 + facula * (1.0 - mu) * 2.0);
        col = starCol * bright * 0.7 * mix(float3(1.0, 0.55, 0.3), float3(1.0), pow(mu, 0.4));   // the limb reddens
        if (S.c.z > 0.0) {
            // flare: two bright ribbons, then a glow
            float fd = length(q - S.c.xy);
            float ribbon = exp(-pow((abs(dot(q - S.c.xy, float2(0.6, 0.8))) - S.c.w * 0.4) / (S.c.w * 0.15), 2.0)) * exp(-fd / S.c.w);
            col += float3(1.0, 0.97, 0.9) * S.c.z * (ribbon * 1.5 + exp(-fd / (S.c.w * 0.8)) * 0.6);
        }
    } else {
        float h = (dist - R) / R;
        // chromosphere and spicules
        float chromo = exp(-h / 0.006);
        float spic = fbm(float3(ang * 260.0, h * 90.0 - F.time * 0.35, 1.0));
        float spicules = smoothstep(0.45, 0.8, spic) * exp(-h / 0.02);
        float3 hAlpha = float3(1.0, 0.25, 0.3);
        col += hAlpha * (chromo * 1.4 + spicules * 0.7);
        // corona with streamers
        float stream = fbm(float3(cos(ang) * 5.0, sin(ang) * 5.0, F.time * 0.004));
        col += mix(starCol, float3(1.0), 0.5) * exp(-h / (0.06 + 0.12 * stream)) * (0.05 + 0.12 * stream);
        // coronal loops: arches rooted on the limb, with plasma streaming along them
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float life = 300.0 + 200.0 * hash13(float3(fi, 8.0, 1.0));
            float cyc = F.time / life + hash13(float3(fi, 9.0, 1.0));
            float gen = floor(cyc), age = fract(cyc);
            float vis = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.7, 1.0, age));
            float a0 = 0.45 + 2.2 * hash13(float3(fi, gen, 2.0));
            float span = 0.04 + 0.07 * hash13(float3(fi, gen, 3.0));
            float hgt = 0.04 + 0.12 * hash13(float3(fi, gen, 4.0));
            float da = ang - a0;
            float x = da / span;
            float y = h / hgt;
            float e = sqrt(x * x + y * y);
            float tube = exp(-pow((e - 1.0) * hgt * R / 0.006, 2.0)) * step(0.0, y);
            float flow = 0.6 + 0.4 * sin(atan2(y, x) * 8.0 - F.time * 1.2 + fi);
            float boost = 1.0 + 3.0 * S.f.y * exp(-pow((a0 - S.f.x) / 0.15, 2.0));
            col += mix(hAlpha, starCol, 0.5) * tube * flow * vis * 0.9 * boost;
        }
        // prominences: clouds of cooler plasma hanging above the limb
        float prom = smoothstep(0.58, 0.82, fbm(float3(ang * 7.0, h * 14.0 - F.time * 0.01, 4.0)))
                   * exp(-h / 0.07) * smoothstep(0.5, 0.7, fbm(float3(ang * 2.0, 1.0, 7.0)));
        col += hAlpha * prom * 1.1;
        if (S.d.z > 0.0) {
            // coronal mass ejection: a bright expanding loop leaving the star
            float2 base = C + float2(cos(S.d.x), sin(S.d.x)) * R;
            float2 cc = base + float2(cos(S.d.x), sin(S.d.x)) * S.d.y * 0.6;
            float rad = S.d.y * 0.55;
            float shell = exp(-pow((length(q - cc) - rad) / S.d.w, 2.0));
            float core = exp(-length(q - cc) / (rad * 0.4 + 0.01)) * 0.4;
            col += mix(starCol, hAlpha, 0.4) * (shell * 0.7 + core) * S.d.z * smoothstep(-0.02, 0.05, h);
        }
    }
    return finalize(col, p, F);
}
"""
