extension ShaderSource {
    static let nebula = """
// ---------- nebula (hidden scene): volume bake and per-frame ----------

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
// hitA / hitB = (Ha, OIII, SII, transmittance).
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
    dirTex.write(float4(octEncode(d), 0.0, 0.0), gid);
}

// S.a.x = flow period (s); S.b/c/d = colors for Ha, OIII, SII
fragment float4 nebulaFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float4 A = hitA.read(p), B = hitB.read(p);
    // each region morphs between the two baked slices on its own phase, so the gas seems to drift
    float phase = fbm(float3(float2(p) * 0.004, 2.0)) * 6.2831853;
    float w = 0.5 + 0.5 * sin(F.time * 6.2831853 / S.a.x + phase * 2.0);
    float4 v = mix(A, B, w);
    float shimmer = 0.9 + 0.1 * sin(F.time * 0.3 + phase * 3.0);
    float3 col = SKY(p, rd, false) * v.w;
    col += (S.b.rgb * v.x + S.c.rgb * v.y + S.d.rgb * v.z) * shimmer;
    if (int(F.nebulaType) == 1) {
        // the planetary nebula's central white dwarf
        float3 ro = F.camPos.xyz;
        float dmin = length(ro - rd * dot(ro, rd));
        col += float3(0.85, 0.92, 1.0) * exp(-dmin / 0.18) * 2.5;
    }
    return finalize(col, p, F);
}
"""
}
