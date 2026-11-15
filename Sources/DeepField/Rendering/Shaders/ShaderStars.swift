extension ShaderSource {
    static let stars = """
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
    float3 rd = octDecode(dirTex.read(p).xy);
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
        col = SKY(p, rd, false);
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
        float x = max(dperp - R, 0.0);
        if (x > scale * 14.0) continue;            // glow below e^-14
        float ang = atan2(dot(w, F.camUp.xyz), dot(w, F.camRight.xyz));
        float rays = 0.7 + 0.45 * noise3(float3(cos(ang) * 3.0, sin(ang) * 3.0, F.time * 0.08 + st.misc.y));
        float glow = (0.55 * exp(-x / (scale * 0.3)) + 0.12 * exp(-x / scale)) * rays;
        col += st.color.rgb * glow;
    }
    return finalize(col, p, F);
}

// ---------- per-frame: star close-up ----------
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
    float3 col;
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
            if (sd >= size * 3.0) continue;              // beyond the facula: nothing to add
            if (sd >= size) { facula += smoothstep(size * 3.0, size, sd) * 0.25; continue; }
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
        col = SKY(p, octDecode(dirTex.read(p).xy), false) * 0.6;
        float h = (dist - R) / R;
        // Terms that fall off with height are skipped once they are below about e^-12.
        // chromosphere and spicules
        float chromo = exp(-h / 0.006);
        float3 hAlpha = float3(1.0, 0.25, 0.3);
        col += hAlpha * chromo * 1.4;
        if (h < 0.24) {
            float spic = fbm(float3(ang * 260.0, h * 90.0 - F.time * 0.35, 1.0));
            col += hAlpha * smoothstep(0.45, 0.8, spic) * exp(-h / 0.02) * 0.7;
        }
        // corona with streamers (its scale height is at most 0.18)
        if (h < 2.2) {
            float stream = fbm(float3(cos(ang) * 5.0, sin(ang) * 5.0, F.time * 0.004));
            col += mix(starCol, float3(1.0), 0.5) * exp(-h / (0.06 + 0.12 * stream)) * (0.05 + 0.12 * stream);
        }
        // coronal loops: arches rooted on the limb, with plasma streaming along them
        // (loops are at most 0.16 high and their tubes ~0.004 thick, so nothing reaches h = 0.2)
        for (int i = 0; i < 5 && h < 0.2; i++) {
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
        if (h < 0.84) {
            float prom = smoothstep(0.58, 0.82, fbm(float3(ang * 7.0, h * 14.0 - F.time * 0.01, 4.0)));
            if (prom > 0.0) prom *= exp(-h / 0.07) * smoothstep(0.5, 0.7, fbm(float3(ang * 2.0, 1.0, 7.0)));
            col += hAlpha * prom * 1.1;
        }
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
}
