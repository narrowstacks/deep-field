extension ShaderSource {
    static let sky = """
// ---------- bake: sky scalars (all scenes) ----------

// Sky as scalars: (star brightness, star tint, nebula A, nebula B) and a star id.
// `fp` is the angular footprint of this pixel on the sky; where lensing squeezes a lot of sky
// into one pixel, detail is filtered instead of aliasing into moire.
// A different star field for each sky seed: the whole field turns to a hashed orientation, so
// stars, nebulae and galaxies keep their look and only where they sit changes. Seed 0 is the
// original sky.
static float3 seededSky(float3 d, float s) {
    if (s == 0.0) return d;
    float3 q = float3(s * 0.0137, s * 0.0291 + 3.1, 7.7);
    float3 h = float3(hash13(q), hash13(q + 19.1), hash13(q + 37.3));
    float3 axis = normalize(h - 0.5 + float3(1e-3, 0.0, 0.0));
    float a = 0.6 + 5.0 * fract(h.x * 7.13 + h.y * 3.71);
    float c = cos(a), sn = sin(a);
    return d * c + cross(axis, d) * sn + axis * dot(axis, d) * (1.0 - c);
}

static float4 skyScalars(float3 d0, float fp, constant BakeParams& P, float seed, thread float& id) {
    float3 d = seededSky(d0, P.skySeed);
    float pixelAngle = 2.0 * P.tanHalfFov / P.height;
    float k = max(fp / pixelAngle, 1.0);           // > 1 where the sky is compressed
    float cells = 0.9 / pixelAngle;
    float3 p = d * cells;
    float3 c = floor(p) + seed * 131.0;
    float h = hash13(c);
    // galactic band: a tilted great circle of dense stars, glow and dark dust lanes
    float band = 0.0, dust = 0.0;
    if (P.milkyWay > 0.5 && seed == 0.0) {
        float lat = dot(d0, normalize(float3(0.42, 0.9, 0.08)));
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

// Whether a pixel shows sky at all: black holes have a shadow with none in it.
static bool hasSky(float info, constant BakeParams& P) { return P.lensing < 0.5 || P.lensing > 1.5 || info >= 1.0; }
static bool sameSide(float a, float b) { return (a < 0.0) == (b < 0.0); }

// Where a pixel looks on the sky: straight from the camera without lensing (exact, no need
// to read it back), else the ray bake's outgoing direction.
static float3 skyDir(texture2d<float, access::read> dirTex, constant BakeParams& P, uint2 g) {
    if (P.lensing < 0.5) { float3 camPos; return cameraRay(P, g, camPos); }
    return octDecode(dirTex.read(g).xy);
}

// Runs after the ray bake. Works out each pixel's sky footprint from its neighbours' ray
// directions, then evaluates the sky with matching detail. The star id goes to its own
// texture, quantized to 1/4096 steps (0 = none).
kernel void skyPass(texture2d<float, access::read> dirTex  [[texture(0)]],
                    texture2d<float, access::read> infoTex [[texture(1)]],
                    texture2d<float, access::write> skyTex [[texture(2)]],
                    texture2d<uint, access::write> idTex   [[texture(3)]],
                    constant BakeParams& P [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint W = uint(P.width), H = uint(P.height);
    if (gid.x >= W || gid.y >= H) return;
    bool lensed = P.lensing > 0.5;
    float info = lensed ? infoTex.read(gid).x : 1000.0;
    if (!hasSky(info, P)) { skyTex.write(float4(0.0), gid); idTex.write(uint4(0), gid); return; }
    float3 d = skyDir(dirTex, P, gid);

    float pixelAngle = 2.0 * P.tanHalfFov / P.height;
    float fp = pixelAngle;
    uint2 nb[4] = { uint2(min(gid.x + 1, W - 1), gid.y), uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y),
                    uint2(gid.x, min(gid.y + 1, H - 1)), uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0) };
    for (int i = 0; i < 4; i++) {
        float infoN = lensed ? infoTex.read(nb[i]).x : 1000.0;
        if (!hasSky(infoN, P) || !sameSide(info, infoN)) continue;
        fp = max(fp, length(skyDir(dirTex, P, nb[i]) - d));
    }

    float id = 0.0;
    float4 sky;
    if (P.lensing > 1.5 && info < 0.0) {
        float ce = cos(P.camElev), se = sin(P.camElev);
        float3 e1 = float3(0.0, se, -ce);
        sky = farSkyScalars(d, fp, normalize(e1 + float3(0.06, 0.08, 0.0)), P, id);
    } else {
        sky = skyScalars(d, fp, P, 0.0, id);
    }
    skyTex.write(sky, gid);
    idTex.write(uint4(id > 0.0 ? 1u + uint(floor(id * 4094.0)) : 0u), gid);
}

// ---------- per-frame: sky color ----------

// Background sky with its occasional phenomena, for sky scalars `sky`, quantized star id
// `idq` and sky direction `dir`. `far` = the wormhole's other universe.
static float3 skyColor(float4 sky, uint idq, float3 dir, bool far, constant FrameParams& F,
                       constant Events& E, constant Palette& Pal) {
    float3 col = float3(0.0);
    float bright = sky.x, tint = sky.y, id = float(idq) / 4096.0;
    if (bright > 0.0) {
        if (tint > 1.0) {
            col = mix(Pal.galaxy.rgb, Pal.starCool.rgb, 0.5 * (tint - 1.0)) * bright;
        } else {
            col = mix(Pal.starWarm.rgb, Pal.starCool.rgb, tint) * bright;
            if (id > 0.0) {
                // occasional twinkle: each star rolls the dice every ~5 s (at speed 1)
                float tt = F.time * F.twinkleSpeed;
                float slotPos = tt * 0.2 + id * 97.0;
                float roll = hash13(float3(id * 1000.0, floor(slotPos), 7.0));
                if (roll > 1.0 - 0.06 * F.twinkle) {
                    float env = sin(3.14159 * fract(slotPos));
                    float flick = 0.5 + 0.5 * sin(tt * 23.0 + id * 61.0) * sin(tt * 9.0 + id * 17.0);
                    col *= 1.0 + env * env * (1.0 + 3.0 * flick) * F.twinkleBrightness;
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
            float c = length(dir - E.farSn.xyz);
            float3 hot = mix(float3(0.75, 0.88, 1.0), float3(1.0, 0.5, 0.25), E.farSnParams.y);
            col += hot * (E.farSn.w * exp(-pow(c / 0.05, 2.0)) + E.farSnParams.x * exp(-c / 0.15));
        }
        return col;
    }
    col += (Pal.nebulaA.rgb * sky.z * 0.02 + Pal.nebulaB.rgb * sky.w * 0.012) * F.skyBrightness;

    // sky events live in sky-direction space, so lensing applies to them like everything else
    float pa = F.pixelAngle;
    if (E.snDir.w > 0.0) {
        float3 S = E.snDir.xyz;
        float3 dd = dir - S;
        float c = length(dd);
        float core = E.snDir.w * exp(-pow(c / (1.3 * pa), 2.0));
        float halo = E.snParams.x * (exp(-c / (4.0 * pa)) + 0.15 * exp(-c / (14.0 * pa)));
        float3 hot = mix(float3(0.70, 0.85, 1.00), float3(1.00, 0.45, 0.20), E.snParams.w);
        float3 light = hot * (core + halo);
        float echoR = E.snParams.y;
        float echoW = (1.6 + 0.04 * echoR / pa) * pa;      // the echo thickens as it spreads
        if (c < 30.0 * pa || (E.snParams.z > 0.0 && abs(c - echoR) < 6.0 * echoW)) {
            // the flash's own sky plane: x, y in pixels from the supernova
            float3 t1 = normalize(cross(S, float3(0.31, 0.92, 0.22)));
            float3 t2 = cross(S, t1);
            float2 xy = float2(dot(dd, t1), dot(dd, t2)) / pa;
            // four faint diffraction spikes while it is at its brightest
            float2 ax = abs(float2(xy.x + xy.y, xy.x - xy.y)) * 0.7071;
            float spikes = (exp(-ax.x / 0.6) * exp(-ax.y / 7.0) + exp(-ax.y / 0.6) * exp(-ax.x / 7.0));
            light += hot * spikes * E.snDir.w * 0.05;
            if (E.snParams.z > 0.0) {
                // Light echoes: the flash lighting up sheets of dust as it sweeps through them.
                // The dust is fixed on the sky, so the expanding rings brighten and fade in
                // patches as they cross it. A second, fainter sheet lags behind the first.
                float dust = fbm(float3(xy / 22.0, 3.0));
                float dust2 = fbm(float3(xy / 15.0, 11.0));
                float patch1 = smoothstep(0.4, 0.72, dust);
                float patch2 = smoothstep(0.45, 0.8, dust2);
                float ring1 = exp(-pow((c - echoR) / echoW, 2.0));
                float ring2 = exp(-pow((c - echoR * 0.62) / (echoW * 0.8), 2.0));
                float echo = E.snParams.z * (ring1 * (0.12 + 1.5 * patch1) + ring2 * patch2 * 0.7);
                // inner edges are lit by the bluer early light, outer edges by the redder tail
                float3 echoCol = mix(float3(0.62, 0.62, 1.00), float3(0.95, 0.55, 0.85), saturate((c - echoR) / echoW * 0.5 + 0.5));
                light += echoCol * echo;
            }
        }
        col += light;
    }
    if (E.cometHead.w > 0.0) {
        // A comet passing: green coma, a straight blue ion tail, and a broader, fainter, curved
        // dust tail peeling off to one side.
        float3 H = E.cometHead.xyz;
        float3 seg = E.cometTail.xyz - H;
        float segLen2 = dot(seg, seg);
        float tt = saturate(dot(dir - H, seg) / segLen2);
        float dh = length(dir - H);
        float hw = E.cometTail.w;
        if (dh < sqrt(segLen2) * 1.5 + hw * 8.0) {
            float dseg = length(dir - (H + seg * tt));
            float w = hw * (0.8 + tt * 3.0);
            float streak = 0.75 + 0.25 * sin(tt * 40.0 - F.time * 0.3);
            float ion = exp(-pow(dseg / w, 2.0)) * pow(1.0 - tt, 2.2) * streak;
            float3 side = cross(H, seg);
            float3 bend = side * (0.35 / max(length(side), 1e-6)) * sqrt(segLen2);
            float3 dustPt = H + seg * (tt * 0.8) + bend * tt * tt;
            float dd = length(dir - dustPt);
            float dustT = exp(-pow(dd / (hw * (1.0 + tt * 9.0)), 2.0)) * pow(1.0 - tt, 2.0);
            float head = exp(-pow(dh / (hw * 1.1), 2.0));
            float coma = exp(-dh / (hw * 2.5));
            col += E.cometHead.w * (float3(0.85, 1.00, 0.95) * head * 2.0 + float3(0.45, 0.95, 0.65) * coma * 0.35
                                  + float3(0.35, 0.65, 1.00) * ion * 0.7 + float3(1.00, 0.85, 0.60) * dustT * 0.45);
        }
    }
    return col;
}

// The sky color at pixel p, seen along dir (inside a fragment shader with FRAME_INPUTS).
#define SKY(p, dir, far) skyColor(skyTex.read(p), idTex.read(p).r, dir, far, F, E, Pal)
"""
}
