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
// Screen space, units of half the screen height. S.a = disk center xy, radius, rotation;
// S.b = star color, spot amount; S.c = flare angle, depth inside the limb (R), brightness, size (R);
// S.f = flare progress, surge angle, surge progress, surge brightness;
// S.d = coronal mass ejection angle, progress, brightness, seed;
// S.e = eruptive prominence angle, progress, brightness, seed;
// S.g = middle and half span of the stretch of limb that's on screen (radians).
// Progress runs 0..1 over an event's life; a brightness of 0 means it isn't running.
// Below, lengths are in stellar radii (R) and `px` is one pixel in R, so fine structure can fade
// to its average before it gets smaller than a pixel and shimmers. Sizes follow the Sun:
// granules ~0.002 R, network cells ~0.04 R, big spots ~0.03 R across, spicules ~0.01 R tall,
// prominences 0.02-0.1 R tall, active-region loops 0.02-0.1 R.

static float wrapPi(float a) { return a - 6.2831853 * floor(a / 6.2831853 + 0.5); }

static float2 noise2(float3 p) {
    return float2(noise3(p), noise3(p + float3(31.4, 17.7, 5.3))) - 0.5;
}

// The spin axis is tipped 20 degrees from the screen's x axis, so the equator and the
// active-region belts cross the upper limb. View space -> the star's rotating frame.
constant float kTiltC = 0.9396926, kTiltS = 0.3420201;
static float3 toStar(float3 N, float rot) {
    float3 a = float3(kTiltC * N.x - kTiltS * N.y, kTiltS * N.x + kTiltC * N.y, N.z);
    float c = cos(rot), s = sin(rot);
    return float3(a.x, c * a.y - s * a.z, s * a.y + c * a.z);
}

// Fine parallel threads `spacing` apart across c, varying along v (noise units). Averages
// about 1; threads that would be thinner than a couple of pixels fade toward that average.
static float threads(float c, float v, float spacing, float px, float seed) {
    float sp = max(spacing, 2.5 * px);
    float t = smoothstep(0.38, 0.66, noise3(float3(c / sp, v, seed))) * 2.0;
    return mix(1.0, t, spacing / sp);
}

// Granulation: convection cells ~0.003 R with dark lanes, slowly boiling. Only resolved when zoomed in.
static float granulation(float3 P, float T, float fw) {
    float k = 1.0 - smoothstep(0.15, 0.45, fw * 300.0);
    if (k <= 0.0) return 0.0;
    float3 g = P * 300.0 + float3(0.31, 0.53, 0.79) * T * 0.04;
    float lane = smoothstep(0.0, 0.12, abs(noise3(g) - 0.5));   // lanes where the noise crosses 0.5
    return k * ((lane - 0.8) * 0.4 + (noise3(g * 2.1 + 7.0) - 0.5) * 0.12);
}

static float3 hash33(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

// Chromospheric network: beaded, broken bright borders around supergranules ~0.04 R across
// (cellular noise in 3D, so it wraps the sphere without a seam).
static float network(float3 P, float T, float fw) {
    float3 x = P * 26.0 + float3(noise2(P * 7.0 + 3.0), noise3(P * 7.0 + 9.0) - 0.5) * 1.4;
    float3 i = floor(x), f = fract(x);
    float f1 = 8.0, f2 = 8.0;
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int xk = -1; xk <= 1; xk++) {
        float3 g = float3(xk, y, z);
        float3 o = g + hash33(i + g) - f;
        float dd = dot(o, o);
        if (dd < f1) { f2 = f1; f1 = dd; } else if (dd < f2) { f2 = dd; }
    }
    float edge = sqrt(f2) - sqrt(f1);          // 0 on a cell border
    float width = 0.25;
    float we = max(width, fw * 26.0 * 1.5);
    float line = exp(-edge / we) * (width / we);
    // the borders are strings of bright mottles with gaps, not continuous walls
    float beads = smoothstep(0.35, 0.75, noise3(x * 2.5 + float3(0.0, 0.0, T * 0.01)));
    float kb = 1.0 - smoothstep(0.5, 1.0, fw * 65.0);
    return line * mix(0.8, 0.4 + 0.8 * beads, kb);
}

struct ActiveRegion { float3 D, e1, e2; float vis, size, spots; };

// Active regions live in the rotating frame, a few at a time, in belts up to ~35 degrees from the equator.
static ActiveRegion activeRegion(int i, float T, float spotAmt) {
    float fi = float(i);
    float life = 700.0 + 500.0 * hash13(float3(fi, 1.0, 3.0));
    float cyc = T / life + hash13(float3(fi, 2.0, 3.0));
    float gen = floor(cyc), age = fract(cyc);
    ActiveRegion r;
    r.vis = smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.75, 1.0, age));
    float lat = (0.08 + 0.5 * hash13(float3(fi, gen, 5.0))) * (hash13(float3(fi, gen, 6.0)) < 0.5 ? -1.0 : 1.0);
    float lon = 6.2831853 * hash13(float3(fi, gen, 7.0));
    float cl = cos(lat), sl = sin(lat), co = cos(lon), so = sin(lon);
    r.D = float3(sl, cl * co, cl * so);
    r.e1 = float3(0.0, -so, co);              // along the rotation
    r.e2 = float3(cl, -sl * co, -sl * so);    // toward the pole
    r.size = 0.05 + 0.05 * hash13(float3(fi, gen, 8.0));
    // spots form after the plage brightens and decay before it fades
    r.spots = step(hash13(float3(fi, gen, 4.0)), spotAmt * 1.6) * smoothstep(0.05, 0.25, age) * (1.0 - smoothstep(0.55, 0.85, age));
    return r;
}

// A sunspot of penumbral radius r centered at l (R): umbra 40% of the way out, penumbra combed
// into radial filaments, a ragged edge. Returns the brightness factor.
static float sunspot(float2 l, float r, float seed, float fw) {
    float d = length(l);
    if (r <= 0.0 || d > r * 1.2 + fw) return 1.0;
    float2 u = l / max(d, 1e-6);
    float edge = r * (1.0 + 0.3 * (noise3(float3(u * 1.7, seed)) - 0.5));
    float rs = d / edge;
    float soft = 0.05 + fw / edge;
    float pen = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, rs);
    float umb = 1.0 - smoothstep(0.42 - soft, 0.42 + soft, rs);
    float nf = max(floor(6.2831853 * edge / 0.0018), 6.0);   // a whole number of filaments, so no seam
    float fil = 0.5 + 0.5 * sin(atan2(l.y, l.x) * nf + 2.5 * noise3(float3(l / edge * 3.0, seed + 3.0)));
    float k = saturate(0.0012 / fw - 0.5);
    float penB = 0.66 + 0.34 * (fil - 0.5) * k + 0.1 * (rs - 0.7);
    float v = mix(1.0, mix(penB, 0.2, umb), pen);
    return mix(1.0, v, saturate(r * r / (fw * fw)));   // spots under a pixel fade to a light smudge
}

// A quiescent prominence: a fuzzy, semi-transparent sheet of cool plasma combed into fine
// threads, either a hedgerow of near-vertical threads (arch 0) or an arch of field-aligned ones
// (arch 1) standing on thin feet, with slow downflows and bubbles. L = (along the limb, height).
static float prominence(float2 L, float Lp, float Hp, float arch, float seed, float T, float px) {
    float sn = L.x / Lp;
    float body = sqrt(saturate(1.0 - sn * sn));
    float top = Hp * body * (0.35 + 0.6 * noise3(float3(sn * 2.5, seed, T * 0.004)) + 0.4 * noise3(float3(sn * 14.0, seed, T * 0.01)));
    float feet = smoothstep(0.55, 0.7, noise3(float3(sn * 4.0, seed + 4.0, 0.0)));
    float bottom = arch * Hp * 0.45 * body * (1.0 - feet);
    float soft = 0.3 * Hp + 2.0 * px;
    float mask = smoothstep(top + soft * 0.5, top - soft * 0.5, L.y) * smoothstep(bottom - soft * 0.3, bottom + soft * 0.3, L.y);
    if (mask <= 0.0) return 0.0;
    float e = length(float2(sn, L.y / Hp));
    float c = mix(L.x + 0.35 * L.y * (noise3(float3(sn * 1.5, seed, 1.0)) - 0.5), e * Lp, arch);
    float v = mix(L.y, atan2(L.y / Hp, sn) * Hp, arch);
    float thr = threads(c, v / 0.03 + T * 0.04, 0.004, px, seed);
    thr *= threads(c + 0.37 * Hp, v / 0.05 + T * 0.03, 0.009, px, seed + 3.0);
    float bubbles = smoothstep(0.2, 0.7, fbm(float3(L / Hp * float2(1.2, 2.0), seed + T * 0.003)));
    return mask * thr * (0.25 + 0.75 * bubbles);
}

// An active-region loop system seen side on (as in 171): a fan of n thin, separate strands,
// each with its own footpoints (spread over about +-W), apex height (up to Hh), sideways shear
// and slight kinks, brightest along the legs and near the top and patchy along its length
// (blobs draining down), some of them faint, over a diffuse glow. Returns emission.
static float loopFamily(float2 L, float W, float Hh, int n, float fanChance, float seed, float T, float px) {
    if (L.y < 0.0 || abs(L.x) > W * 1.7 + Hh * 0.5 || L.y > Hh * 1.15) return 0.0;
    float em = 0.0;
    // the strands leave one compact cluster of footpoints (one magnetic polarity) and land either
    // in a second cluster (a bipolar arcade) or spread out along the limb (a fan)
    float fan = step(hash13(float3(seed, 3.0, 17.0)), fanChance);
    float side = hash13(float3(seed, 4.0, 17.0)) < 0.5 ? -1.0 : 1.0;
    for (int k = 0; k < n; k++) {
        float fk = float(k);
        float3 hk = hash33(float3(seed * 7.3 + fk * 1.91, fk * 3.7 + 1.3, seed + 11.0));
        float h2 = hash13(float3(seed, fk, 19.0));
        float xa = -0.85 + 0.25 * (hk.x - 0.5);
        float xb = mix(0.85 + 0.45 * (hk.y - 0.5), -0.55 + 1.6 * hk.y, fan);
        xb = max(xb, xa + 0.25);
        float w = W * 0.5 * (xb - xa);                              // half the footpoint separation
        float c = side * W * 0.5 * (xa + xb);                       // footpoint midpoint
        // tall or squat, never a family of round arcs
        float hh = min(Hh * (0.4 + 0.6 * hk.z) * (0.7 + 0.3 * w / W), w * (0.9 + 2.0 * fract(h2 * 7.13)));
        float sh = (h2 - 0.5) * 1.1;                                // shear: the apex leans sideways
        float x = L.x - c - sh * L.y;
        x += 0.06 * w * sin(L.y / hh * (4.0 + 3.0 * hk.x) + fk * 2.3 + seed);   // kinks
        // an inverted U with steep legs: |x/w|^3 + (y/h)^2 = 1
        float ax = abs(x) / w, ay = L.y / hh;
        float f = ax * ax * ax + ay * ay;
        float2 g = float2(3.0 * ax * ax / w, 2.0 * ay / hh);
        float dist = (f - 1.0) / max(length(g), 1e-4);             // distance to the strand, in R
        float wl = (0.0006 + 0.0007 * hk.z) * (0.6 + 0.8 * h2);
        float we = max(wl, 1.2 * px);
        if (abs(dist) > we * 3.0) continue;
        float leg = 1.0 - saturate(ay);                              // 0 at the top, 1 at the feet
        float along = noise3(float3(leg * 7.0 - T * 0.04, fk * 1.7 + sign(x) * 5.0, seed + 2.0));
        float shape = 0.45 + 0.6 * smoothstep(0.3, 0.9, leg) + 0.35 * smoothstep(0.25, 0.0, leg);
        float amp = h2 < 0.3 ? 0.3 : 0.7 + 0.6 * hk.x;             // a few faint ones
        em += exp(-dist * dist / (we * we)) * (wl / we) * amp * shape * (0.15 + 1.8 * along * along);
    }
    float2 en = float2(L.x / (W * 1.2), L.y / Hh);
    float haze = exp(-dot(en, en) * 2.5) * 0.1;
    return (em * 1.4 + haze) * exp(-L.y / (0.8 * Hh + 0.02)) * smoothstep(0.0, 0.004, L.y);
}

fragment float4 stellarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 col;
    float W = F.camRight.w, H = F.camUp.w;
    float T = F.time;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    q *= F.screenScale;
    float2 C = S.a.xy;
    float R = S.a.z;
    float px = 2.0 * F.screenScale / (H * R);
    float2 d = (q - C) / R;            // R units from here on
    float r = length(d);
    float ang = atan2(d.y, d.x);
    float h = r - 1.0;                 // height above the limb
    float3 starCol = S.b.rgb;
    float spotAmt = S.b.w;
    // a deep, saturated surface color, like a filtered solar image, and the cool chromospheric red
    float3 surf = max(mix(float3(dot(starCol, float3(0.2126, 0.7152, 0.0722))), starCol, 10.0), 0.0);
    surf = pow(surf / max(max(surf.r, surf.g), max(surf.b, 1e-3)), float3(2.0));
    float3 chrom = mix(float3(1.0, 0.28, 0.2), surf, 0.4);
    float3 hot = mix(surf, float3(1.0), 0.45);
    float offDisk = smoothstep(1.0 - px * 0.7, 1.0 + px * 0.7, r);

    if (r < 1.0) {
        float3 N = float3(d, sqrt(max(1.0 - r * r, 0.0)));
        float mu = N.z, om = 1.0 - mu;
        float3 P = toStar(N, S.a.w);
        float fw = px / max(mu, 0.08);   // pixel footprint on the surface, stretched toward the limb
        float gran = granulation(P, T, fw);
        float net = network(P, T, fw);
        float big = fbm(float3(P * 3.2 + 5.0)) + 0.6 * (noise3(P * 12.0 + 1.0) - 0.5);   // patches: quiet, enhanced, coronal-hole-dim
        float mid = (noise3(P * 70.0 + 2.0) - 0.5) * (1.0 - smoothstep(0.2, 0.5, fw * 70.0));
        float spot = 1.0, plage = 0.0, core = 0.0, glow = 0.0;
        for (int i = 0; i < 12; i++) {
            ActiveRegion ar = activeRegion(i, T, spotAmt);
            float3 dv = P - ar.D;
            if (ar.vis <= 0.0 || dot(dv, dv) > ar.size * ar.size * 6.0) continue;
            float2 l = float2(dot(dv, ar.e1), dot(dv, ar.e2));
            // compact plage threaded with bright network and mottles, a soft glow around it,
            // and a small white-hot core where the loops are densest
            float2 le = l / (ar.size * float2(0.8, 0.5));
            float pl = exp(-dot(le, le) * 1.5);
            plage += pl * ar.vis * (0.5 + 1.6 * net + 1.2 * max(mid, 0.0));
            glow += exp(-dot(le, le) * 0.35) * ar.vis;
            float2 lc = l / (ar.size * float2(0.36, 0.22));
            core += exp(-dot(lc, lc)) * ar.vis * (0.3 + 1.2 * net + 1.5 * max(mid, 0.0));
            if (ar.spots > 0.0) {
                float seed = float(i) * 7.1 + ar.size * 100.0;
                float rl = ar.size * (0.2 + 0.12 * fract(seed * 3.7)) * ar.spots;   // leader penumbra radius
                spot *= sunspot(l - ar.size * float2(0.32, 0.04), rl, seed, fw);
                spot *= sunspot(l + ar.size * float2(0.3, 0.07), rl * (0.5 + 0.3 * fract(seed * 5.3)), seed + 1.0, fw);
                for (int k = 0; k < 3; k++) {   // pores and small spots strung between
                    float fk = float(k);
                    float2 pc = ar.size * float2(0.45 * fk - 0.4 + 0.1 * fract(seed * (fk + 2.1)), 0.15 * (fract(seed * (fk + 5.3)) - 0.5));
                    spot *= sunspot(l - pc, ar.size * (0.05 + 0.05 * fract(seed * (fk + 7.9))) * ar.spots, seed + fk + 2.0, fw);
                }
            }
        }
        // filaments: long, dark, sinuous threads of prominence plasma seen against the disk
        float fil = 0.0;
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float life = 900.0 + 400.0 * hash13(float3(fi, 21.0, 1.0));
            float cyc = T / life + hash13(float3(fi, 22.0, 1.0));
            float gen = floor(cyc), age = fract(cyc);
            float lat = (0.2 + 0.7 * hash13(float3(fi, gen, 23.0))) * (hash13(float3(fi, gen, 24.0)) < 0.5 ? -1.0 : 1.0);
            float lon = 6.2831853 * hash13(float3(fi, gen, 25.0));
            float cl = cos(lat), sl = sin(lat), co = cos(lon), so = sin(lon);
            float3 D = float3(sl, cl * co, cl * so);
            float3 dv = P - D;
            float Lf = 0.08 + 0.12 * hash13(float3(fi, gen, 26.0));
            if (dot(dv, dv) > Lf * Lf * 1.5) continue;
            float tw = (hash13(float3(fi, gen, 27.0)) - 0.5) * 1.2;   // angle to the east-west line
            float2 l = float2(dot(dv, float3(0.0, -so, co)), dot(dv, float3(cl, -sl * co, -sl * so)));
            l = float2(cos(tw) * l.x + sin(tw) * l.y, -sin(tw) * l.x + cos(tw) * l.y);
            float al = l.x / Lf;
            float y = l.y - Lf * 0.15 * sin(al * 2.5 + fi * 3.0) - Lf * 0.08 * (noise3(float3(al * 5.0, fi, gen)) - 0.5);
            float w = 0.003 + 0.003 * hash13(float3(fi, gen, 28.0));
            float we = max(w, fw * 1.2);
            fil = max(fil, exp(-y * y / (we * we)) * (w / we) * smoothstep(1.0, 0.6, abs(al))
                      * (0.5 + 0.6 * noise3(float3(al * 14.0, y / w, fi + gen))) * smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.8, 1.0, age)));
        }
        // limb darkening, stronger toward the blue, so the edge reddens
        float3 ld = max(1.0 - float3(0.32, 0.46, 0.6) * om - 0.12 * om * om, 0.05);
        // high contrast, as in filtered full-disk images: dim cell interiors, darker still in the
        // quiet, coronal-hole-like patches, against bright, beaded network borders
        float enh = smoothstep(0.25, 0.8, big);
        float b = (1.0 + gran) * (0.07 + 0.3 * enh + 0.06 * mid + net * (0.55 + 1.5 * enh))
                * spot * (1.0 - 0.7 * fil);
        b += plage * (4.0 + 1.0 * om);
        col = surf * ld * b * 0.6 + hot * glow * 0.3 + mix(hot, float3(1.0), 0.6) * core * 2.5;
        // the chromosphere seen edge-on brightens the last sliver inside the limb
        col += chrom * 0.3 * exp(-(1.0 - r) / 0.004);
    } else {
        col = SKY(p, octDecode(dirTex.read(p).xy), false) * 0.6;
        float2 u = d / r;
        // spicule forest: a ragged fringe of thin jets about 0.01 R tall, sampled around a circle
        // (no seam), leaning a little this way and that
        if (h < 0.05) {
            float sp = max(0.0035, 2.0 * px);
            float jets = 0.0;
            for (int k = 0; k < 2; k++) {   // two overlapping layers, leaning differently
                float fk = float(k);
                float as = ang + (0.9 * (noise3(float3(u * 8.0, 2.0 + fk * 5.0)) - 0.5) + 0.3 * (fk - 0.5)) * h;
                float2 cs = float2(cos(as), sin(as)) / (sp * (1.0 + 0.4 * fk));
                float top = 0.005 + 0.011 * noise3(float3(cs * 0.5, T * 0.03 + fk * 7.0));
                jets += smoothstep(top, top * 0.2, h) * smoothstep(0.25, 0.8, noise3(float3(cs, h / 0.015 - T * 0.05 + fk * 3.0)));
            }
            float fringe = mix(0.5 * smoothstep(0.012, 0.002, h), jets * 0.75, 0.0035 / sp);
            col += chrom * (fringe * 0.8 + exp(-h / 0.002) * 0.5);
        }
        // glow of the transition region, the inner corona and scattered light hugging the limb.
        // Besides falling with height it fades over a fixed share of the screen, so zoomed in it
        // stays a soft halo along the limb and the sky beyond keeps its own dark color.
        float hs = h * R / F.screenScale;   // height in half screen heights
        float fade = exp(-hs * hs / 0.035);
        if (fade > 0.002) {
            // lumpy, with helmet streamers that narrow into faint radial rays
            float st = fbm(float3(u * 1.6, 7.0 + T * 0.0015));
            float stream = smoothstep(0.45 + 0.1 * saturate(h - 0.3), 0.75, st);
            float rays = 0.8 + 0.4 * noise3(float3(u * 45.0, h * 1.5));
            float rr = 1.0 + h;
            col += chrom * (0.16 * exp(-h / 0.02) + 0.2 * exp(-h / 0.1) * (0.6 + 0.8 * stream)) * fade;
            col += mix(surf, hot, 0.5) * (0.07 * pow(rr, -8.0) + 0.07 * stream * pow(rr, -3.0) * rays) * fade;
        }
        // quiescent prominences and active-region loop systems, placed along the visible limb;
        // they stand for days, so they only come and go slowly
        float arcMid = S.g.x, arcHalf = S.g.y;
        float prom = 0.0, loops = 0.0;
        for (int i = 0; i < 3 && h < 0.2; i++) {
            float fi = float(i);
            float life = 500.0 + 300.0 * hash13(float3(fi, 11.0, 1.0));
            float cyc = T / life + hash13(float3(fi, 12.0, 1.0));
            float gen = floor(cyc), age = fract(cyc);
            float a0 = arcMid + arcHalf * 0.9 * (2.0 * hash13(float3(fi, gen, 13.0)) - 1.0);
            float Lp = 0.04 + 0.08 * hash13(float3(fi, gen, 14.0));
            float Hp = 0.025 + 0.055 * hash13(float3(fi, gen, 15.0));
            float s = wrapPi(ang - a0);
            if (abs(s) > Lp * 1.3 || h > Hp * 1.6) continue;
            float vis = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.75, 1.0, age));
            prom += prominence(float2(s, h), Lp, Hp, hash13(float3(fi, gen, 16.0)), fi * 5.3 + gen * 1.7, T, px) * vis;
        }
        for (int i = 0; i < 3 && h < 0.2; i++) {
            float fi = float(i);
            float life = 400.0 + 300.0 * hash13(float3(fi, 31.0, 1.0));
            float cyc = T / life + hash13(float3(fi, 32.0, 1.0));
            float gen = floor(cyc), age = fract(cyc);
            float a0 = arcMid + arcHalf * 0.9 * (2.0 * hash13(float3(fi, gen, 33.0)) - 1.0);
            float Wl = 0.025 + 0.04 * hash13(float3(fi, gen, 34.0));
            float Hl = 0.04 + 0.07 * hash13(float3(fi, gen, 35.0));
            float lean = (hash13(float3(fi, gen, 36.0)) - 0.5) * 0.5;
            float2 L = float2(wrapPi(ang - a0) - lean * h, h + 0.008 * hash13(float3(fi, gen, 37.0)));
            if (abs(L.x) > Wl * 1.7 + Hl * 0.5 || L.y > Hl * 1.15) continue;
            float vis = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.75, 1.0, age));
            float boost = 1.0 + 2.0 * S.c.z * exp(-pow(wrapPi(a0 - S.c.x) / 0.15, 2.0));   // a nearby flare lights them up
            loops += loopFamily(L, Wl, Hl, 6 + int(4.0 * hash13(float3(fi, gen, 38.0))), 0.5, fi * 3.1 + gen, T, px) * vis * boost;
        }
        col += chrom * prom * 0.22 + mix(surf, hot, 0.4) * loops * 0.35;
    }

    // ---- events ----
    // flare: two thin ribbons drifting apart on the disk just inside the limb, saturating at first,
    // with an arcade of nested loops growing over them that cools from white-hot to chromospheric red
    if (S.c.z > 0.0) {
        float fa = S.c.x, fb = S.c.z, sz = S.c.w, fp = S.f.x;
        float2 nrm = float2(cos(fa), sin(fa)), tg = float2(-nrm.y, nrm.x);
        float2 l = d - nrm * (1.0 - S.c.y);
        l = float2(dot(l, tg), dot(l, nrm));
        if (abs(l.x) < sz * 3.0 && l.y < sz * 3.0 && l.y > -sz * 2.0) {
            float seed = fa * 17.0;
            float sep = sz * (0.3 + 0.6 * pow(fp, 0.6));
            float len = sz * 0.6;
            float w = max(0.002, 1.2 * px);
            float rib = 0.0;
            for (int k = -1; k <= 1; k += 2) {
                float fk = float(k);
                float x = l.x - fk * sep - sz * 0.25 * (noise3(float3(l.y / sz * 2.0, fk * 3.0 + seed, 0.0)) - 0.5)
                          - fk * sz * 0.3 * pow(abs(l.y) / len, 2.0);   // hooked ends
                float knots = 0.4 + smoothstep(0.4, 0.85, noise3(float3(l.y / sz * 7.0, fk * 5.0, T * 0.1)));
                rib += exp(-x * x / (w * w)) * knots * (0.002 / w);
            }
            rib *= exp(-pow(l.y / len, 4.0)) * (1.0 - offDisk);
            float kern = exp(-length(l) / (sz * 0.12)) * (1.0 - smoothstep(0.0, 0.25, fp));
            float ah = sz * (0.35 + 0.9 * smoothstep(0.03, 0.6, fp));
            float arc = loopFamily(l + float2(0.0, sz * 0.1), sep, ah, 10, 0.0, seed, T, px) * 1.6 * smoothstep(0.0, 0.15, fp);
            float glow = exp(-length_squared(l - float2(0.0, ah * 0.4)) / (sz * sz)) * smoothstep(0.0, 0.05, fp) * (1.0 - smoothstep(0.15, 0.6, fp));
            float3 arcCol = mix(mix(hot, float3(1.0), 0.5), mix(chrom, hot, 0.4), smoothstep(0.25, 0.8, fp));
            col += mix(hot, float3(1.0), 0.7) * fb * (rib * 1.2 + kern * 1.5) + arcCol * arc * (0.35 + 0.4 * fb) + mix(hot, float3(1.0), 0.3) * glow * 0.3 * fb;
        }
    }

    if (offDisk > 0.0) {
        // surge: a narrow jet of chromospheric plasma shot up along the field, fanning a little,
        // that slows, stalls and drains back down the same path
        if (S.f.w > 0.0) {
            float sa = S.f.y, sp = S.f.z, seed = fract(sa * 13.7) * 50.0;
            float2 L = float2(wrapPi(ang - sa), h);
            float top = (0.1 + 0.15 * hash13(float3(seed, 2.0, 1.0))) * pow(sin(3.14159265 * sp), 0.8);
            float lean = (hash13(float3(seed, 3.0, 1.0)) - 0.5) * 0.6;
            float bend = (hash13(float3(seed, 5.0, 1.0)) - 0.5) * 2.0;
            float x = L.x - lean * L.y - bend * L.y * L.y;
            float wid = 0.006 + 0.1 * L.y;
            if (abs(x) < wid * 3.0 + 3.0 * px && L.y < top * 1.3 + 0.02) {
                // a spray of threads with ragged tops, densest along the axis
                float xa = x / wid;
                float topk = top * (0.6 + 0.5 * noise3(float3(xa * 1.5, seed, sp * 3.0)));
                float env = exp(-xa * xa * 0.7) * smoothstep(topk + 0.02, topk - 0.02, L.y);
                float flow = sp < 0.5 ? -0.3 : 0.2;
                float thr = threads(x, L.y / 0.02 + T * flow, 0.003, px, seed);
                thr *= 0.4 + 0.9 * smoothstep(0.3, 0.7, noise3(float3(xa * 0.8, L.y / 0.03 + T * flow * 0.5, seed + 4.0)));
                float base = exp(-L.y / 0.005) * exp(-x * x / 1e-4);
                col += (chrom * env * thr * 1.3 + hot * base * 0.6) * S.f.w * offDisk;
            }
        }

        // eruptive prominence: a hanging prominence that lifts off, slowly then faster, swelling
        // into a huge, faint arch of twisted threads that breaks into wisps, its legs draining
        if (S.e.z > 0.0) {
            float ea = S.e.x, fp = S.e.y, seed = S.e.w;
            float2 L = float2(wrapPi(ang - ea), h);
            float rise = max(fp - 0.2, 0.0) / 0.8;
            float Hh = 0.07 + 0.03 * smoothstep(0.0, 0.2, fp) + 2.6 * pow(rise, 1.8);
            float Wp = 0.08 + 0.05 * smoothstep(0.2, 0.7, fp) + 0.35 * rise;
            if (abs(L.x) < Wp * 1.5 + Hh * 0.4 + 0.05 && L.y < Hh * 1.4 + 0.05) {
                float2 Lw = L + noise2(float3(L * 2.0 / (0.15 + Hh), seed + T * 0.01)) * (0.01 + 0.2 * Hh) * smoothstep(0.0, 0.3, L.y / Hh);
                float2 en = Lw / float2(Wp, Hh);
                float e = length(en);
                float uu = atan2(max(en.y, 0.0), en.x);
                float spacing = 0.003 * (1.0 + 6.0 * rise);
                // as it rises the rope loosens from a band into a broad, billowing cloud
                float rope = smoothstep(0.5 - 0.25 * rise, 0.75 - 0.2 * rise, e) * smoothstep(1.1 + 0.1 * rise, 0.92 - 0.1 * rise, e);
                float thr = threads(e * Hh, uu * 6.0 - T * 0.03, spacing, px, seed);
                // a second set of threads crossing at an angle: the twist of the flux rope
                float twist = threads(e * Hh + 0.3 * Hh * sin(uu * 3.0), uu * 3.0, spacing * 1.5, px, seed + 9.0);
                float wisps = smoothstep(0.3 + 0.2 * rise, 0.6 + 0.1 * rise, fbm(float3(Lw / (0.1 + Hh) * 2.0, seed)));
                // thin, ragged filaments: the ridges of a noise field, combed a little along the arch
                float ridge = 1.0 - abs(2.0 * fbm(float3(Lw / (0.1 + Hh) * float2(4.0, 3.0) + float2(uu, 0.0), seed + 5.0)) - 1.0);
                float filaments = ridge * ridge * ridge * 2.2;
                float loose = smoothstep(0.0, 0.35, rise);
                float combed = mix(0.6 * thr + 0.4 * twist * smoothstep(0.1, 0.4, fp), 1.0, 0.6 * loose);
                float em = rope * combed * mix(1.0, wisps * mix(1.0, filaments, loose), smoothstep(0.25, 0.6, fp));
                em *= smoothstep(0.0, 0.01, L.y) / (1.0 + 5.0 * Hh) * (1.0 - 0.4 * loose);
                // before it goes, it's a quiet prominence hanging under the arch
                float hang = 1.0 - smoothstep(0.15, 0.4, fp);
                if (hang > 0.0) em += prominence(L, Wp * 0.9, Hh * 0.95, 0.3, seed, T, px) * hang;
                // what's left of the legs drains back down
                if (fp > 0.4 && L.y < 0.15) {
                    float lx = abs(L.x) - Wp * 0.85;
                    em += exp(-lx * lx / 2e-4) * threads(L.x, L.y / 0.01 + T * 0.4, 0.003, px, seed + 2.0)
                          * smoothstep(0.15, 0.03, L.y) * smoothstep(0.4, 0.6, fp) * 0.5;
                }
                col += mix(chrom, hot, 0.1) * em * 1.0 * S.e.z * offDisk;
            }
        }

        // coronal mass ejection: a faint, self-similar bubble expanding at constant angular width:
        // a fibrous, loop-shaped front, a darker cavity, a bright twisted core, and legs to the limb
        if (S.d.z > 0.0) {
            float ca = S.d.x, fp = S.d.y, seed = S.d.w;
            float2 nrm = float2(cos(ca), sin(ca)), tg = float2(-nrm.y, nrm.x);
            float2 L = float2(dot(d, tg), dot(d, nrm));
            float hw = 0.35 + 0.15 * fract(seed * 0.37);   // half width of the cone
            float rF = 1.06 + 3.6 * pow(fp, 1.25);         // leading edge, from the star's center
            float sw = sin(hw);
            float rB = rF / (1.0 + sw), rb = rB * sw;
            if (L.y > 0.0 && abs(L.x) < rb * 1.4 + 0.05 && L.y < rF + rb * 0.4) {
                float2 Lw = L + noise2(float3(L * 1.5 / rb, seed + T * 0.01)) * rb * 0.15;
                float2 rel = Lw - float2(0.0, rB);
                float rr = length(rel);
                float phi = atan2(rel.x, rel.y);
                float dB = rr - rb * (1.0 + 0.15 * (noise3(float3(rel / max(rr, 1e-4) * 1.3, seed)) - 0.5));
                float th = 0.22 * rb;
                float shell = exp(-pow(max(dB, 0.0) / (th * 0.45), 2.0)) * exp(min(dB, 0.0) / th);
                float lead = 0.25 + 0.75 * smoothstep(-0.6, 0.9, cos(phi));
                // fibrous: soft strands running along the front, broken into clumps
                float fib = mix(1.0, threads(dB + 0.1 * rb * noise3(float3(phi * 2.0, seed, 3.0)), phi * 4.0, 0.07 * rb, px, seed), 0.45);
                float3 cq = float3(Lw * 4.0 / rb, seed + 1.0);
                float clumps = 0.35 + 0.9 * smoothstep(0.25, 0.75, (noise3(cq) * 2.0 + noise3(cq * 2.1 + 3.0)) / 3.0 + 0.17);
                float front = shell * lead * fib * clumps;
                // legs: faint flanks of the cone reaching back toward the limb
                float th2 = atan2(L.x, L.y);
                float legs = exp(-pow((abs(th2) - hw * 0.85) / 0.08, 2.0)) * smoothstep(rB, rB * 0.6, length(L)) * 0.12
                           * smoothstep(1.0, 1.3, length(L)) * clumps;
                // the core: erupted prominence material, a twisted, wispy knot trailing the front
                float2 cp = rel + float2(0.0, rb * 0.4);
                float2 cw = cp / rb;
                float core = 0.0;
                if (dot(cw, cw) < 0.3) {
                    cw += noise2(float3(cp / rb * 3.0, seed + 7.0)) * 0.25;
                    core = exp(-dot(cw, cw * float2(1.0, 1.6)) / 0.06)
                         * smoothstep(0.4, 0.75, fbm(float3(cw * float2(5.0, 2.5), seed + 4.0)));
                }
                float cav = smoothstep(0.0, -0.35 * rb, dB) * (1.0 - exp(-dot(cw, cw) / 0.08));
                float dim = 1.0 / (rF * rF);
                col *= 1.0 - 0.3 * cav * S.d.z * offDisk;
                col += (mix(surf, hot, 0.5) * (front + legs) * 0.55 + chrom * core * 1.0) * dim * S.d.z * offDisk;
            }
        }
    }
    return finalize(col, p, F);
}
"""
}
