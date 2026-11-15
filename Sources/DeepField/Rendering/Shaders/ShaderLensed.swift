extension ShaderSource {
    static let lensed = """
// ---------- per-frame: black hole, tidal disruption and wormhole ----------

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

fragment float4 lensedFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    bool wormhole = F.scene > 0.5 && F.scene < 1.5;
    bool tde = F.scene > 4.5;
    int lightCount = int(F.lightCount);

    // Layers indexed by event order along the ray (0 = nearest), composited back to front.
    // Nothing behind the nearest opaque layer shows, so it isn't shaded (or even read).
    float4 layers[6] = { float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0), float4(0.0) };
    int opaque = 6;
    if (!wormhole) {
        float4 A = hitA.read(p);
        if (A.w > 0.0) {
            int ia = min(int(A.w) - 1, 5);
            layers[ia] = tde ? shadeTDE(A, F, Pal, S) : shadeDisk(A, F, Pal);
            if (layers[ia].a >= 1.0) opaque = ia;
            float4 B = hitB.read(p);              // a second crossing only exists after a first
            int ib = min(int(B.w) - 1, 5);
            if (B.w > 0.0 && ib < opaque) {
                layers[ib] = tde ? shadeTDE(B, F, Pal, S) : shadeDisk(B, F, Pal);
                if (layers[ib].a >= 1.0) opaque = min(opaque, ib);
            }
        }
    }
    int count = int(F.planetCount);
    if (count > 0) {
        float4 sp[2] = { shell0P.read(p), shell1P.read(p) };
        float4 sd[2] = { sp[0].x >= 0.0 ? shell0D.read(p) : float4(0.0), sp[1].x >= 0.0 ? shell1D.read(p) : float4(0.0) };
        float radii[2] = { F.shellR0, F.shellR1 };
        for (int s = 0; s < 2; s++) {
            for (int k = 0; k < 2; k++) {
                float2 tp = k == 0 ? sp[s].xy : sp[s].zw;
                if (tp.x < 0.0) continue;
                float ev = floor(tp.x / 4.0);
                int il = min(int(ev), 5);
                if (il >= opaque) continue;
                float theta = tp.x - ev * 4.0;
                float3 Xs = radii[s] * float3(sin(theta) * cos(tp.y), cos(theta), sin(theta) * sin(tp.y));
                float3 v = octDecode(k == 0 ? sd[s].xy : sd[s].zw);
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
"""
}
