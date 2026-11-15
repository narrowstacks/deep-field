extension ShaderSource {
    static let ringed = """
// ---------- per-frame: ringed planet ----------
// A gas giant close up, with its rings, two moons and the sun off to one side. Everything is
// traced per pixel: the oblate planet, the ring plane and the moons, sorted by distance. The
// rings are semi-transparent, so stars and the planet show through their thin parts.
//
// S.a = spin axis (the ring plane's normal), equatorial radius R
// S.b = direction to the sun, sun brightness
// S.c = light band color, the storm head's longitude in the bands' own (drifting) frame
// S.d = dark band color, storm progress (0 = none, else 0..1)
// S.e = ring color, w unused
// S.f / S.g / S.h = moon centers, radius (0 = none)
// S.i = band scale, turbulence, wind, unused
// S.j = ring style (0 classic, 1 broad, 2 narrow ringlets, 3 none), width, density, spokes (0/1)
// Uses rotateAbout (pulsar) and spheroidSpan (planetary nebula).

constant float RG_FLAT = 0.9;          // polar over equatorial radius
constant float RG_STORM_LAT = 0.52;    // sine of the storm band's latitude

// The bands' drift: the whole cloud deck turns, and alternating jets run faster or slower.
// Mirrored on the CPU (SceneParams.ringedPlanet), which places the storm.
static float rgDrift(float lat, float T, float wind) {
    return T * wind * (0.0025 + 0.004 * cos(lat * 19.0));
}

static float rgBand(float r, float a, float b, float e) {
    return smoothstep(a - e, a + e, r) * (1.0 - smoothstep(b - e, b + e, r));
}

// How opaque the rings are at radius r (planet radii), with fp the size of a pixel in r, for
// ring settings P (style, width, density). Classic: the faint inner ring, the dense middle ring,
// a near-empty division, the outer ring with a narrow gap, and a thin braided ring outside.
// Broad: one wide, softly banded sheet. Narrow: a handful of thin, dark-gapped ringlets over a
// faint dust sheet, like an ice giant's. Ringlets finer than a pixel are faded out, not aliased.
// The width setting stretches the system outward from its inner edge.
static float rgRingOpacity(float r, float fp, float4 P) {
    int style = int(P.x + 0.5);
    if (style == 3) return 0.0;
    r = 1.24 + (r - 1.24) / P.y;
    fp /= P.y;
    if (r < 1.18 || r > 2.42) return 0.0;
    float e = max(fp * 0.7, 0.004);
    float k1 = 1.0 - smoothstep(0.25, 0.7, fp * 160.0);
    float k2 = 1.0 - smoothstep(0.25, 0.7, fp * 50.0);
    float fine = (noise3(float3(r * 160.0, 1.0, 0.5)) - 0.5) * k1 + (noise3(float3(r * 50.0, 2.0, 0.5)) - 0.5) * 0.9 * k2;
    float broad = noise3(float3(r * 14.0, 3.0, 0.5)) - 0.5;   // wide ringlets, always visible
    float o;
    if (style == 1) {
        o = rgBand(r, 1.3, 2.3, e * 4.0) * saturate(0.25 + 0.4 * smoothstep(1.3, 1.7, r) + 0.45 * broad + 0.25 * fine)
          * (1.0 - smoothstep(2.0, 2.3, r) * 0.5);
    } else if (style == 2) {
        o = rgBand(r, 1.4, 2.28, e * 4.0) * 0.035;            // the dust sheet
        for (int k = 0; k < 6; k++) {
            float rk = 1.55 + 0.13 * float(k) + 0.03 * sin(float(k) * 2.7);
            float wk = max(0.005 + 0.004 * fract(float(k) * 0.618), e);
            o += exp(-pow((r - rk) / wk, 2.0)) * (0.55 + 0.35 * fract(float(k) * 0.37)) * min(1.0, 0.008 / wk);
        }
    } else {
        float c = rgBand(r, 1.24, 1.53, e * 2.0) * (0.14 + 0.08 * fine + 0.08 * broad + 0.08 * smoothstep(1.42, 1.53, r));
        float b = rgBand(r, 1.53, 1.95, e) * saturate(0.55 + 0.3 * smoothstep(1.58, 1.78, r) + 0.4 * fine + 0.5 * broad);
        float d = rgBand(r, 1.95, 2.02, e) * (0.1 + 0.08 * fine);
        float a = rgBand(r, 2.02, 2.27, e * 1.5) * saturate(0.45 + 0.3 * fine + 0.25 * broad - 0.15 * smoothstep(2.12, 2.27, r));
        a *= 0.25 + 0.75 * smoothstep(0.004, 0.01 + e, abs(r - 2.215));
        float w = max(0.006, e);
        float f = exp(-pow((r - 2.33) / w, 2.0)) * 0.3 * (0.006 / w);
        o = c + b + d + a + f;
    }
    return saturate(o * P.z);
}

// The ring material's color across the rings: grayer and cooler inside, warm through the
// dense ring, neutral further out.
static float3 rgRingTint(float3 col, float r) {
    float3 inner = col * float3(0.7, 0.75, 0.85);
    float3 middle = col * float3(1.05, 1.0, 0.9);
    float3 outer = col * float3(0.92, 0.94, 0.98);
    float3 c = r < 1.53 ? mix(inner, middle, smoothstep(1.4, 1.6, r)) : mix(middle, outer, smoothstep(1.9, 2.1, r));
    float v = noise3(float3(r * 30.0, 5.0, 0.5)) - 0.5;          // ringlets of slightly different stuff
    return c * (float3(1.0) + v * float3(0.18, 0.04, -0.16));
}

// Unit point on the planet (the spheroid scaled to a sphere) and its latitude (sine).
static float3 rgUnit(float3 P, float3 n, float R) {
    float h = dot(P, n);
    return normalize((P - n * h) / R + n * (h / (R * RG_FLAT)));
}

// Fraction of sunlight reaching P past a sphere (center M, radius rm), with a soft edge.
static float rgSphereShadow(float3 P, float3 L, float3 M, float rm) {
    if (rm <= 0.0) return 1.0;
    float s = dot(M - P, L);
    if (s <= 0.0) return 1.0;
    float d = length(M - (P + L * s));
    return smoothstep(rm * 0.75, rm * 1.25, d);
}

// The cloud deck at unit point q (latitude q.n): bands sheared by the jets, streaks and
// turbulence along their edges, a bright equatorial zone, darker cooler poles, and the white
// storm when there is one.
// `look` = band scale (how many bands), turbulence, wind.
static float3 rgClouds(float3 q, float3 n, float3 e1, float3 e2, float T, float3 light, float3 dark,
                       float stormHead, float storm, float4 look) {
    float lat = dot(q, n);
    float bs = look.x, turb = look.y;
    float3 qr = rotateAbout(q, n, rgDrift(lat, T, look.z));
    float u1 = dot(qr, e1), u2 = dot(qr, e2);
    float warp = fbm(float3(u1 * 3.0, lat * 16.0 * bs, u2 * 3.0) + 4.0);
    float lt = lat + (warp - 0.5) * 0.05 * turb / bs;
    float fineBands = 0.5 + 0.5 * sin(lt * 38.0 * bs + 1.7 * sin(lt * 11.0 * bs));
    float broad = 0.5 + 0.5 * sin(lt * 9.0 * bs + 1.0);
    float streak = fbm(float3(u1 * 5.0, lt * 70.0 * bs, u2 * 5.0) + 9.0);
    float t = smoothstep(0.12, 0.88, 0.5 * fineBands + 0.3 * broad + 0.4 * turb * (streak - 0.5));
    float3 c = mix(dark, light, t);
    c = mix(c, light * 1.06, smoothstep(0.2, 0.0, abs(lat)) * 0.45);                       // equatorial zone
    c = mix(c, dark * float3(0.55, 0.68, 0.85), smoothstep(0.72, 0.95, abs(lat)) * 0.7);   // poles
    if (storm > 0.0) {
        // a bright head, and a turbulent white tail trailing it round the planet as it grows
        float lon = atan2(u2, u1);
        float dl = lon - stormHead;
        dl -= 6.2831853 * floor(dl / 6.2831853 + 0.5);
        float spread = 0.3 + 5.5 * storm;
        float across = (lat - RG_STORM_LAT) / (0.05 + 0.04 * storm);
        float churn = fbm(float3(u1 * 9.0, lat * 60.0, u2 * 9.0) + float3(0.0, 0.0, T * 0.02));
        float head = exp(-(dl * dl) / 0.05 - across * across);
        float tail = smoothstep(0.05, -0.1, dl) * smoothstep(-spread, -spread * 0.6, dl) * exp(-across * across * 0.7);
        float fade = smoothstep(0.0, 0.03, storm) * (1.0 - smoothstep(0.75, 1.0, storm));
        float white = saturate(head * 1.4 + tail * (0.45 + 1.0 * churn)) * fade;
        c = mix(c, float3(1.0, 0.97, 0.9) * max(max(light.r, light.g), 0.8) * 1.2, white * 0.95);
    }
    return c;
}

fragment float4 ringedFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = F.time;
    float3 n = S.a.xyz;
    float R = S.a.w;
    float3 L = S.b.xyz;
    float sunI = S.b.w;
    float3 sunCol = float3(1.0, 0.97, 0.92) * sunI;
    float3 e1 = normalize(cross(n, F.camRight.xyz)), e2 = cross(n, e1);
    float3 ringCol = S.e.rgb;

    // nearest opaque thing: the planet or a moon
    float tOpaque = 1e9;
    float3 base = SKY(p, rd, false);
    float2 sp = spheroidSpan(ro, rd, n, R, R * RG_FLAT);
    if (sp.x < sp.y && sp.x > 0.0) {
        tOpaque = sp.x;
        float3 P = ro + rd * sp.x;
        float h = dot(P, n);
        float3 N = normalize((P - n * h) / (R * R) + n * (h / (R * R * RG_FLAT * RG_FLAT)));
        float3 q = rgUnit(P, n, R);
        float3 alb = rgClouds(q, n, e1, e2, T, S.c.rgb, S.d.rgb, S.c.w, S.d.w, S.i);
        float nl = dot(N, L);
        float mu = saturate(dot(N, -rd));
        float shade = 1.0;
        // the rings' shadow, carrying their structure
        float ln = dot(L, n);
        if (abs(ln) > 1e-3) {
            float ts = -h / ln;
            if (ts > 0.0) shade *= 1.0 - 0.9 * rgRingOpacity(length(P + L * ts) / R, 0.004, S.j);
        }
        shade *= rgSphereShadow(P, L, S.f.xyz, S.f.w) * rgSphereShadow(P, L, S.g.xyz, S.g.w) * rgSphereShadow(P, L, S.h.xyz, S.h.w);
        float diffuse = saturate((nl + 0.04) / 1.04);
        float limb = 0.6 + 0.4 * pow(mu, 0.5);
        float3 col = alb * sunCol * diffuse * shade * limb;
        // ringshine: the sunlit face of the rings faintly lights the hemisphere facing it
        if (h * ln > 0.0) col += alb * ringCol * 0.045 * sunI * (1.0 - saturate(nl * 3.0 + 0.3)) * (0.4 + 0.6 * abs(dot(N, n)));
        // a thin haze along the limb, lit on the day side
        col += mix(S.c.rgb, float3(0.65, 0.78, 1.0), 0.4) * pow(1.0 - mu, 3.0) * saturate(nl + 0.25) * 0.3 * sunI;
        base = col;
    }
    for (int m = 0; m < 3; m++) {
        float4 M = m == 0 ? S.f : (m == 1 ? S.g : S.h);
        if (M.w <= 0.0) continue;
        float2 s = sphereSpan(ro - M.xyz, rd, M.w);
        if (s.x < s.y && s.x > 0.0 && s.x < tOpaque) {
            tOpaque = s.x;
            float3 P = ro + rd * s.x;
            float3 N = normalize(P - M.xyz);
            float alb = 0.55 + 0.35 * fbm(N * 4.0 + float(m) * 7.0);
            float lit = saturate(dot(N, L));
            // eclipsed when it passes into the planet's shadow
            float2 sh = spheroidSpan(M.xyz, L, n, R, R * RG_FLAT);
            float ecl = sh.x < sh.y && sh.y > 0.0 ? 0.03 : 1.0;
            base = float3(0.9, 0.9, 0.95) * alb * sunCol * lit * ecl * 0.9;
        }
    }

    // the rings, over whatever is behind them
    float3 col = base;
    float dn = dot(rd, n);
    if (abs(dn) > 1e-4) {
        float tr = -dot(ro, n) / dn;
        if (tr > 0.0 && tr < tOpaque) {
            float3 Q = ro + rd * tr;
            float r = length(Q) / R;
            float fp = F.pixelAngle * tr / R / max(abs(dn), 0.08);
            float a = rgRingOpacity(r, fp, S.j);
            if (a > 0.002) {
                float rs = 1.24 + (r - 1.24) / S.j.y;     // radius in the unstretched layout
                // each ring turns as a whole, the inner ones faster
                float period = rs < 1.53 ? 260.0 : (rs < 1.98 ? 420.0 : 700.0);
                float3 qa = rotateAbout(Q / length(Q), n, -T * 6.2831853 / period);
                float clumps = 0.85 + 0.3 * noise3(float3(dot(qa, e1) * 5.0, dot(qa, e2) * 5.0, rs * 55.0));
                // Spokes: thin wisps of dust lifted off the dense ring, pointing out from the planet
                // and turning with its magnetic field. Noise that varies quickly round the ring and
                // hardly at all outward makes them narrow and long; each leans a little as it shears.
                float3 qs = rotateAbout(Q / length(Q), n, -T * 0.012 + (rs - 1.75) * 0.25);
                float az = noise3(float3(dot(qs, e1) * 28.0, dot(qs, e2) * 28.0, T * 0.003 + rs * 0.8));
                float spokes = smoothstep(0.68, 0.88, az) * rgBand(rs, 1.6, 1.92, 0.08) * S.j.w;
                float ln = dot(L, n);
                bool litFace = ln * dot(ro - Q, n) > 0.0;
                float fwd = pow(saturate(dot(rd, L)), 6.0);
                // sunlight on the rings falls off as the sun lowers toward their plane; edge-on they go dark
                float grazing = pow(abs(ln), 0.35);
                float I = litFace ? a * grazing * (1.0 + 0.8 * fwd * (1.0 - a)) * (1.0 - 0.12 * spokes)
                                  : a * (1.0 - a) * (1.0 + 3.5 * fwd) * grazing * (1.0 + 0.6 * spokes * fwd);
                // the planet's shadow across the rings
                float2 sh = spheroidSpan(Q, L, n, R, R * RG_FLAT);
                if (sh.x < sh.y && sh.y > 0.0) I *= 0.02;
                col = rgRingTint(ringCol, rs) * sunCol * I * clumps * 0.85 + base * (1.0 - a);
            }
        }
    }
    return finalize(col, p, F);
}
"""
}
