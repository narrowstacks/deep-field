extension ShaderSource {
    static let lensed = """
// ---------- per-frame: black hole, tidal disruption and wormhole ----------

static float diskNoise(float r, float ang, float seed) {
    float3 p = float3(cos(ang) * 2.6, sin(ang) * 2.6, r * 3.2 + seed);
    float n = fbm(p);
    float3 q = float3(cos(ang) * 7.0, sin(ang) * 7.0, r * 9.0 - seed);
    return n * 0.75 + noise3(q) * 0.25;
}

// A darker, deeper shade of c: its channels weighted by how much of the strongest one they hold,
// so it stays the same hue at any brightness (c * c only does that when the strongest is 1).
static float3 deepen(float3 c) {
    return c * c / max(max(c.r, max(c.g, c.b)), 1e-4);
}

// Accretion disk at a crossing h = (radius, angle, redshift g, event). rec / app / core: the
// receding, approaching and hottest colors; rin / rout: inner edge and outer radius.
static float4 shadeDisk(float4 h, constant FrameParams& F, float3 rec, float3 app, float3 core, float rin, float rout) {
    float r = h.x, phi = h.y, g = h.z;
    float x = (r - rin) / (rout - rin);
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
    float3 warm = mix(deepen(rec) * 0.5, rec, smoothstep(0.0, 0.6, heat));
    warm = mix(warm, core, smoothstep(0.7, 1.0, heat) * 0.6);
    float appMax = max(app.r, max(app.g, app.b));
    float3 cool = mix(deepen(app) * 0.85, mix(app, float3(appMax), 0.35), smoothstep(0.2, 1.0, heat));
    float shift = smoothstep(0.95, 1.30, g);
    float3 col = mix(warm, cool, shift);

    float beaming = pow(clamp(g, 0.35, 1.8), 2.2);
    float radial = pow(rin / r, 1.3);
    float emit = prof * radial * beaming * (0.30 + 1.1 * dens);
    float alpha = saturate(prof * (0.55 + 0.7 * dens) * 1.25);
    return float4(col * emit * 2.2, alpha);
}

// ---------- star meets black hole ----------
// S: a = (star color, spot activity), b = (stream brightness, jets on, 0, 0),
// c = (jet color, disk outer radius), d / e / f = disk receding / approaching / core colors.
// The bake (bakeBlackHole) traced the star, stream and jets; see its notes for the layout.

static float4 tdeDisk(float4 h, constant FrameParams& F, constant SceneParams& S) {
    return shadeDisk(h, F, S.d.rgb, S.e.rgb, S.f.rgb, F.diskIn, S.c.w);
}

// The star's surface at a baked hit: granulation, spots, limb darkening, and the tip toward
// the hole (where the stream leaves) heated and lit by the disk.
static float3 tdeStarSurface(float4 st, constant FrameParams& F, constant SceneParams& S) {
    float3 n = octDecode(st.xy);
    float mu = st.z;
    float t = F.time;
    float gran = fbm(n * 16.0 + float3(0.0, 0.0, t * 0.02));
    float cells = noise3(n * 45.0 + t * 0.02);
    float spots = S.a.w > 0.0 ? smoothstep(0.7, 0.78, fbm(n * 5.0 + 5.3)) * S.a.w : 0.0;
    float3 base = S.a.rgb;
    // limb darkening, deeper in color toward the edge
    float3 tint = pow(max(base, 0.001), 4.0 - 3.0 * sqrt(mu));
    float3 col = tint * (0.25 + 0.95 * pow(mu, 0.7)) * (0.85 + 0.25 * gran + 0.1 * cells);
    col *= 1.0 - spots * (0.85 - 0.5 * base * base);                                // dark umbrae, warmer edges
    float tip = smoothstep(0.6, 0.98, n.x);
    col += mix(base, float3(1.0), 0.3) * tip * 0.3 * (0.6 + 0.8 * gran);    // the L1 tip, where gas boils off
    col += S.f.rgb * saturate(n.x) * 0.12 * (0.3 + 0.7 * mu);              // lit by the disk
    return col * 0.8;
}

// Gas in the stream: hot where it leaves the star, cooling and clumping into filaments on the
// way in, shocked bright again where it slams into the disk's rim, then trailing round it.
static float3 tdeStreamColor(float s, float u, constant FrameParams& F, constant SceneParams& S, thread float& fil) {
    float flow = F.time * 0.012;             // the gas drifts toward the hole, slowly
    float streaks = fbm(float3((s - flow) * 7.0, u * 3.2, 3.0));
    float clumps = noise3(float3((s - flow * 1.3) * 30.0, u * 1.5, 11.0));
    fil = 0.12 + 1.3 * smoothstep(0.32, 0.78, streaks) * (0.6 + 0.6 * clumps);
    fil = max(fil, 1.2 * (1.0 - smoothstep(0.0, 0.12, s)));   // a solid neck where it leaves the star
    float3 star = S.a.rgb;
    float3 warm = mix(S.d.rgb, S.f.rgb, 0.25);
    float3 col = mix(star, warm * 0.8, smoothstep(0.03, 0.32, s));
    col = mix(col, deepen(warm) * 0.7, smoothstep(0.1, 0.6, s) * smoothstep(0.9, -0.2, fil));  // dimmer gaps cool and redden
    float shock = exp(-pow((s - 1.0) / 0.14, 2.0));
    col = mix(col, mix(S.f.rgb, float3(1.0), 0.4) * 1.4, shock * 0.7);
    float bright = (1.1 - 0.65 * smoothstep(0.0, 0.5, s)) * (1.0 - 0.5 * smoothstep(1.1, 1.8, s));
    return col * bright;
}

fragment float4 lensedFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    bool wormhole = F.scene > 0.5 && F.scene < 1.5;
    int lightCount = int(F.lightCount);

    // Layers indexed by event order along the ray (0 = nearest), composited back to front.
    // Nothing behind the nearest opaque layer shows, so it isn't shaded (or even read).
    float4 layers[6] = { float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0) };
    int opaque = 6;
    if (!wormhole) {
        float3 rec = Pal.receding.rgb, app = Pal.approaching.rgb, core = Pal.core.rgb;
        float4 A = hitA.read(p);
        if (A.w > 0.0) {
            int ia = min(int(A.w) - 1, 5);
            layers[ia] = shadeDisk(A, F, rec, app, core, F.diskIn, F.diskOut);
            if (layers[ia].a >= 1.0) opaque = ia;
            float4 B = hitB.read(p);              // a second crossing only exists after a first
            int ib = min(int(B.w) - 1, 5);
            if (B.w > 0.0 && ib < opaque) {
                layers[ib] = shadeDisk(B, F, rec, app, core, F.diskIn, F.diskOut);
                if (layers[ib].a >= 1.0) opaque = min(opaque, ib);
            }
        }
    }
    int count = int(F.planetCount);
    if (count > 0) {
        float4 sp[2] = { shell0P.read(p), shell1P.read(p) };
        float radii[2] = { F.shellR0, F.shellR1 };
        for (int s = 0; s < 2; s++) {
            for (int k = 0; k < 2; k++) {
                float2 tp = k == 0 ? sp[s].xy : sp[s].zw;
                if (tp.x <= 0.0) continue;
                float packed = tp.x * 25.0 - 0.5;           // see recordShell
                float ev = floor(packed / 4.0);
                int il = min(int(ev), 5);
                if (il >= opaque) continue;
                float theta = packed - ev * 4.0, phi = tp.y * 6.2831853 - 3.1415927;
                float3 Xs = radii[s] * float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
                if (!planetsNearShellPoint(Xs, radii[s], s, planets, count)) continue;
                float4 sd = s == 0 ? shell0D.read(p) : shell1D.read(p);
                float3 v = octDecode(k == 0 ? sd.xy : sd.zw);
                float4 pc = shadePlanetsOnShell(Xs, v, s, planets, count, lights, lightCount);
                if (pc.a > 0.0) { layers[il] = pc; opaque = il; }
            }
        }
    }

    float3 col = float3(0.0);
    float info = infoTex.read(p).x;
    if (opaque < 6) {
        // fully covered: the sky, ring and rim would be multiplied by zero
    } else if (!wormhole) {
        if (info >= 1.0) {
            col = SKY(p, octDecode(dirTex.read(p).xy), false);
            col += Pal.ring.rgb * exp(-(info - 1.5) * 40.0) * 1.2 * F.ringStrength;  // photon ring
        }
    } else {
        bool far = info < 0.0;
        col = SKY(p, octDecode(dirTex.read(p).xy), far);
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
    return finalize(col, p, F);
}

// Star meets black hole: the disk, the star, the stream and the jets, all from the bake.
fragment float4 tdeFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 layers[6] = { float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0) };
    int opaque = 6;
    float4 A = hitA.read(p);
    if (A.w > 0.0) {
        int ia = min(int(A.w) - 1, 5);
        layers[ia] = tdeDisk(A, F, S);
        if (layers[ia].a >= 1.0) opaque = ia;
        float4 B = hitB.read(p);
        int ib = min(int(B.w) - 1, 5);
        if (B.w > 0.0 && ib < opaque) {
            layers[ib] = tdeDisk(B, F, S);
            if (layers[ib].a >= 1.0) opaque = min(opaque, ib);
        }
    }
    float4 star = shell1P.read(p);
    if (star.w > 0.0) {
        int is = min(int(star.w) - 1, 5);
        if (is < opaque) { layers[is] = float4(tdeStarSurface(star, F, S), 1.0); opaque = is; }
    }

    float3 col = float3(0.0);
    float4 info = infoTex.read(p);
    if (opaque == 6 && info.x >= 1.0) {
        col = SKY(p, octDecode(dirTex.read(p).xy), false);
        col += Pal.ring.rgb * exp(-(info.x - 1.5) * 40.0) * 1.2 * F.ringStrength;  // photon ring
    }

    // Gas (stream and jets) was split at the first disk crossing: what lies behind it goes
    // under the nearest layer, the rest on top.
    float4 sv = shell0P.read(p);
    float3 gasBack = float3(0.0), gasFront = float3(0.0);
    float aBack = 0.0, aFront = 0.0;
    if (sv.x + sv.y > 0.002) {
        float fil;
        float3 sc = tdeStreamColor(sv.z, sv.w, F, S, fil) * S.b.x;
        // an emitting, absorbing slab: thick gas saturates at its own color instead of white
        aBack = 1.0 - exp(-sv.y * fil * 1.4);
        aFront = 1.0 - exp(-sv.x * fil * 1.4);
        gasBack = sc * aBack * 1.3;
        gasFront = sc * aFront * 1.3;
    }
    if (S.b.y > 0.0 && info.y + info.z > 0.001) {
        // knots running out along the jets, brightest at the base
        float y = info.w;
        float knots = 0.4 + 0.9 * smoothstep(0.4, 0.85, noise3(float3(y * 0.5 - F.time * 0.25, 0.0, 5.0)));
        float3 jc = S.c.rgb * knots * (0.12 + 0.45 * exp(-y / 3.0));
        gasBack += jc * info.z;
        gasFront += jc * info.y;
    }
    for (int i = 5; i >= 1; i--) col = col * (1.0 - layers[i].a) + layers[i].rgb;
    col = col * (1.0 - aBack) + gasBack;
    col = col * (1.0 - layers[0].a) + layers[0].rgb;
    col = col * (1.0 - aFront) + gasFront;
    if (star.w == 0.0) {
        // a tight glow round the star (lensed with it)
        float d = max(-star.z - 0.93, 0.0);
        col += S.a.rgb * (exp(-d * 10.0) * 0.35 + exp(-d * 3.0) * 0.025);
    }
    return finalize(col, p, F);
}
"""
}
