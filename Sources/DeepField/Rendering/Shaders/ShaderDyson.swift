extension ShaderSource {
    static let dyson = """
// ---------- per-frame: dyson swarm ----------
// A star partly enclosed by light-collecting panels on many inclined rings. Each ring is a band
// of panels on its own sphere around the star (no two share a radius, or they'd collide where
// they cross), orbiting at Kepler speed, so inner rings overtake outer ones. Panels face the
// star: from the near side we see their dark backs against it, faintly warm with waste heat; on
// the far side their lit faces show, and they glint when a panel's slow wobble lines its mirror
// up with us. Thin dust around the star scatters the light that escapes between the bands into
// beams. The scene has its own frame: the camera at the origin looking down +z, x right, y up.
//
// S.a = star center, radius
// S.b = star color, surface brightness
// S.c = ring count, density (0..1), glint strength, orbit phase of the innermost ring (radians)
// S.d = panel color A, seed
// S.e = panel color B, innermost ring radius
// S.f = waste heat color, outermost ring radius
// S.g = event: ring index, age (s), sweep length (s), 1 = active

constant int DS_MAX_RINGS = 20;
constant float DS_PANEL = 0.085;        // panel pitch, in star radii
constant float DS_FILL = 0.82;          // panel width as a fraction of its pitch; the rest is gap

struct DSRing { float3 n; float3 a1; float3 a2; float r; float phase; float hue; float hw; };

static DSRing dsRing(int k, float count, constant SceneParams& S) {
    DSRing g;
    float seed = S.d.w, fk = float(k);
    // radii spread evenly with a little jitter between the innermost and outermost
    float x = (fk + 0.5 + 0.5 * (hash13(float3(fk, seed, 1.7)) - 0.5)) / count;
    g.r = mix(S.e.w, S.f.w, x);
    // inclinations: a golden-ratio sequence over the sphere, so the rings cross at all angles
    float z = 2.0 * fract(fk * 0.618034 + seed * 0.37) - 1.0;
    float az = fk * 2.39996 + seed * 5.1;
    float s = sqrt(max(1.0 - z * z, 0.0));
    g.n = float3(s * cos(az), s * sin(az), z);
    g.phase = S.c.w * (S.e.w / g.r) * sqrt(S.e.w / g.r);         // Kepler: angular speed ~ r^-1.5
    g.hw = mix(0.05, 0.24, S.c.y) * (0.75 + 0.5 * hash13(float3(fk, seed, 7.9)));   // band half width (radians)
    return g;
}

// The rest of a ring's frame, worked out only where a ray actually meets its band.
static void dsFrame(thread DSRing& g, int k, constant SceneParams& S) {
    g.a1 = normalize(cross(g.n, abs(g.n.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
    g.a2 = cross(g.n, g.a1);
    g.hue = hash13(float3(float(k), S.d.w, 4.2));
}

// Chance that a panel sits at (lon, lat) in the ring's turning frame. The band thins out toward
// its edges, and stretches are still unbuilt; both fill in as the swarm gets denser.
static float dsPresence(DSRing g, int k, float lon, float lat, float density) {
    float band = 1.0 - smoothstep(0.35 * g.hw, g.hw, abs(lat));
    if (band <= 0.0) return 0.0;
    // a few waves round the ring (whole numbers of them, so it closes on itself), cheaper than noise
    float fk = float(k);
    float cl = 0.5 + 0.22 * sin(3.0 * lon + fk * 1.7 + 1.3 * sin(2.0 * lon + fk))
                   + 0.16 * sin(7.0 * lon - fk * 2.3 + lat * 14.0) + 0.12 * sin(lat * 23.0 + 5.0 * lon + fk * 4.1);
    float a = mix(0.56, 0.12, density);
    return band * smoothstep(a - 0.1, a + 0.1, cl);
}

// Fraction of starlight a ring blocks in unit direction u from the star (panels and gaps averaged).
static float dsBlock(DSRing g, int k, float3 u, float density, constant SceneParams& S) {
    float z = dot(u, g.n);
    if (abs(z) > g.hw) return 0.0;
    dsFrame(g, k, S);
    float lon = atan2(dot(u, g.a2), dot(u, g.a1)) - g.phase;
    return dsPresence(g, k, lon, asin(z), density) * DS_FILL * DS_FILL;
}

// A ring's panels where the view ray crosses its sphere at t: color, and coverage in w.
static float4 dsPanels(DSRing g, int k, float3 rd, float t, constant SceneParams& S, constant FrameParams& F) {
    float3 C = S.a.xyz;
    float3 u = (rd * t - C) / g.r;
    float z = dot(u, g.n);
    if (abs(z) > g.hw) return float4(0.0);
    dsFrame(g, k, S);
    float lat = asin(z);
    float lon = atan2(dot(u, g.a2), dot(u, g.a1)) - g.phase;
    float count = max(floor(6.2832 * g.r / DS_PANEL), 8.0);
    float cx = lon / 6.2832 * count, cy = lat * g.r / DS_PANEL;
    float ix = floor(cx), iy = floor(cy);
    float2 f = float2(cx - ix, cy - iy) - 0.5;
    ix -= count * floor(ix / count);                    // the same panel either side of the seam
    float3 cell = float3(ix, iy, float(k) * 17.0 + S.d.w);
    float pres = dsPresence(g, k, (ix + 0.5) / count * 6.2832, (iy + 0.5) * DS_PANEL / g.r, S.c.y);
    float hp = hash13(cell);
    float fp = F.pixelAngle * t / DS_PANEL / max(abs(dot(u, rd)), 0.25);
    float e = 0.5 * fp + 0.04, hf = 0.5 * DS_FILL;
    float m = smoothstep(hf + e, hf - e, abs(f.x)) * smoothstep(hf + e, hf - e, abs(f.y));
    float cov = (hash13(cell + 3.1) < pres ? 1.0 : 0.0) * m;
    cov = mix(cov, pres * DS_FILL * DS_FILL, smoothstep(0.7, 1.8, fp));   // too small to resolve: average
    if (cov <= 0.0) return float4(0.0);

    // each panel faces the star, wobbling slowly as its attitude control hunts
    float3 elon = normalize(cross(g.n, u)), elat = cross(u, elon);
    float T = F.time;
    float w1 = sin(T * (0.12 + 0.2 * hp) + hp * 40.0), w2 = sin(T * (0.09 + 0.17 * fract(hp * 7.3)) + hp * 91.0);
    float3 L = -u, V = -rd;
    float3 nrm = normalize(L + 0.2 * (w1 * elon + w2 * elat));

    // the event: a wave runs along the ring and each panel in turn swings to mirror the star at us
    float turn = 0.0;
    if (S.g.w > 0.0 && float(k) > S.g.x - 0.5 && float(k) < S.g.x + 2.5) {   // three neighboring rings
        float lon0 = lon + g.phase;                     // in the ring's fixed frame
        float far = atan2(g.a2.z, g.a1.z);              // the ring's point farthest from us
        float dl = lon0 - far;
        dl -= 6.2832 * floor(dl / 6.2832 + 0.5);
        float lag = float(k) - S.g.x;
        float tt = S.g.y - (dl / 3.2 + 0.5) * S.g.z - lag * 2.5 - hp * 0.8;
        turn = smoothstep(0.0, 1.6, tt) * (1.0 - smoothstep(5.5, 9.0, tt));
        turn *= 1.0 - smoothstep(1.2, 1.55, abs(dl));    // a section of the ring, not all of it
        if (dot(L, V) > -0.92) nrm = normalize(mix(nrm, normalize(L + V), turn));
    }

    float E = S.b.w / sq(g.r);                          // irradiance: falls as 1/r^2 from the surface
    float nl = dot(nrm, L), nv = dot(nrm, V);
    float3 face = mix(S.d.rgb, S.e.rgb, saturate(g.hue * 1.4 - 0.2 + 0.25 * sin(lon * 2.0 + g.hue * 9.0)));
    float3 col;
    if (nv > 0.0 && nl > 0.0) {
        // lit face: a little diffuse light, and a mirror image of the star when lined up. The star
        // fills an angle asin(R/r) seen from the panel; the panels aren't perfectly flat, so the
        // image is softened over a slightly narrower window.
        float gl = dot(reflect(-L, nrm), V);
        float alpha = asin(min(S.a.w / g.r, 1.0));
        float mirror = smoothstep(cos(alpha * 0.22), cos(alpha * 0.05), gl);
        float sheen = pow(saturate(gl), 24.0);
        col = face * E * nl * 0.22 * (0.4 + 0.6 * nv);
        col += mix(S.b.rgb, face, 0.35) * S.c.z * (mirror * S.b.w * 0.55 + sheen * E * 0.12);
        col += mix(S.b.rgb, face, 0.25) * turn * mirror * S.b.w * 0.6;   // the event's flashes, full strength
    } else {
        // the back: dark, glowing faintly with the waste heat it radiates
        col = S.f.rgb * 0.05 * sq(S.e.w / g.r) * (0.6 + 0.8 * hp) + face * 0.002;
        if (nv > 0.0) col += face * E * 0.05 * nv;      // the lit face's edge, caught side on
    }
    return float4(col, cov);
}

fragment float4 dysonFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rdw = octDecode(dirTex.read(p).xy);
    float3 right = F.camRight.xyz, up = F.camUp.xyz, fwd = cross(right, up);
    float3 rd = float3(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    float3 C = S.a.xyz;
    float R = S.a.w;
    float3 star = pow(S.b.rgb, float3(1.4));         // a little deeper than the blackbody, for color
    float I = S.b.w, density = S.c.y;
    int N = min(int(S.c.x), DS_MAX_RINGS);

    float3 col = SKY(p, rdw, false);
    float2 ss = sphereSpan(-C, rd, R);
    bool hitStar = ss.x < ss.y && ss.x > 0.0;
    float tc = dot(C, rd);
    float b = length(rd * tc - C);                     // closest approach to the star's center

    if (hitStar) {
        float3 N3 = normalize(rd * ss.x - C);
        float mu = saturate(dot(N3, -rd));
        float gran = fbm(N3 * 11.0 + float3(0.0, 0.0, F.time * 0.05) + S.d.w);
        float limb = 0.3 + 0.7 * pow(mu, 0.55);
        // limb darkening is stronger in the blue, so the edge runs redder
        float3 tint = mix(star * float3(1.0, 0.55, 0.35), star, smoothstep(0.0, 0.7, mu));
        col = tint * I * 0.38 * limb * (0.8 + 0.4 * gran);   // dimmer than the light it sheds, so the disk keeps its color
    }

    // Dust lit by the light escaping between the bands. Along the view ray, at angle th from the
    // point of closest approach, the dust (density ~ 1/d) lit by the star (~ 1/d^2) gives
    // cos(th) dth / b^2, dimmed by every ring the light crossed on its way out. The samples are
    // set up here and dimmed ring by ring in the loop below, so each ring is built only once.
    const int NS = 4;
    float3 su[NS];
    float sd[NS], tr[NS];
    float jit = bayer4(p), tStar = hitStar ? ss.x : 1e9;
    for (int i = 0; i < NS; i++) {
        float th = -1.35 + 2.7 * (float(i) + jit) / float(NS);
        float tq = tc + b * tan(th);
        float3 q = rd * tq - C;
        sd[i] = length(q);
        su[i] = q / max(sd[i], 1e-4);
        // samples behind the star, behind us, or inside it give nothing
        tr[i] = (tq > tStar || tq < 0.0 || sd[i] < R || tc <= 0.0) ? 0.0 : cos(th);
    }

    // far half of each ring (behind the star's plane, lit faces toward us), outermost first
    for (int k = N - 1; k >= 0; k--) {
        DSRing g = dsRing(k, float(N), S);
        for (int i = 0; i < NS; i++) {
            if (tr[i] > 0.0 && g.r < sd[i]) tr[i] *= 1.0 - dsBlock(g, k, su[i], density, S);
        }
        if (hitStar) continue;
        float2 s = sphereSpan(-C, rd, g.r);
        if (s.x >= s.y) continue;
        float4 pc = dsPanels(g, k, rd, s.y, S, F);
        col = mix(col, pc.rgb, pc.w);
    }

    // corona hugging the limb
    float x = max(b - R, 0.0);
    if (tc > 0.0) {
        float ang = atan2(dot(rd * tc - C, float3(0.0, 1.0, 0.0)), dot(rd * tc - C, float3(1.0, 0.0, 0.0)));
        float rays = 0.75 + 0.4 * noise3(float3(cos(ang) * 4.0, sin(ang) * 4.0, F.time * 0.06 + S.d.w));
        col += star * I * (0.22 * exp(-x / (0.08 * R)) + 0.07 * exp(-x / (0.45 * R))) * rays;

        float glow = 0.0;
        for (int i = 0; i < NS; i++) glow += tr[i];
        glow *= 2.7 / float(NS);
        float bb = max(b, R);
        // the dust thins out slowly past the swarm, so the beams reach well beyond it
        float fall = exp(-max(bb - R, 0.0) / (1.0 * S.f.w)) / (pow(bb / R, 1.3) + 0.6);
        // the leaking light flickers a little as panels sweep across the gaps
        float flick = 0.9 + 0.1 * noise3(float3(F.time * 0.6, b * 2.0, 3.0));
        // deeper in hue than the star, and redder farther out
        float3 deep = star * star;
        float3 dustCol = mix(deep, deep * float3(1.0, 0.5, 0.35), smoothstep(R, 1.5 * S.f.w, bb));
        col += dustCol * I * 0.13 * glow * fall * flick;
    }

    // near half of each ring (between us and the star): dark backs, innermost first
    for (int k = 0; k < N; k++) {
        DSRing g = dsRing(k, float(N), S);
        float2 s = sphereSpan(-C, rd, g.r);
        if (s.x >= s.y || s.x <= 0.0) continue;
        float4 pc = dsPanels(g, k, rd, s.x, S, F);
        col = mix(col, pc.rgb, pc.w);
    }
    return finalize(col, p, F);
}
"""
}
