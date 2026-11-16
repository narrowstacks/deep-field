extension ShaderSource {
    static let protoDisk = """
// ---------- per-frame: protoplanetary disk ----------
// A young star in its disk of gas and dust. Two kinds of dust: small grains float high, spread
// through a flaring layer whose surface catches the starlight at a grazing angle (scattered
// light) and soaks up light everywhere below it (the dark midplane lane); millimeter grains settle
// into a thin midplane sheet and glow with their own warmth (what ALMA sees). Forming planets
// clear gaps; the starlight then strikes the gaps' outer walls head on, so those rims shine and
// the gaps' inner sides lie in shadow. The small grains are marched as a volume along each ray;
// the thin sheet is taken in one piece where the ray crosses it.
// The scene uses the world frame: the star at the origin, the camera at F.camPos.
//
// S.a = disk axis (unit, toward our side), outer radius R
// S.b = in-plane reference direction, thickness (scale height over radius at R)
// S.c = dust (millimeter glow) color, gap width
// S.d = lit surface (scattered light) color, how much the small grains hide the glow (0..1)
// S.e = star color, star brightness (with any outburst)
// S.f = jet color, jets on
// S.g = gap count, seed, angular speed at R (rad/s), longest texture cycle (s)
// S.h = outburst age (s, < 0 none), light echo speed (units/s), outburst amplitude
// S.i = scattered light weight, glow weight

constant int PD_GAPS = 7;

// An accretion outburst's light curve a seconds in: a soft-edged pulse (so the echo it sends
// across the disk has no hard front), then a long faint tail. Mirrors SceneParams.protoOutburst.
static float pdOutburst(float a) {
    return a <= 0.0 ? 0.0 : exp(-sq((a - 9.0) / 5.0)) + 0.12 * smoothstep(0.0, 12.0, a) * exp(-a / 45.0);
}

// Gap k of n: its radius and half-width, as fractions of R. Spread from the inner disk to near
// the edge, a little irregularly, wider farther out (as in HL Tau).
static float2 pdGap(int k, int n, float gw, float seed) {
    float h = hash13(float3(float(k), float(n), seed));
    float u = (float(k) + 0.5 + 0.45 * (h - 0.5)) / float(n);
    float x = 0.14 + 0.74 * pow(u, 0.9);
    float w = gw * (0.016 + 0.035 * x) * (0.75 + 0.5 * hash13(float3(float(k), seed, 1.7)));
    return float2(x, w);
}

// The gap nearest x = r / R (inverting pdGap's spacing); only it and its neighbours matter.
static int pdNearestGap(float x, int n) {
    float u = pow(saturate((x - 0.14) / 0.74), 1.0 / 0.9);
    return clamp(int(u * float(n)), 0, n - 1);
}

// x^1.25, which sets how the disk thickens outward (its flaring).
static float pdP125(float x) { return x * sqrt(sqrt(x)); }

// The inner hole the star has cleared: 0 inside, 1 well outside, and its log slope.
static float2 pdCavity(float x) {
    if (x > 0.2) return float2(1.0, 0.0);
    float q = sq(sq(x / 0.07));
    float cav = 1.0 - exp(-q);
    return float2(cav, exp(-q) * 4.0 * q / x / max(cav, 1e-4));
}

// The small grains' column at x = r / R, and d ln(column) / dx, which sets how the lit surface
// rises and falls: a falling power law with a soft outer taper, and a dip at each gap.
static float2 pdGas(float x, int n, thread const float4* gaps) {
    float xs = max(x, 1e-3);
    float2 cav = pdCavity(xs);
    float gas = exp2(-0.8 * log2(xs) - 1.442695 * sq(xs * xs)) * cav.x;
    float dln = -0.8 / xs - 4.0 * xs * xs * xs + cav.y;
    int k0 = pdNearestGap(x, n);
    for (int k = max(k0 - 1, 0); k <= min(k0 + 1, n - 1); k++) {
        float d = (x - gaps[k].x) * gaps[k].w;
        if (abs(d) > 3.5) continue;
        float e = exp(-d * d);
        float keep = 1.0 - 0.8 * e;
        gas *= keep;
        dln += 1.6 * e * d * gaps[k].w / keep;
    }
    return float2(gas, dln);
}

// The millimeter grains' column: swept out of the gaps more completely than the gas, and piled
// up in a bright ring at the pressure bump just outside each gap.
static float pdDust(float x, int n, thread const float4* gaps) {
    float xs = max(x, 1e-3);
    float mm = rsqrt(xs) * exp(-sq(sq(xs / 0.9) * (xs / 0.9))) * pdCavity(xs).x;
    int k0 = pdNearestGap(x, n);
    for (int k = max(k0 - 1, 0); k <= min(k0 + 1, n - 1); k++) {
        float d = (x - gaps[k].x) * gaps[k].w;
        if (abs(d) > 4.0) continue;
        mm *= (1.0 - 0.97 * exp(-0.7 * d * d)) * (1.0 + 1.4 * exp(-sq(d - 1.9) * 1.3));
    }
    return mm;
}

// Rotate p (in the disk plane's 2D coordinates) by angle a.
static float2 pdRot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Clumps and streaks in the dust at in-plane position q (units of R), orbiting at the local
// Kepler speed. Shear winds any pattern up, so two copies run half a cycle apart, each starting
// afresh (at a random turn) while it's faded out. The cycle is a fraction of the local orbit (but
// not too quick), so the fast inner disk doesn't wind its pattern finer than a pixel.
static float pdClumps(float2 q, float x, float T, float om0, float cycMax, float seed) {
    float om = om0 * pow(max(x, 0.05), -1.5);
    float cyc = clamp(1.9 / max(om, 1e-4), 12.0, cycMax);
    float s = 0.0;
    for (int k = 0; k < 2; k++) {
        float ph = T / cyc + 0.5 * float(k);
        float f = fract(ph), w = 1.0 - abs(2.0 * f - 1.0);
        float n = floor(ph);
        float2 r = pdRot(q, -om * f * cyc + 6.2831853 * hash13(float3(n, float(k), seed)));
        float3 p3 = float3(r * 9.0, seed + n * 3.7 + float(k) * 11.0);
        s += w * (0.65 * noise3(p3) + 0.35 * noise3(p3 * 2.3 + 5.0));
    }
    return s;
}

// The spiral wake a planet at (xp, ap) drives in the disk at (x, phi): a density wave trailing
// outside the planet's orbit and leading inside it, along the linear wake shape for a Kepler
// disk (Ogilvie and Lubow), opened up a little so it reads at a glance.
static float pdWake(float x, float phi, float xp, float ap) {
    float u = x / xp, eps = u - 1.0;
    if (abs(eps) > 0.9) return 0.0;
    float shape = (2.0 / 3.0) * pow(u, 1.5) - log(u) - 2.0 / 3.0;
    float dphi = -sign(eps) * shape / 0.12;
    float d = phi - ap - dphi;
    d -= 6.2831853 * floor(d / 6.2831853 + 0.5);
    float width = 0.1 + 0.3 * abs(eps);
    return exp(-sq(d / width)) * exp(-abs(eps) * 2.0);
}

// The dust's clumps and the planets' wakes at disk point X: (clumps 0..1, wake).
static float2 pdTexture(float3 X, float3 ax, float3 e1, float3 e2, float R, int n,
                        thread const float4* gaps, float T, float om0, float cyc, float seed) {
    float2 q = float2(dot(X, e1), dot(X, e2)) / R;
    float x = length(q);
    float tex = pdClumps(q, x, T, om0, cyc, seed);
    float phi = atan2(q.y, q.x), wake = 0.0;
    for (int k = 0; k < PD_GAPS; k++) {
        if (k >= n) break;
        wake += pdWake(x, phi, gaps[k].x, gaps[k].z);
    }
    return float2(tex, wake);
}

// How much brighter the starlight reaching X is during an outburst: the light curve, delayed
// by the extra path the light takes via X on its way to us. Points at equal delay lie on a
// paraboloid round the line of sight, so the echo sweeps the near side first.
static float pdBoost(float3 X, float3 ro, float age, float echoV, float amp) {
    if (age < 0.0) return 1.0;
    float delay = length(X) + length(ro - X) - length(ro);
    return 1.0 + amp * pdOutburst(age - delay / echoV);
}

fragment float4 protoDiskFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = F.time;
    float3 ax = S.a.xyz, e1 = S.b.xyz, e2 = cross(ax, e1);
    float R = S.a.w, hR = S.b.w, gw = S.c.w;
    int n = int(S.g.x);
    float seed = S.g.y, om0 = S.g.z, cyc = S.g.w;
    float age = S.h.x, echoV = S.h.y, amp = S.h.z;
    float kMm = S.d.w, wScat = S.i.x, wTherm = S.i.y;
    float3 colDust = S.c.rgb, colGas = S.d.rgb, colStar = S.e.rgb;
    float pixW = F.pixelAngle * length(ro);
    float tStar = -dot(ro, rd);
    float dStar = length(ro + rd * tStar);
    float3 col = SKY(p, rd, false);

    // the gaps (radius, half-width) and their planets, one in each on a Kepler orbit (angle);
    // find the planet nearest this ray
    float4 gaps[PD_GAPS];
    float tPlanet = 0.0, dPlanet = 1e9;
    for (int k = 0; k < PD_GAPS; k++) {
        if (k >= n) break;
        float2 g = pdGap(k, n, gw, seed);
        float a = 6.2831853 * hash13(float3(float(k), seed, 9.1)) + om0 * pow(g.x, -1.5) * T;
        gaps[k] = float4(g, a, 1.0 / g.y);
        float3 P = R * g.x * (e1 * cos(a) + e2 * sin(a));
        float tk = dot(P - ro, rd);
        float dk = length(ro + rd * tk - P);
        if (dk < dPlanet) { dPlanet = dk; tPlanet = tk; }
    }

    // the jets: where this ray passes closest to the spin axis
    float tJet = 0.0, sJet = 0.0, dJet = 1e9;
    if (S.f.w > 0.0) {
        float b = dot(rd, ax), dd = dot(rd, ro), e = dot(ax, ro);
        float den = max(1.0 - b * b, 1e-4);
        tJet = (b * e - dd) / den;
        sJet = (e - b * dd) / den;
        dJet = length(ro + rd * tJet - ax * sJet);
    }

    // where the ray is inside the disk's bounds: a slab, and a cylinder round the axis
    float Rc = 1.35 * R;
    float Zm = 4.8 * hR * R * pow(1.35, 1.25);
    float zo = dot(ro, ax), zd = dot(rd, ax);
    float t0 = 0.0, t1 = -1.0, span = 0.0;
    {
        float ta = (-Zm - zo) / zd, tb = (Zm - zo) / zd;
        float s0 = abs(zd) < 1e-6 ? -1e9 : min(ta, tb), s1 = abs(zd) < 1e-6 ? 1e9 : max(ta, tb);
        float3 o = ro - ax * zo, d = rd - ax * zd;
        float A = dot(d, d), B = dot(o, d), C = dot(o, o) - Rc * Rc;
        float disc = B * B - A * C;
        if (disc > 0.0 && A > 1e-8) {
            float q = sqrt(disc);
            t0 = max(max(s0, (-B - q) / A), 0.0);
            t1 = min(s1, (-B + q) / A);
        }
        span = t1 - t0;
        // tighter: the disk lies within the double cone |z| < k r round the star
        float k = Zm / Rc;
        float qa = zd * zd - k * k * A, qb = zo * zd - k * k * B, qc = zo * zo - k * k * dot(o, o);
        float qd = qb * qb - qa * qc;
        if (qa > 0.0) {
            if (qd <= 0.0) t1 = -1.0;
            else {
                float sq_ = sqrt(qd);
                t0 = max(t0, (-qb - sq_) / qa);
                t1 = min(t1, (-qb + sq_) / qa);
            }
        } else if (qd > 0.0 && t1 > t0) {
            // inside before the first root and after the second (qa < 0); if the ray starts
            // between them, begin at the second
            float rb = (-qb - sqrt(qd)) / qa;
            float f0 = (qa * t0 + 2.0 * qb) * t0 + qc;
            if (f0 > 0.0) t0 = max(t0, rb);
        }
    }

    // Starlight scattered off the small grains, marched front to back; those grains also block
    // whatever lies behind (Tr). The clumps, wakes and outburst light are looked up once, where
    // the light along this ray mostly came from.
    float Tr = 1.0, acc = 0.0, wSum = 0.0;
    float3 wPos = float3(0.0);
    float trStar = -1.0, trJet = -1.0, trPlanet = -1.0, trMid = -1.0;
    const float kView = 25.0, kStar = 1.5;
    float tMid = abs(zd) > 1e-5 ? -zo / zd : -1.0;      // where the ray crosses the midplane
    if (t1 > t0) {
        // step limits from the looser bounds, which vary smoothly from pixel to pixel
        float dsMin = span / 130.0, dsMax = span / 8.0;
        // jitter the start (against banding), but by no more than a step at the entry point: near
        // the star the ray's path through the disk is short, and a full jitter skipped some of it
        // on some pixels and not others (dark speckle on the star when the disk is thin)
        float3 X0 = ro + rd * t0;
        float z0 = dot(X0, ax);
        float H0 = hR * R * pdP125(max(length(X0 - ax * z0) / R, 0.08));
        float j0 = min(dsMin * 2.0, max(0.45 * H0, 0.8 * (abs(z0) - 4.0 * H0)));
        float t = t0 + j0 * hash13(float3(float(p.x), float(p.y), 7.3));
        for (int i = 0; i < 40; i++) {
            if (t >= t1 || Tr * max(wScat, 0.15) < 0.003) break;
            float3 X = ro + rd * t;
            float z = dot(X, ax);
            float x = length(X - ax * z) / R;
            float H = hR * R * pdP125(max(x, 0.08));   // (no thinner than the march can resolve)
            float zh = abs(z) / H;
            // (finer than the usual floor in the thin inner disk, whose lit skin it would skip)
            float ds = min(clamp(max(0.45 * H, 0.8 * (abs(z) - 4.0 * H)), min(dsMin, 0.4 * H), dsMax), t1 - t);
            if (trStar < 0.0 && t + ds > tStar) trStar = Tr;
            if (trJet < 0.0 && t + ds > tJet) trJet = Tr;
            if (trPlanet < 0.0 && t + ds > tPlanet) trPlanet = Tr;
            if (trMid < 0.0 && t + ds > tMid) trMid = Tr;
            if (zh < 4.8 && x < 1.35) {
                float2 cm = pdGas(x, n, gaps);
                float g = exp(-0.5 * zh * zh);
                float dens = cm.x * g / H * smoothstep(1.34, 0.95, x) * smoothstep(4.8, 3.6, zh);
                // The starlight comes in at a grazing angle alpha to the disk's surface (the
                // height where it's crossed about one optical depth), so it lights only a thin
                // skin, deeper where alpha is steep. The surface rises where the column grows
                // (a gap's outer wall, which shines) and sinks where it thins (the gap's inner
                // side, in shadow).
                float lnc = log(max(10.0 * cm.x, 1.0001));
                float zeta = max(sqrt(2.0 * lnc), 0.6);
                float dzeta = lnc > 0.18 ? cm.y / zeta : 0.0;
                float alpha = (H / R) * (dzeta + 0.25 * zeta / max(x, 0.02));
                float above = g * 2.0 / (zh + sqrt(zh * zh + 2.546));
                float lit = exp(-kStar * cm.x * above / max(alpha, 0.008));
                // small grains throw light forward (Henyey-Greenstein, g = 0.45): the near side
                // is brighter
                float v = 1.2025 - 0.9 * dot(X, -rd) * rsqrt(max(dot(X, X), 1e-6));
                float phase = 0.48 / (v * sqrt(v)) + 0.4;
                float xf = max(x, 0.15);
                float jS = lit * phase * dens * 4.5 * wScat / (xf * sqrt(xf));
                float od = kView * dens * ds, att = exp(-od);
                float w = Tr * jS * ds * (od > 1e-3 ? (1.0 - att) / od : 1.0);
                // (an outburst's light reaches each point late: the light echo)
                acc += age >= 0.0 ? w * pdBoost(X, ro, age, echoV, amp) : w;
                wPos += X * w;
                wSum += w;
                Tr *= att;
            }
            t += ds;
        }
    }
    if (trStar < 0.0) trStar = tStar < t0 || t1 <= t0 ? 1.0 : Tr;
    if (trJet < 0.0) trJet = tJet < t0 || t1 <= t0 ? 1.0 : Tr;
    if (trPlanet < 0.0) trPlanet = tPlanet < t0 || t1 <= t0 ? 1.0 : Tr;
    if (trMid < 0.0) trMid = tMid < t0 || t1 <= t0 ? 1.0 : Tr;
    float3 accS = float3(0.0);
    if (wSum > 1e-6) {
        float3 X = wPos / wSum;
        // the lit surface: warmer near the star, bluer far out
        float x = length(X - ax * dot(X, ax)) / R;
        float3 sc = mix(mix(colStar, colGas, 0.4), colGas, smoothstep(0.08, 0.5, x));
        sc = mix(sc, colGas * float3(0.8, 0.9, 1.25), smoothstep(0.6, 1.2, x));
        float2 tw = pdTexture(X, ax, e1, e2, R, n, gaps, T, om0, cyc, seed);
        accS = sc * acc * (0.55 + 0.9 * tw.x) * (1.0 + 2.5 * tw.y);
    }

    // The millimeter glow: a thin sheet in the midplane, so taken in one piece where the ray
    // crosses it. The small grains hide it as much as the look asks: their column down to the
    // midplane here, and whatever the march found in front.
    float3 accM = float3(0.0);
    float visMid = 1.0;
    if (tMid > 0.0 && wTherm > 0.0) {
        float3 X = ro + rd * tMid;
        float x = length(X) / R;
        if (x < 1.35) {
            float cz = max(abs(zd), 0.06);
            float2 cg = pdGas(x, n, gaps);
            visMid = pow(max(trMid, 1e-6), kMm) * exp(-kMm * kView * cg.x * 1.2533 / max(cz, 0.1));
            // hotter, yellower rings inside; deep red and magenta at the edge
            float3 tc = mix(colDust * float3(1.0, 1.5, 1.9) + float3(0.08, 0.06, 0.0), colDust, smoothstep(0.1, 0.45, x));
            tc = mix(tc, colDust * float3(0.95, 0.45, 1.1), smoothstep(0.5, 1.05, x));
            float glow = pdDust(x, n, gaps) * rsqrt(max(x, 0.04)) * 2.5066 / cz * 0.22 * wTherm;
            float boost = pdBoost(X, ro, age, echoV, amp);
            float2 tw = pdTexture(X, ax, e1, e2, R, n, gaps, T, om0, cyc, seed);
            accM = tc * glow * (0.45 + 1.1 * tw.x) * (1.0 + 1.5 * tw.y)
                 * (1.0 + 0.8 * (boost - 1.0)) * visMid;
        }
    }
    // what hides the star, planets and jets: the small grains, unless the look sees through them
    float vis = saturate(wScat);
    float visStar = mix(pow(max(trStar, 1e-6), kMm), trStar, vis);
    float visJet = mix(pow(max(trJet, 1e-6), kMm), trJet, vis);
    float visPlanet = mix(pow(max(trPlanet, 1e-6), kMm), trPlanet, vis);
    float visBack = mix(pow(max(Tr, 1e-6), kMm) * visMid, Tr, vis);

    // a faint envelope of leftover cloud, lit by the star, behind and around the disk
    float3 pe = (ro + rd * tStar) / R * 1.6 + seed;
    // (an outburst reaches it late, as an echo spreading out through the cloud)
    float env = exp(-dStar / (0.9 * R)) * (0.4 + 0.9 * (0.65 * noise3(pe) + 0.35 * noise3(pe * 2.1 + 3.0)));
    float envBoost = 1.0 + 0.5 * (pdBoost(ro + rd * tStar, ro, age, echoV, amp) - 1.0);
    col += mix(colGas, colDust, 0.35) * env * 0.035 * envBoost;
    col = col * visBack + accS + accM;

    // the jets: thin, slowly widening streams with knots of shocked gas moving outward, and the
    // counter jet showing only where the disk doesn't hide it
    if (S.f.w > 0.0 && tJet > 0.0) {
        float as = abs(sJet), L = 1.3 * R;
        if (as < 1.2 * L) {
            float side = sJet > 0.0 ? 0.0 : 1.0;
            float wj = 0.003 * R + 0.012 * as + pixW * 0.5;
            float base = smoothstep(0.03 * R, 0.15 * R, as) * smoothstep(1.15 * L, 0.5 * L, as);
            float stream = (exp(-sq(dJet / wj)) + 0.25 * exp(-dJet / (3.0 * wj))) * base * 0.12;
            float knots = 0.0;
            for (int k = 0; k < 6; k++) {
                float hk = hash13(float3(float(k), side, seed + 4.0));
                float sk = fract(T / 110.0 + float(k) / 6.0 + 0.12 * hk) * L * 1.15;
                float lk = 0.012 * R + 0.02 * sk;
                float bk = (0.4 + 1.2 * hk) * smoothstep(0.0, 0.15 * L, sk) * smoothstep(1.15 * L, 0.6 * L, sk);
                // a bow shape: brightest at the head, trailing back and widening
                float da = as - sk;
                float along = da > 0.0 ? exp(-sq(da / (0.4 * lk))) : exp(da / lk);
                float wk = wj * 1.6 + 0.4 * lk * saturate(-da / lk + 0.3);
                knots += bk * along * exp(-sq(dJet / wk));
            }
            float3 jc = S.f.rgb;
            float3 jetLight = jc * stream + mix(jc, float3(1.0, 0.85, 0.9) * max(jc.r, 0.5), 0.35) * knots * 0.5;
            col += jetLight * visJet;
        }
    }

    // the planets: small and hot, each glowing in its gap, which shows it from above (edge-on,
    // the disk hides it)
    float pr = max(0.007 * R, pixW * 1.2);
    float3 pc = mix(colDust, float3(1.0, 0.85, 0.6), 0.5);
    float seeThrough = 0.5 * smoothstep(0.2, 0.6, abs(zd));
    col += pc * (exp(-sq(dPlanet / pr)) * 4.0 + exp(-dPlanet / (0.03 * R)) * 0.6) * max(visPlanet, seeThrough);

    // the star: a hot point and a soft glow, dimmed where the disk passes in front
    float core = max(pixW * 0.9, 0.004 * R);
    float sb = S.e.w;
    col += colStar * sb * (exp(-sq(dStar / core)) * 6.0 + exp(-dStar / (0.03 * R)) * 0.5 + exp(-dStar / (0.12 * R)) * 0.08) * visStar;
    return finalize(col, p, F);
}
"""
}
