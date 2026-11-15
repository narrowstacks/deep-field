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
// S.b = star color, spot amount; S.c = flare angle, depth inside the limb, brightness, size;
// S.f = flare progress, surge angle, surge progress, surge brightness;
// S.d = coronal mass ejection angle, progress, brightness, seed;
// S.e = eruptive prominence angle, progress, brightness, seed.
// Progress runs 0..1 over an event's life; a brightness of 0 means it isn't running.

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

static float wrapPi(float a) { return a - 6.2831853 * floor(a / 6.2831853 + 0.5); }

// A magnetic flux tube arching from x = W to x = -W (L in screen units, y up from the limb,
// apex at height Hh). It sways and writhes, and is wound from `strands` twisted threads of
// uneven thickness. Blobs of plasma run along it: drain 0 siphons them from one foot to the
// other, drain 1 drains them from the top down both legs (coronal rain). Returns emission.
static float fluxTube(float2 L, float W, float Hh, float thick, float t, float seed,
                      int strands, float twist, float drain, float writhe)
{
    float yn = saturate(L.y / Hh);
    L.x -= Hh * yn * yn * writhe * (0.3 * sin(t * 0.17 + seed * 5.0) + 0.6 * (noise3(float3(seed * 3.1, t * 0.06, 0.5)) - 0.5));
    float2 en = float2(L.x / W, L.y / Hh);
    float e = max(length(en), 1e-4);
    float u = atan2(max(en.y, 0.0), en.x) * 0.31830989;        // 0 at one foot, 1 at the other
    float g = length(float2(en.x / W, en.y / Hh)) / e;           // change in e per screen unit
    float env = sin(3.14159265 * u);
    float d0 = (e - 1.0) / g;
    // kinks running along the tube, and a slow wander
    d0 -= Hh * writhe * env * (0.06 * sin(u * 11.0 - t * 0.45 + seed * 3.0)
                               + 0.22 * (noise3(float3(u * 2.5, t * 0.05, seed)) - 0.5));
    if (abs(d0) > thick * 6.0) return 0.0;
    float fc = mix(u, abs(u - 0.5), drain);
    float acc = 0.0;
    for (int s = 0; s < strands; s++) {
        float fs = float(s);
        float th = thick * (0.4 + 0.9 * noise3(float3(u * 6.0 + fs * 3.7, t * 0.04, seed + fs))) * (0.7 + 0.5 * env);
        float off = thick * 1.4 * sin(twist * u * 6.2831853 + fs * 6.2831853 / float(strands) + t * 0.15 + seed) * (0.35 + env);
        float d = (d0 - off) / th;
        if (d * d > 9.0) continue;
        float blobs = noise3(float3(fc * 18.0 - t * (0.22 + 0.35 * drain), fs * 5.3, seed));
        acc += exp(-d * d) * (0.3 + 1.2 * smoothstep(0.45, 0.85, blobs)) * sqrt(thick / th);
    }
    return acc * smoothstep(-0.004, 0.004, L.y) / float(strands) * 2.0;
}

static float2 noise2(float3 p) {
    return float2(noise3(p), noise3(p + float3(31.4, 17.7, 5.3))) - 0.5;
}

fragment float4 stellarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 col;
    float W = F.camRight.w, H = F.camUp.w;
    float T = F.time;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    float2 C = S.a.xy;
    float R = S.a.z;
    float2 d = q - C;
    float dist = length(d);
    float3 starCol = S.b.rgb;
    starCol = max(mix(float3(dot(starCol, float3(0.3, 0.55, 0.15))), starCol, 1.8), 0.0);   // richer surface color
    float spotAmt = S.b.w;
    float ang = atan2(d.y, d.x);
    float3 hAlpha = float3(1.0, 0.25, 0.3);
    float3 hot = mix(starCol, float3(1.0), 0.6);
    float offDisk = smoothstep(R - 0.003, R + 0.003, dist);

    if (dist < R) {
        float2 n2 = d / R;
        float3 N = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
        float mu = N.z;
        float lon = atan2(N.x, N.z) + S.a.w, lat = asin(clamp(N.y, -1.0, 1.0));
        float2 surf = float2(lon * cos(lat), lat);
        float limb = 0.28 + 0.72 * pow(mu, 0.55);
        float gran = mix(granules(surf * 48.0, T), fbm(float3(surf * 90.0, T * 0.01)), 0.35) * 0.45 + 0.68;
        float superg = 0.92 + 0.08 * fbm(float3(surf * 9.0, T * 0.002));
        // sunspots: each lives a while, then fades, and drifts with the rotation
        float spot = 1.0;
        float facula = 0.0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float life = 240.0 + 120.0 * hash13(float3(fi, 1.0, 3.0));
            float cyc = T / life + hash13(float3(fi, 2.0, 3.0));
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
    } else {
        col = SKY(p, octDecode(dirTex.read(p).xy), false) * 0.6;
        float h = (dist - R) / R;
        // Terms that fall off with height are skipped once they are below about e^-12.
        // chromosphere and spicules
        col += hAlpha * exp(-h / 0.006) * 1.4;
        if (h < 0.24) {
            float spic = fbm(float3(ang * 260.0, h * 90.0 - T * 0.35, 1.0));
            col += hAlpha * smoothstep(0.45, 0.8, spic) * exp(-h / 0.02) * 0.7;
        }
        // corona with streamers (its scale height is at most 0.18)
        if (h < 2.2) {
            float stream = fbm(float3(cos(ang) * 5.0, sin(ang) * 5.0, T * 0.004));
            col += mix(starCol, float3(1.0), 0.5) * exp(-h / (0.06 + 0.12 * stream)) * (0.05 + 0.12 * stream);
        }
        // coronal loops: twisted, writhing flux tubes rooted on the limb, with plasma siphoning
        // along them or draining down their legs. Loops reach at most 0.17 R, plus their sway.
        float flareBoost = S.c.z;
        for (int i = 0; i < 6 && h < 0.3; i++) {
            float fi = float(i);
            float life = 260.0 + 200.0 * hash13(float3(fi, 8.0, 1.0));
            float cyc = T / life + hash13(float3(fi, 9.0, 1.0));
            float gen = floor(cyc), age = fract(cyc);
            float vis = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.7, 1.0, age));
            float a0 = 0.45 + 2.2 * hash13(float3(fi, gen, 2.0));
            float Wl = R * (0.035 + 0.07 * hash13(float3(fi, gen, 3.0)));
            float Hl = R * (0.04 + 0.13 * hash13(float3(fi, gen, 4.0)));
            float2 L = float2(wrapPi(ang - a0) * R, dist - R);
            float lean = (hash13(float3(fi, gen, 5.0)) - 0.5) * 1.2;
            L.x -= lean * L.y;
            if (abs(L.x) > Wl * 1.3 + Hl * 0.6 || L.y > Hl * 1.5) continue;
            float hotness = hash13(float3(fi, gen, 6.0));
            float drain = step(0.55, hash13(float3(fi, gen, 7.0)));
            float em = fluxTube(L, Wl, Hl, 0.0055 + 0.004 * hotness, T, fi * 7.3 + gen, 3, 1.0 + 2.0 * hotness, drain, 0.7);
            float boost = 1.0 + 2.5 * flareBoost * exp(-pow(wrapPi(a0 - S.c.x) / 0.15, 2.0));
            col += mix(hAlpha * 1.1, hot, 0.25 + 0.6 * hotness) * em * vis * 0.8 * boost;
        }
        // prominences: clouds of cooler plasma hanging above the limb, combed into threads
        if (h < 0.84) {
            float prom = smoothstep(0.58, 0.82, fbm(float3(ang * 7.0, h * 14.0 - T * 0.01, 4.0)));
            if (prom > 0.0) {
                prom *= exp(-h / 0.07) * smoothstep(0.5, 0.7, fbm(float3(ang * 2.0, 1.0, 7.0)));
                prom *= 0.55 + 0.7 * noise3(float3(ang * 140.0 + h * 30.0, h * 9.0 - T * 0.03, 2.0));
            }
            col += hAlpha * prom * 1.1;
        }
    }

    // ---- events ----
    // flare: two ribbons drifting apart on the disk near the limb, flickering, with an arcade of
    // hot loops growing over them that cools and rains back down
    if (S.c.z > 0.0) {
        float fa = S.c.x, fb = S.c.z, sz = S.c.w, fp = S.f.x;
        float2 nrm = float2(cos(fa), sin(fa)), tg = float2(-nrm.y, nrm.x);
        float2 l = q - (C + nrm * R * (1.0 - S.c.y));
        l = float2(dot(l, tg), dot(l, nrm));
        if (abs(l.x) < sz * 5.0 && l.y < sz * 7.0 && l.y > -sz * 5.0) {
            float seed = fa * 17.0;
            float sep = sz * (0.22 + 0.55 * pow(fp, 0.6));
            float len = sz * 1.2;
            float rib = 0.0;
            for (int k = -1; k <= 1; k += 2) {
                float fk = float(k);
                float x = l.x - fk * sep - sz * 0.5 * noise2(float3(l.y / sz * 1.8, fk * 3.0 + seed, T * 0.04)).x
                          - fk * sz * 0.25 * pow(max(abs(l.y) / len, 0.0), 2.0);
                float knots = 0.35 + 1.3 * smoothstep(0.45, 0.9, noise3(float3(l.y / sz * 8.0, fk * 5.0, T * 0.5)));
                rib += exp(-pow(x / (sz * 0.07), 2.0)) * knots;
            }
            rib *= exp(-pow(l.y / len, 4.0)) * (1.0 - offDisk);
            float kern = exp(-length(l) / (sz * 0.6)) * (1.0 - offDisk) * (1.0 - smoothstep(0.0, 0.3, fp));
            // the post-flare arcade: loops from ribbon to ribbon rising outward, hot at first,
            // then cooling, with condensed plasma raining down their legs
            float arc = 0.0;
            float ah = sz * (0.5 + 1.6 * smoothstep(0.03, 0.55, fp));
            if (abs(l.x) < sep * 1.5 + ah * 0.5 && l.y < ah * 1.6 + sz && l.y > -sz * 1.5) {
                float drain = smoothstep(0.35, 0.7, fp);
                for (int k = 0; k < 6; k++) {
                    float fk = float(k);
                    float2 lk = l - float2(sz * 0.1 * (fk - 2.5), -sz * 0.18 * fk);
                    arc += fluxTube(lk, sep * (0.8 + 0.1 * fk), ah * (0.7 + 0.08 * fk), sz * 0.05, T, seed + fk * 3.3, 2, 1.5, drain, 0.3);
                }
                arc *= smoothstep(0.0, 0.2, fp) * 1.6;
            }
            float glow = exp(-length_squared(l - float2(0.0, ah * 0.7)) / pow(sz * 1.5, 2.0)) * smoothstep(0.0, 0.1, fp) * (1.0 - smoothstep(0.2, 0.7, fp));
            float3 arcCol = mix(float3(1.0, 0.95, 0.85), mix(hAlpha, hot, 0.35), smoothstep(0.2, 0.75, fp));
            col += arcCol * glow * 0.35 * fb;
            col += float3(1.0, 0.97, 0.9) * fb * (rib * 1.3 + kern * 0.8) + arcCol * arc * (0.25 + 0.5 * fb) * 1.4;
        }
    }

    float hh = dist - R;   // height above the limb, screen units
    if (offDisk > 0.0) {
        // surge / spray: threads of chromospheric plasma shot up, then falling back along their path
        if (S.f.w > 0.0) {
            float sa = S.f.y, sp = S.f.z, seed = fract(sa * 13.7) * 50.0;
            float2 L = float2(wrapPi(ang - sa) * R, hh);
            float fan = 0.06 + 0.4 * hash13(float3(seed, 1.0, 1.0));
            float top = (0.3 + 0.35 * hash13(float3(seed, 2.0, 1.0))) * pow(sin(3.14159265 * sp), 0.7);
            if (L.y < top * 1.3 + 0.03 && abs(L.x) < 0.04 + (fan + 0.3) * top) {
                float lean = (hash13(float3(seed, 3.0, 1.0)) - 0.5) * 0.6;
                float acc = 0.0;
                float rising = sp < 0.5 ? 1.0 : -0.7;
                for (int k = 0; k < 7; k++) {
                    float fk = (float(k) - 3.0) * 0.67;
                    float hk = hash13(float3(seed, float(k), 4.0));
                    float topk = top * (0.55 + 0.45 * hk);
                    float cx = L.y * (lean + fan * fk * 0.5) + 0.6 * L.y * L.y * fk * fan
                             + 0.012 * (noise3(float3(L.y * 12.0, fk, T * 0.2 + seed)) - 0.5);
                    float wk = 0.004 + 0.004 * hk + 0.012 * L.y;
                    float dx = (L.x - cx) / wk;
                    if (dx * dx > 9.0) continue;
                    float knots = smoothstep(0.4, 0.85, noise3(float3(L.y * 30.0 - T * 1.1 * rising, fk * 3.0, seed)));
                    acc += exp(-dx * dx) * smoothstep(topk, topk - 0.03, L.y) * (0.15 + 1.5 * knots);
                }
                float base = exp(-L.y / 0.015) * exp(-pow(L.x / 0.05, 2.0));
                col += (mix(hAlpha, hot, 0.25) * acc + hot * base) * S.f.w * offDisk;
            }
        }

        // eruptive prominence: a twisted rope of cool plasma that hangs, lifts off, writhes,
        // tears apart, and leaves its legs raining back onto the star
        if (S.e.z > 0.0) {
            float ea = S.e.x, fp = S.e.y, seed = S.e.w;
            float2 L = float2(wrapPi(ang - ea) * R, hh);
            float lift = smoothstep(0.15, 0.4, fp);
            float Hh = 0.09 + 0.05 * smoothstep(0.0, 0.25, fp) + 2.4 * pow(max(fp - 0.2, 0.0), 1.7);
            float Wp = 0.13 + 0.14 * smoothstep(0.2, 0.8, fp);
            float brk = smoothstep(0.42, 0.85, fp);
            if (abs(L.x) < Wp * 1.4 + Hh * 0.7 + 0.08 && L.y < Hh * 1.7 + 0.1) {
                float yn = saturate(L.y / Hh);
                float tw = (0.006 + 0.03 * lift + 0.09 * brk) * (0.25 + yn);
                float2 Lw = L + noise2(float3(L * 6.0 / (0.3 + Hh * 0.5), T * 0.07 + seed)) * 2.0 * tw;
                float ts = T * (1.0 + 2.0 * lift);
                float rope = fluxTube(Lw, Wp, Hh, 0.012 + 0.02 * fp, ts, seed, 4, 2.5 - 1.8 * brk, 0.0, 0.5 + 1.5 * lift);
                // the hanging body below the rope: vertical threads, like a hedgerow
                float2 en = Lw / float2(Wp, Hh);
                float body = smoothstep(1.05, 0.6, length(en)) * smoothstep(0.0, 0.01, L.y)
                           * (0.25 + 0.75 * smoothstep(0.35, 0.8, noise3(float3(Lw.x * 70.0, Lw.y * 5.0 - T * 0.05, seed))))
                           * (1.0 - smoothstep(0.2, 0.45, fp));
                // tearing apart, the top first
                float frag = fbm(float3(Lw * float2(9.0, 5.0) / (0.3 + Hh * 0.4), seed + fp * 3.0));
                float keep = mix(1.0, smoothstep(0.45, 0.75, frag), brk * smoothstep(0.05, 0.3, L.y));
                float dim = 1.0 / (1.0 + 1.3 * Hh);
                float em = (rope * 1.3 + body * 0.7) * keep * dim;
                // what's left of the legs drains back down
                if (fp > 0.45) {
                    float legs = fluxTube(L, Wp * 0.9, 0.14 + 0.06 * fp, 0.008, T, seed + 7.0, 2, 1.0, 1.0, 0.4);
                    em += legs * smoothstep(0.45, 0.65, fp) * smoothstep(0.03, 0.12, abs(L.x));
                }
                col += mix(hAlpha * 1.3, hot, 0.2 + 0.3 * smoothstep(0.6, 0.0, frag) * lift) * em * S.e.z * offDisk;
            }
        }
    }

    // coronal mass ejection: a turbulent, striated front tearing away from the star, a dark
    // cavity, a tangled bright core, and material raining back down the legs
    if (S.d.z > 0.0) {
        float ca = S.d.x, fp = S.d.y, seed = S.d.w;
        float2 nrm = float2(cos(ca), sin(ca)), tg = float2(-nrm.y, nrm.x);
        float2 L = q - (C + nrm * R);
        L = float2(dot(L, tg), dot(L, nrm));
        float Hc = 0.16 + 2.6 * pow(fp, 1.15);
        float rc = 0.10 + 1.15 * pow(fp, 1.05);
        if (L.y > -0.05 && abs(L.x) < rc * 1.8 + 0.2 && L.y < Hc + rc * 1.9) {
            float2 Lw = L + noise2(float3(L * 2.5 / (0.25 + rc), T * 0.04 + seed)) * rc * 0.35
                          + noise2(float3(L * 9.0 / (0.25 + rc), T * 0.08 + seed)) * rc * 0.08;
            float2 rel = Lw - float2(0.0, Hc);
            float rr = length(rel);
            float phi = atan2(rel.x, rel.y);
            float dB = rr - rc * (1.0 + 0.3 * (noise3(float3(rel / max(rr, 1e-4) * 1.6, seed + fp)) - 0.5));
            float th = 0.02 + 0.07 * fp;
            // a sharp outer edge, thick and clumpy behind it, brightest along the leading edge
            float prof = exp(-pow(max(dB, 0.0) / (th * 0.5), 2.0)) * exp(min(dB, 0.0) / (th * 1.6));
            float lead = 0.25 + 0.75 * smoothstep(-0.7, 0.9, cos(phi));
            float clumps = 0.25 + 1.2 * smoothstep(0.35, 0.8, fbm(float3(Lw * 5.0 / rc, seed + T * 0.02)));
            float stri = 0.6 + 0.6 * smoothstep(0.35, 0.75, fbm(float3(phi * 10.0, rr / rc * 1.2 - fp * 2.0, seed)));
            float front = prof * lead * clumps * stri;
            // the legs: frayed streamers dragged out behind it
            float legX = mix(0.12 + 0.1 * fp, rc * 0.75, smoothstep(0.0, Hc, Lw.y));
            float dL = abs(Lw.x) - legX;
            front += exp(-pow(dL / (th * 1.5), 2.0)) * 0.3 * step(Lw.y, Hc) * clumps * (1.0 - 0.6 * smoothstep(0.0, Hc, Lw.y));
            float cav = smoothstep(0.0, -0.3, dB / rc) * 0.03;
            float halo = exp(-max(dB, 0.0) / (rc * 0.3)) * 0.07 * lead;
            // the core: the erupted prominence, a tangled, twisted knot
            float2 cp = rel + float2(0.0, rc * 0.4) + noise2(float3(rel * 4.0 / rc, seed + 3.0)) * rc * 0.3;
            float sw = length(cp) / rc * 1.5 - T * 0.03;
            float2 cr = float2(cos(sw) * cp.x - sin(sw) * cp.y, sin(sw) * cp.x + cos(sw) * cp.y);
            float core = smoothstep(0.6, 0.85, fbm(float3(cr * 8.0 / rc, seed + T * 0.03)))
                       * exp(-dot(cp, cp) / pow(rc * 0.38, 2.0));
            float dil = 1.0 / (1.0 + 1.6 * rc);
            float3 e = mix(starCol, float3(1.0), 0.5) * (front * 0.9 + cav + halo) + hAlpha * core * 1.2;
            // late on, material falls back down the legs near the limb
            if (fp > 0.3 && L.y < 0.45) {
                float lx = abs(L.x) - (0.12 + 0.1 * fp) - 0.06 * L.y;
                float rain = smoothstep(0.6, 0.9, noise3(float3(L.x * 70.0, L.y * 9.0 + T * 0.5, seed)))
                           * exp(-pow(lx / 0.03, 2.0)) * smoothstep(0.45, 0.2, L.y);
                e += mix(hAlpha, hot, 0.3) * rain * smoothstep(0.3, 0.5, fp) * 2.5 / dil;
            }
            col += e * S.d.z * dil * smoothstep(-0.01, 0.03, L.y) * offDisk;
        }
    }
    return finalize(col, p, F);
}
"""
}
