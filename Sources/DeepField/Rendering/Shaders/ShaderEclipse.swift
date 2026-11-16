extension ShaderSource {
    static let eclipse = """
// ---------- per-frame: eclipse ----------
// A total solar eclipse seen from the surface of a small airless moon. With no air there's no
// sky glow, so the sky stays black and the corona shows whenever the sun's glare allows; the eye
// (and the exposure) adapts as the sun is covered. The scene has its own camera: screen
// coordinates in half screen heights, a ray through each at `th` per unit, pitched up by `pitch`.
// The world frame has y up, the camera at the origin, and the moon's center straight below.
// Sky features are laid out on the plane of the sky around the sun, in sun radii.
//
// S.a = sun direction, tan of the sun's angular radius
// S.b = occluder center relative to the sun (sun radii, along sx, sy), occluder radius, sunlight still reaching us (0..1)
// S.c = corona color, corona size
// S.d = prominence color, prominence amount
// S.e = ground color, landscape on (1) or off (0)
// S.f = planet direction, tan of its angular radius (0 = none)
// S.g = planet color, corona brightness
// S.h = eruption: angle round the sun, progress, brightness, seed
// S.i = tan of half the vertical field of view, camera pitch, shadow parallax (sun radii per moon radius), planet's lit fraction
// S.j = middle of the uncovered sunlight (sun radii), eye adaptation gain, log10 of the uncovered sunlight

constant float EC_HEIGHT = 0.0098;   // the camera above the ground, moon radii (the horizon dips 8 degrees)
constant float EC_MOUNT = 0.012;     // the occluder's limb relief, sun radii
constant float EC_AXIS = 0.35;       // the sun's spin axis, radians from the sky's up

// The occluder's limb: mountains (+) and valleys (-), whole numbers of waves round the limb so
// there's no seam. Valleys let the last beads of sunlight through. Mirrors SceneParams.eclipseLimb.
static float ecLimb(float a) {
    float hills = 0.35 * sin(7.0 * a + 1.3) + 0.2 * sin(13.0 * a + 0.4) + 0.1 * sin(29.0 * a + 2.1);
    float notches = pow(max(sin(11.0 * a + 0.7), 0.0), 12.0) + 0.8 * pow(max(sin(17.0 * a + 2.9), 0.0), 12.0)
                  + 0.7 * pow(max(sin(23.0 * a + 4.4), 0.0), 16.0);
    return hills - 1.3 * notches;
}

// The share of the sun's disk (radius 1) left uncovered by a smooth disk of radius R, d away.
static float ecUncovered(float d, float R) {
    if (d >= 1.0 + R) return 1.0;
    if (d <= R - 1.0) return 0.0;
    float a1 = acos(clamp((d * d + 1.0 - R * R) / (2.0 * d), -1.0, 1.0));
    float a2 = acos(clamp((d * d + R * R - 1.0) / (2.0 * d * R), -1.0, 1.0));
    float k = max((-d + 1.0 + R) * (d + 1.0 - R) * (d - 1.0 + R) * (d + 1.0 + R), 0.0);
    return 1.0 - (a1 + R * R * a2 - 0.5 * sqrt(k)) / M_PI_F;
}

// The corona: a smooth K corona falling steeply from the limb, helmet streamers (broad over
// the active belts, narrowing into long rays) and polar plumes, with fine radial striations and
// density drifting outward in the solar wind. Returns light.
static float3 ecCorona(float2 d, float r, float T, float size, float3 tint) {
    float a = atan2(d.y, d.x);
    float rs = 1.0 + (r - 1.0) / size;
    float u = log(rs);
    float2 cs = float2(cos(a), sin(a));
    float base = 0.5 * pow(rs, -14.0) + 0.16 * pow(rs, -3.0);
    // streamers: rooted along the equator (90 degrees from the axis), leaning with the field
    float str = 0.0;
    for (int k = 0; k < 12; k++) {
        float fk = float(k);
        float3 hk = hash33(float3(fk * 3.1, 7.7, 1.9));
        float h4 = fract(hk.x * 7.3 + hk.y * 3.1);
        float side = hk.x < 0.5 ? 0.0 : M_PI_F;
        float a0 = EC_AXIS + 1.5708 + side + (hk.y - 0.5) * (k < 6 ? 1.2 : 2.6) + 0.02 * sin(T * 0.004 + fk);
        float bend = (hk.z - 0.5) * 0.9 * (1.0 - 1.0 / rs);
        // a broad helmet near the limb pinching into a long thin stalk
        float w = (0.16 + 0.24 * hk.z) * (0.45 + 1.0 * exp(-(rs - 1.0) * 1.6));
        float da = wrapPi(a - a0 - bend);
        float reach = 1.0 + 1.3 * h4;              // how far it carries: lower falls off faster
        str += exp(-sq(da / w)) * (0.25 + 0.5 * h4) * pow(rs, -reach);
    }
    float stream = str;
    // polar plumes: thin straight rays fanning out of the poles
    float pa = abs(cos(wrapPi(a - EC_AXIS)));
    float plumes = smoothstep(0.75, 0.97, pa) * pow(rs, -4.5) * (0.4 + 0.9 * smoothstep(0.45, 0.8, noise3(float3(cs * 30.0, 3.0))));
    float rays = 0.7 + 0.6 * noise3(float3(cs * 16.0, u * 0.8 + 4.0));
    float flow = 0.7 + 0.6 * noise3(float3(cs * 7.0, u * 5.0 - T * 0.04));
    float flow2 = 0.8 + 0.4 * noise3(float3(cs * 12.0, u * 7.0 - T * 0.07 + 9.0));
    float I = base * (0.85 + 0.3 * rays) + stream * mix(1.0, rays * flow * flow2, 0.7) * 0.6 + plumes * rays * 0.4 + 0.06 * pow(rs, -1.8);
    I *= exp(-sq((rs - 1.0) / 8.0));   // the outer corona thins into the sky, no edge
    // pearly near the limb, toward the corona color farther out, the hue drifting round it
    float drift = noise3(float3(cs * 2.0, 11.0 + T * 0.002));
    float3 pearl = float3(1.0, 0.96, 0.9);
    float3 c = mix(pearl, tint, smoothstep(1.1, 2.6, rs) * (0.65 + 0.5 * drift));
    c = mix(c, c * float3(1.05, 0.92, 1.1), smoothstep(0.4, 0.8, drift) * smoothstep(1.4, 3.0, rs));
    return c * I;
}

// One layer of craters `cell` apart: bowls with raised rims and ejecta aprons. Adds height,
// slope (in the uv plane), and the shadows the rims cast onto the floors for two lights, each
// given as a horizontal direction (xy) and the tangent of its elevation (z), w = penumbra.
static void ecCraters(float2 uv, float cell, float seed, float fp, float4 L1, float4 L2,
                      thread float& h, thread float2& g, thread float& sh1, thread float& sh2, thread float& alb) {
    if (cell * 0.12 < fp) return;     // the whole layer is under a pixel: just the albedo
    float2 cid = floor(uv / cell);
    const float D = 0.26, RIM = 0.06;
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        float2 c = cid + float2(i, j);
        float3 hh = hash33(float3(c, seed));
        if (hh.z > 0.75) continue;
        float rad = cell * (0.12 + 0.38 * sq(hh.z / 0.75));
        float2 ctr = (c + 0.2 + 0.6 * hh.xy) * cell;
        float2 l = (uv - ctr) / rad;
        // worn, slightly polygonal rims rather than perfect circles
        float wob = noise3(float3(normalize(l + 1e-5) * 1.8, seed * 3.0 + c.x * 0.37 + c.y));
        float rho = length(l) * (1.0 + 0.14 * (wob - 0.5));
        if (rho > 2.6) continue;
        float k = smoothstep(0.8, 2.5, rad / fp);   // craters near a pixel across fade out
        float fin = D * (rho * rho - 1.0) + RIM, din = 2.0 * D * rho;
        float eo = exp(-(rho - 1.0) * 2.4);
        float fout = RIM * eo, dout = -2.4 * RIM * eo;
        float m = smoothstep(0.9, 1.1, rho);
        float f = mix(fin, fout, m), df = mix(din, dout, m);
        h += k * f * rad;
        g += k * df * l / max(rho, 1e-4);
        if (rho < 1.05) {
            // the rim on the light's side shades the floor below it
            float b1 = dot(l, L1.xy), b2 = dot(l, L2.xy);
            float t1 = -b1 + sqrt(max(b1 * b1 - rho * rho + 1.0, 0.0));
            float t2 = -b2 + sqrt(max(b2 * b2 - rho * rho + 1.0, 0.0));
            float drop = RIM + 0.02 - f;
            float p1 = 0.04 + L1.w * t1, p2 = 0.04 + L2.w * t2;
            sh1 *= mix(1.0, smoothstep(-p1, p1, t1 * L1.z - drop), k);
            sh2 *= mix(1.0, smoothstep(-p2, p2, t2 * L2.z - drop), k);
        }
        // fresh craters: a bright apron streaked with rays
        if (hh.x > 0.86) {
            float ang = atan2(l.y, l.x);
            float streak = 0.5 + 0.8 * smoothstep(0.45, 0.8, noise3(float3(cos(ang) * 6.0, sin(ang) * 6.0, seed + c.x)));
            alb += 0.45 * k * exp(-max(rho - 1.0, 0.0) * 1.1) * smoothstep(0.6, 1.0, rho) * streak;
        }
    }
}

// The far rims standing along the horizon, radians above the smooth horizon, by azimuth.
static float ecSkyline(float az) {
    float2 c = float2(cos(az), sin(az));
    float mesa = smoothstep(0.35, 0.75, fbm(float3(c * 2.6, 1.7)));
    return 0.003 + 0.016 * mesa + 0.006 * fbm(float3(c * 11.0, 5.0)) + 0.002 * noise3(float3(c * 40.0, 2.0));
}

fragment float4 eclipseFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float W = F.camRight.w, H = F.camUp.w;
    float T = F.time;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5)) * F.screenScale;
    float th = S.i.x, pitch = S.i.y;
    float3 rc = normalize(float3(q * th, 1.0));
    float cp = cos(pitch), sp = sin(pitch);
    float3 rd = float3(rc.x, rc.y * cp + rc.z * sp, -rc.y * sp + rc.z * cp);
    float pixA = 2.0 * th * F.screenScale / H;       // radians per pixel, near the middle

    float3 sunD = S.a.xyz;
    float ts = S.a.w;
    float3 sx = normalize(cross(float3(0.0, 1.0, 0.0), sunD)), sy = cross(sunD, sx);
    float2 o = S.b.xy;
    float Ro = S.b.z;
    float eCam = S.b.w, gain = S.j.z, logE = S.j.w;
    float adapt = gain / 2.5;                          // how far the eye has opened since full sun
    float coronaVis = smoothstep(-2.4, -4.3, logE);
    float starVis = smoothstep(-2.6, -4.5, logE);
    float glareAmp = smoothstep(-5.6, -4.0, logE) * (0.6 + 2.4 * smoothstep(-3.5, 0.0, logE));
    float3 sunCol = float3(1.0, 0.94, 0.85);

    // ---- sky ----
    float sd = dot(rd, sunD);
    float2 d = float2(dot(rd, sx), dot(rd, sy)) / max(sd, 1e-3) / ts;
    if (sd <= 0.0) d = float2(1e4);
    float r = length(d);
    float px = pixA / ts;                              // one pixel in sun radii
    float3 col = SKY(p, octDecode(dirTex.read(p).xy), false) * starVis;

    // the planet: a banded giant, lit by the sun from beside it, so a crescent
    float tp = S.f.w;
    float pHit = 0.0;
    float3 planetCol = S.g.rgb;
    if (tp > 0.0) {
        float3 Pc = S.f.xyz;
        float Rp = tp / sqrt(1.0 + tp * tp);
        float2 ps = sphereSpan(-Pc, rd, Rp);
        float bp = length(cross(rd, Pc));               // ray's closest approach to its center
        if (ps.x < ps.y && ps.x > 0.0) {
            float3 N = normalize(rd * ps.x - Pc);
            float3 ax = normalize(float3(-0.25, 1.0, -0.1));
            float lat = dot(N, ax);
            float warp = fbm(N * 3.0 + 2.0) - 0.5;
            float lt = lat + warp * 0.06;
            float bands = 0.5 + 0.5 * sin(lt * 26.0 + 2.0 * sin(lt * 7.0 + 1.0));
            float fine = fbmLOD(float3(N.xz * 18.0, lt * 60.0), pixA / Rp * 18.0);
            float3 alb = planetCol * (0.62 + 0.5 * bands + 0.25 * (fine - 0.5));
            alb = mix(alb, alb * float3(1.15, 0.95, 0.8), smoothstep(0.6, 0.85, bands) * 0.25);   // warmer light zones
            float mu = saturate(dot(N, -rd));
            float nl = dot(N, sunD);
            float day = smoothstep(-0.06, 0.25, nl) * (0.35 + 0.65 * saturate(nl));
            float3 pc = alb * day * 1.1 * (0.5 + 0.5 * pow(mu, 0.4)) * pow(adapt, 0.2);
            // a thin haze lights up along the sunward limb
            pc += mix(planetCol, float3(0.7, 0.85, 1.0), 0.5) * pow(1.0 - mu, 3.0) * smoothstep(-0.2, 0.4, nl) * 0.6;
            // the night side, faintly lit by our moon
            pc += alb * 0.004 * adapt * (1.0 - day);
            pHit = smoothstep(Rp + pixA * 1.0, Rp - pixA * 1.0, bp);
            col = mix(col, pc, pHit);
        } else {
            // haze glowing just off the sunward limb
            float off = (bp - Rp) / Rp;
            float3 Nl = normalize(rd * dot(rd, Pc) - Pc);
            col += mix(planetCol, float3(0.6, 0.8, 1.0), 0.5) * exp(-max(off, 0.0) / 0.012) * smoothstep(-0.2, 0.5, dot(Nl, sunD)) * 0.25;
        }
    }

    float3 sky = float3(0.0);
    if (r < 1.0 + 20.0 * S.c.w) {   // well past where the corona has faded out
        // corona, behind everything round the sun
        float3 cor = ecCorona(d, max(r, 1.0), T, S.c.w, S.c.rgb) * S.g.w;
        sky += cor * mix(0.05, 1.0, coronaVis) * smoothstep(1.0 - px, 1.0 + px, r);

        float h = r - 1.0;
        float ang = atan2(d.y, d.x);
        float3 promCol = S.d.rgb;
        float promVis = mix(0.1, 1.0, sqrt(coronaVis));
        // the chromosphere: a thin pink shell, a fringe of spicules over it
        if (h > -px && h < 0.08) {
            float2 cs = float2(cos(ang), sin(ang));
            float jets = smoothstep(0.35, 0.8, noise3(float3(cs * 140.0, h / 0.01 - T * 0.05)));
            float top = 0.012 + 0.012 * noise3(float3(cs * 60.0, T * 0.02));
            float chrom = exp(-max(h, 0.0) / 0.006) * 0.8 + smoothstep(top, top * 0.3, h) * jets * 0.6;
            sky += promCol * chrom * smoothstep(-px, px, h) * 2.5 * promVis;
        }
        // prominences round the limb, standing for a while and slowly changing
        float amt = S.d.w;
        if (amt > 0.0 && h < 0.35 && h > -px) {
            float prom = 0.0;
            for (int i = 0; i < 7; i++) {
                float fi = float(i);
                float life = 400.0 + 300.0 * hash13(float3(fi, 11.0, 2.0));
                float cyc = T / life + hash13(float3(fi, 12.0, 2.0));
                float gen = floor(cyc), age = fract(cyc);
                if (hash13(float3(fi, gen, 19.0)) > amt * 0.6) continue;
                float a0 = 6.2831853 * hash13(float3(fi, gen, 13.0));
                float Lp = 0.09 + 0.13 * hash13(float3(fi, gen, 14.0));
                float Hp = 0.1 + 0.16 * hash13(float3(fi, gen, 15.0));
                float s = wrapPi(ang - a0);
                if (abs(s) > Lp * 1.4 || h > Hp * 1.7) continue;
                float vis = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.75, 1.0, age));
                prom += prominence(float2(s, h), Lp, Hp, hash13(float3(fi, gen, 16.0)), fi * 5.3 + gen * 1.7, T, px) * vis;
            }
            // a soft glow round each, the cool plasma's own haze
            sky += promCol * prom * (4.0 + amt) * promVis;
        }

        // eruption: a big prominence lifts off, swelling into a loop of twisted threads, ahead of a
        // faint expanding bubble of corona (a coronal mass ejection)
        if (S.h.z > 0.0) {
            float ea = S.h.x, fp = S.h.y, seed = S.h.w;
            float2 L = float2(wrapPi(ang - ea), h);
            float rise = max(fp - 0.12, 0.0) / 0.88;
            float Hh = 0.14 + 0.05 * smoothstep(0.0, 0.12, fp) + 2.4 * pow(rise, 1.6);
            float Wp = 0.16 + 0.06 * smoothstep(0.1, 0.5, fp) + 0.3 * rise;
            if (abs(L.x) < Wp * 1.5 + Hh * 0.4 + 0.08 && L.y < Hh * 1.5 + 0.08 && L.y > -px) {
                float2 Lw = L + noise2(float3(L * 2.0 / (0.15 + Hh), seed + T * 0.01)) * (0.01 + 0.18 * Hh) * smoothstep(0.0, 0.3, L.y / Hh);
                float2 en = Lw / float2(Wp, Hh);
                float e = length(en);
                float uu = atan2(max(en.y, 0.0), en.x);
                float spacing = 0.006 * (1.0 + 5.0 * rise);
                float rope = smoothstep(0.45 - 0.2 * rise, 0.72 - 0.2 * rise, e) * smoothstep(1.15 + 0.1 * rise, 0.9 - 0.1 * rise, e);
                float thr = threads(e * Hh, uu * 6.0 - T * 0.03, spacing, px, seed);
                float twist = threads(e * Hh + 0.3 * Hh * sin(uu * 3.0), uu * 3.0, spacing * 1.5, px, seed + 9.0);
                float wisps = smoothstep(0.3 + 0.15 * rise, 0.62, fbm(float3(Lw / (0.1 + Hh) * 2.0, seed)));
                float loose = smoothstep(0.0, 0.4, rise);
                float em = rope * mix(0.6 * thr + 0.4 * twist, 1.0, 0.5 * loose) * mix(1.0, wisps, smoothstep(0.2, 0.6, fp));
                em *= smoothstep(0.0, 0.015, L.y) * 1.6 / (1.0 + 2.5 * Hh);
                float hang = 1.0 - smoothstep(0.08, 0.3, fp);
                if (hang > 0.0) em += prominence(L, Wp * 0.9, Hh * 0.95, 0.4, seed, T, px) * hang * 1.5;
                if (fp > 0.35 && L.y < 0.2) {
                    float lx = abs(L.x) - Wp * 0.8;
                    em += exp(-lx * lx / 8e-4) * threads(L.x, L.y / 0.015 + T * 0.4, 0.006, px, seed + 2.0)
                          * smoothstep(0.2, 0.04, L.y) * smoothstep(0.35, 0.55, fp) * 0.6;
                }
                sky += mix(promCol, float3(1.0, 0.8, 0.85), 0.15 * loose) * em * S.h.z * promVis * 4.0;
            }
            // the bubble of corona it pushes out: a soft bright front over a darker cavity
            float2 nrm = float2(cos(ea), sin(ea)), tg = float2(-nrm.y, nrm.x);
            float2 Lc = float2(dot(d, tg), dot(d, nrm));
            float rF = 1.1 + 4.5 * pow(max(fp - 0.08, 0.0), 1.15);
            float hw = 0.42;
            float sw = sin(hw);
            float rB = rF / (1.0 + sw), rb = rB * sw;
            if (Lc.y > 0.0 && abs(Lc.x) < rb * 1.6 + 0.2 && Lc.y < rF + rb * 0.6) {
                float2 Lw = Lc + noise2(float3(Lc * 1.5 / rb, seed + T * 0.01)) * rb * 0.18;
                float2 rel = Lw - float2(0.0, rB);
                float rr = length(rel);
                float phi = atan2(rel.x, rel.y);
                float dB = rr - rb * (1.0 + 0.15 * (noise3(float3(rel / max(rr, 1e-4) * 1.3, seed)) - 0.5));
                float thk = 0.4 * rb;
                float shell = exp(-sq(max(dB, 0.0) / (thk * 0.8))) * exp(min(dB, 0.0) / thk);
                float lead = 0.25 + 0.75 * smoothstep(-0.6, 0.9, cos(phi));
                float fib = mix(1.0, threads(dB + 0.1 * rb * noise3(float3(phi * 2.0, seed, 3.0)), phi * 4.0, 0.07 * rb, px, seed), 0.25);
                float clumps = 0.65 + 0.5 * smoothstep(0.25, 0.75, noise3(float3(Lw * 2.5 / rb, seed + 1.0)));
                float cav = smoothstep(0.0, -0.4 * rb, dB) * smoothstep(0.0, 0.1, fp);
                float fade = smoothstep(0.08, 0.2, fp) / (0.4 + 0.6 * rF);
                sky *= 1.0 - 0.3 * cav * S.h.z;
                sky += mix(float3(1.0, 0.97, 0.94), S.c.rgb, 0.4) * shell * lead * fib * clumps * fade * S.h.z * 0.6 * S.g.w * mix(0.1, 1.0, coronaVis);
            }
        }

        // the photosphere, where the occluder leaves it uncovered
        float limbD = 1.0 - 0.55 * (1.0 - sqrt(max(1.0 - r * r, 0.0)));
        sky += sunCol * gain * 14.0 * limbD * smoothstep(1.0 + px, 1.0 - px, r);

        // the occluder: its night side faces us, dimly lit by the planet
        float2 dv = d - o;
        float ro = length(dv);
        float phiO = atan2(dv.y, dv.x);
        float Rl = Ro + EC_MOUNT * ecLimb(phiO);
        float cover = smoothstep(Rl + px, Rl - px, ro);
        if (cover > 0.0) {
            float z = sqrt(max(1.0 - sq(ro / Ro), 0.0));
            float3 N = float3(dv / Ro, z);
            float shine = saturate(dot(N, normalize(float3(-0.9, -0.1, 0.4)))) * (0.6 + 0.5 * fbm(float3(dv * 3.0, 4.0)));
            float3 night = planetCol * shine * 0.0035 * adapt * S.i.w * step(0.0, tp);
            sky = mix(sky, night, cover);
            col *= 1.0 - cover;
        }

        // Baily's beads: the last sunlight shining through the limb's valleys, each with a glow
        if (length(o) < 1.0 && abs(ro - Ro) < 0.5 && r < 1.5) {
            float glow = 0.0;
            for (int k = -6; k <= 6; k++) {
                float a = phiO + float(k) * 0.022;
                float2 u2 = float2(cos(a), sin(a));
                float b = dot(o, u2);
                float ts2 = -b + sqrt(max(b * b - dot(o, o) + 1.0, 0.0));
                float Rk = Ro + EC_MOUNT * ecLimb(a);
                float gap = ts2 - Rk;
                if (gap <= 0.0) continue;
                float2 pt = o + u2 * (Rk + gap * 0.5);
                float dist2 = length_squared(d - pt);
                glow += saturate(gap / 0.012) * (exp(-dist2 / 0.0012) * 3.0 + exp(-dist2 / 0.015) * 0.6);
            }
            sky += sunCol * glow * smoothstep(-5.6, -4.0, logE);
        }
    }
    col += sky * (1.0 - pHit);

    // ---- the moon we stand on ----
    if (S.e.w > 0.5) {
        float3 Cm = float3(0.0, -(1.0 + EC_HEIGHT), 0.0);
        float2 gs = sphereSpan(-Cm, rd, 1.0);
        float dip = acos(1.0 / (1.0 + EC_HEIGHT));
        float el = asin(clamp(rd.y, -1.0, 1.0));
        float az = atan2(rd.x, rd.z);
        float sky_top = -dip + ecSkyline(az);
        bool hitG = gs.x < gs.y && gs.x > 0.0;
        float edgeAA = pixA * 0.8;
        float ridge = hitG ? 0.0 : smoothstep(sky_top + edgeAA, sky_top - edgeAA, el);
        float3 gcol = S.e.rgb;
        // light: the sun as uncovered from each spot (the occluder's shadow has a sharp-cored
        // umbra drifting over the ground), the planet's crescent, and the corona's faint glow
        float3 Lpl = normalize(S.f.xyz + 0.6 * tp * normalize(sunD - S.f.xyz * dot(sunD, S.f.xyz)));
        float plI = tp > 0.0 ? S.i.w * 0.6 * adapt : 0.0;
        float coI = 0.006 * S.g.w * adapt;
        float resid = max(eCam - ecUncovered(length(o), Ro), 0.0);
        float3 plCol = mix(planetCol, float3(0.8, 0.9, 1.0), 0.25);
        float3 coCol = mix(float3(1.0, 0.97, 0.94), S.c.rgb, 0.4);
        if (hitG) {
            float t = gs.x;
            float3 G = rd * t;
            float3 Ns = normalize(G - Cm);
            float mu = saturate(dot(Ns, -rd));
            float fp = pixA * t / max(mu, 0.04);
            float2 uv = G.xz;
            // the lights' horizontal directions and elevations, with their penumbrae
            float2 sh2 = normalize(sunD.xz + 1e-5), ph2 = normalize(Lpl.xz + 1e-5);
            float4 L1 = float4(sh2, sunD.y / length(sunD.xz), ts * 0.7);
            float4 L2 = float4(ph2, max(Lpl.y, 0.02) / length(Lpl.xz), tp * 0.5);
            float hgt = 0.0, sS = 1.0, sP = 1.0, bright = 0.0;
            float2 grad = float2(0.0);
            ecCraters(uv, 0.05, 1.0, fp, L1, L2, hgt, grad, sS, sP, bright);
            ecCraters(uv, 0.016, 2.0, fp, L1, L2, hgt, grad, sS, sP, bright);
            ecCraters(uv, 0.0055, 3.0, fp, L1, L2, hgt, grad, sS, sP, bright);
            ecCraters(uv, 0.0018, 4.0, fp, L1, L2, hgt, grad, sS, sP, bright);
            // gentle undulation and grit
            float e2 = 0.0004;
            float n0 = fbmLOD(float3(uv * 90.0, 1.0), fp * 90.0);
            float nx = fbmLOD(float3((uv + float2(e2, 0.0)) * 90.0, 1.0), fp * 90.0);
            float nz = fbmLOD(float3((uv + float2(0.0, e2)) * 90.0, 1.0), fp * 90.0);
            grad += float2(nx - n0, nz - n0) / e2 * 0.0012;
            float3 ex = normalize(float3(1.0, 0.0, 0.0) - Ns * Ns.x), ez = normalize(float3(0.0, 0.0, 1.0) - Ns * Ns.z);
            float3 N = normalize(Ns - grad.x * ex - grad.y * ez);
            float alb = (0.72 + 0.5 * (n0 - 0.5) + 0.35 * (fbmLOD(float3(uv * 14.0, 7.0), fp * 14.0) - 0.5)) * (1.0 + bright);
            alb *= 0.85 + 0.3 * noise3(float3(uv * 900.0, 3.0)) * (1.0 - smoothstep(0.3, 0.8, fp * 900.0));
            float muV = saturate(dot(N, -rd));
            // regolith: between Lambert and the flat look of the Moon's own surface
            float nlS = dot(N, sunD), nlP = dot(N, Lpl);
            float ls = saturate(nlS) * (0.55 + 0.9 / (saturate(nlS) + muV + 0.3));
            float lp = saturate(nlP) * (0.55 + 0.9 / (saturate(nlP) + muV + 0.3));
            float2 oG = o - float2(dot(G, sx), dot(G, sy)) * S.i.z;
            float frac = max(ecUncovered(length(oG), Ro) + resid, 0.0);
            // light bounced off the sunlit plains around fills the shadows a little
            float3 light = sunCol * gain * frac * (ls * sS * 0.75 + 0.07 * (0.6 + 0.4 * Ns.y))
                         + plCol * plI * lp * sP
                         + coCol * coI * (0.4 + 0.6 * saturate(nlS + 0.3));
            col = gcol * alb * light;
        } else if (ridge > 0.0) {
            // the far rims: their faces toward us in shadow, crests catching the light
            float3 G = float3(sin(az), 0.0, cos(az)) * sqrt(2.0 * EC_HEIGHT) + float3(0.0, -EC_HEIGHT, 0.0);
            float2 oG = o - float2(dot(G, sx), dot(G, sy)) * S.i.z;
            float frac = max(ecUncovered(length(oG), Ro) + resid, 0.0);
            float below = sky_top - el;
            float crest = exp(-below / (pixA * 3.0 + 0.001));
            float face = 0.12 + 0.2 * fbm(float3(az * 40.0, below * 400.0, 3.0));
            float sideP = saturate(dot(normalize(float3(rd.x, 0.0, rd.z)), -normalize(float3(Lpl.x, 0.0, Lpl.z))) * -1.0 + 0.4);
            float3 light = sunCol * gain * frac * (face * 0.25 + crest * 0.9) * smoothstep(-0.1, 0.4, dot(normalize(float3(rd.x, 0.0, rd.z)), normalize(float3(sunD.x, 0.0, sunD.z))))
                         + plCol * plI * (0.15 + 0.35 * sideP) + coCol * coI * 0.5;
            float3 rc2 = gcol * 0.8 * light;
            col = mix(col, rc2, ridge);
        }
    }

    // glare: the uncovered sun, or at the end the diamond, scatters light in the eye and lens
    if (glareAmp > 0.0 && sd > 0.0) {
        float2 dg = d - S.j.xy;
        float g2 = dot(dg, dg);
        // with only a bead or two left the light is one point: a tight, hot core (the diamond)
        float size = 0.4 + 0.6 * smoothstep(-4.0, 0.0, logE);
        float diamond = 1.0 - smoothstep(-3.6, -2.4, logE);
        float gl = 0.8 * exp(-g2 / (0.05 * size)) + 0.1 / (1.0 + g2 / (0.3 * size)) + 0.004 / (1.0 + g2 / (5.0 * size));
        float dg2 = diamond * smoothstep(-5.6, -4.0, logE) * (4.0 * exp(-g2 / 0.03) + 1.2 * exp(-g2 / 0.25) + 0.25 / (1.0 + g2 / 1.2));
        col += sunCol * (gl * glareAmp + dg2);
    }
    return finalize(col, p, F);
}
"""
}
