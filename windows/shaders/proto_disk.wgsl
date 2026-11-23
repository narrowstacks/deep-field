// ---------- per-frame: protoplanetary disk ---------- (ShaderProtoDisk.swift)
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

const PD_GAPS: i32 = 7;

// An accretion outburst's light curve a seconds in: a soft-edged pulse (so the echo it sends
// across the disk has no hard front), then a long faint tail. Mirrors SceneParams.protoOutburst.
fn pdOutburst(a: f32) -> f32 {
    return select(exp(-sq((a - 9.0) / 5.0)) + 0.12 * smoothstep(0.0, 12.0, a) * exp(-a / 45.0), 0.0, a <= 0.0);
}

// Gap k of n: its radius and half-width, as fractions of R. Spread from the inner disk to near
// the edge, a little irregularly, wider farther out (as in HL Tau).
fn pdGap(k: i32, n: i32, gw: f32, seed: f32) -> vec2<f32> {
    let h = hash13(vec3<f32>(f32(k), f32(n), seed));
    let u = (f32(k) + 0.5 + 0.45 * (h - 0.5)) / f32(n);
    let x = 0.14 + 0.74 * pow(max(u, 0.0), 0.9);
    let w = gw * (0.016 + 0.035 * x) * (0.75 + 0.5 * hash13(vec3<f32>(f32(k), seed, 1.7)));
    return vec2<f32>(x, w);
}

// The gap nearest x = r / R (inverting pdGap's spacing); only it and its neighbours matter.
fn pdNearestGap(x: f32, n: i32) -> i32 {
    let u = pow(saturate((x - 0.14) / 0.74), 1.0 / 0.9);
    return clamp(i32(u * f32(n)), 0, n - 1);
}

// x^1.25, which sets how the disk thickens outward (its flaring).
fn pdP125(x: f32) -> f32 { return x * sqrt(sqrt(x)); }

// The inner hole the star has cleared: 0 inside, 1 well outside, and its log slope.
fn pdCavity(x: f32) -> vec2<f32> {
    if (x > 0.2) { return vec2<f32>(1.0, 0.0); }
    let q = sq(sq(x / 0.07));
    let cav = 1.0 - exp(-q);
    return vec2<f32>(cav, exp(-q) * 4.0 * q / x / max(cav, 1e-4));
}

// The small grains' column at x = r / R, and d ln(column) / dx, which sets how the lit surface
// rises and falls: a falling power law with a soft outer taper, and a dip at each gap.
fn pdGas(x: f32, n: i32, gaps: ptr<function, array<vec4<f32>, 7>>) -> vec2<f32> {
    let xs = max(x, 1e-3);
    let cav = pdCavity(xs);
    var gas = exp2(-0.8 * log2(xs) - 1.442695 * sq(xs * xs)) * cav.x;
    var dln = -0.8 / xs - 4.0 * xs * xs * xs + cav.y;
    let k0 = pdNearestGap(x, n);
    for (var k = max(k0 - 1, 0); k <= min(k0 + 1, n - 1); k++) {
        let gk = (*gaps)[k];
        let d = (x - gk.x) * gk.w;
        if (abs(d) > 3.5) { continue; }
        let e = exp(-d * d);
        let keep = 1.0 - 0.8 * e;
        gas *= keep;
        dln += 1.6 * e * d * gk.w / keep;
    }
    return vec2<f32>(gas, dln);
}

// The millimeter grains' column: swept out of the gaps more completely than the gas, and piled
// up in a bright ring at the pressure bump just outside each gap.
fn pdDust(x: f32, n: i32, gaps: ptr<function, array<vec4<f32>, 7>>) -> f32 {
    let xs = max(x, 1e-3);
    var mm = inverseSqrt(xs) * exp(-sq(sq(xs / 0.9) * (xs / 0.9))) * pdCavity(xs).x;
    let k0 = pdNearestGap(x, n);
    for (var k = max(k0 - 1, 0); k <= min(k0 + 1, n - 1); k++) {
        let gk = (*gaps)[k];
        let d = (x - gk.x) * gk.w;
        if (abs(d) > 4.0) { continue; }
        mm *= (1.0 - 0.97 * exp(-0.7 * d * d)) * (1.0 + 1.4 * exp(-sq(d - 1.9) * 1.3));
    }
    return mm;
}

// Rotate p (in the disk plane's 2D coordinates) by angle a.
fn pdRot(p: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Clumps and streaks in the dust at in-plane position q (units of R), orbiting at the local
// Kepler speed. Shear winds any pattern up, so two copies run half a cycle apart, each starting
// afresh (at a random turn) while it's faded out. The cycle is a fraction of the local orbit (but
// not too quick), so the fast inner disk doesn't wind its pattern finer than a pixel.
fn pdClumps(q: vec2<f32>, x: f32, T: f32, om0: f32, cycMax: f32, seed: f32) -> f32 {
    let om = om0 * pow(max(x, 0.05), -1.5);
    let cyc = clamp(1.9 / max(om, 1e-4), 12.0, cycMax);
    var s = 0.0;
    for (var k = 0; k < 2; k++) {
        let ph = T / cyc + 0.5 * f32(k);
        let f = fract(ph);
        let w = 1.0 - abs(2.0 * f - 1.0);
        let n = floor(ph);
        let r = pdRot(q, -om * f * cyc + 6.2831853 * hash13(vec3<f32>(n, f32(k), seed)));
        let p3 = vec3<f32>(r * 9.0, seed + n * 3.7 + f32(k) * 11.0);
        s += w * (0.65 * noise3(p3) + 0.35 * noise3(p3 * 2.3 + 5.0));
    }
    return s;
}

// The spiral wake a planet at (xp, ap) drives in the disk at (x, phi): a density wave trailing
// outside the planet's orbit and leading inside it, along the linear wake shape for a Kepler
// disk (Ogilvie and Lubow), opened up a little so it reads at a glance.
fn pdWake(x: f32, phi: f32, xp: f32, ap: f32) -> f32 {
    let u = x / xp;
    let eps = u - 1.0;
    if (abs(eps) > 0.9) { return 0.0; }
    let shape = (2.0 / 3.0) * pow(u, 1.5) - log(u) - 2.0 / 3.0;
    let dphi = -sign(eps) * shape / 0.12;
    var d = phi - ap - dphi;
    d -= 6.2831853 * floor(d / 6.2831853 + 0.5);
    let width = 0.1 + 0.3 * abs(eps);
    return exp(-sq(d / width)) * exp(-abs(eps) * 2.0);
}

// The dust's clumps and the planets' wakes at disk point X: (clumps 0..1, wake).
fn pdTexture(X: vec3<f32>, ax: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, R: f32, n: i32,
             gaps: ptr<function, array<vec4<f32>, 7>>, T: f32, om0: f32, cyc: f32, seed: f32) -> vec2<f32> {
    let q = vec2<f32>(dot(X, e1), dot(X, e2)) / R;
    let x = length(q);
    let tex = pdClumps(q, x, T, om0, cyc, seed);
    let phi = atan2(q.y, q.x);
    var wake = 0.0;
    for (var k = 0; k < PD_GAPS; k++) {
        if (k >= n) { break; }
        wake += pdWake(x, phi, (*gaps)[k].x, (*gaps)[k].z);
    }
    return vec2<f32>(tex, wake);
}

// How much brighter the starlight reaching X is during an outburst: the light curve, delayed
// by the extra path the light takes via X on its way to us. Points at equal delay lie on a
// paraboloid round the line of sight, so the echo sweeps the near side first.
fn pdBoost(X: vec3<f32>, ro: vec3<f32>, age: f32, echoV: f32, amp: f32) -> f32 {
    if (age < 0.0) { return 1.0; }
    let delay = length(X) + length(ro - X) - length(ro);
    return 1.0 + amp * pdOutburst(age - delay / echoV);
}

@fragment
fn protoDiskFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    let T = F.time;
    let ax = S.a.xyz;
    let e1 = S.b.xyz;
    let e2 = cross(ax, e1);
    let R = S.a.w;
    let hR = S.b.w;
    let gw = S.c.w;
    let n = i32(S.g.x);
    let seed = S.g.y;
    let om0 = S.g.z;
    let cyc = S.g.w;
    let age = S.h.x;
    let echoV = S.h.y;
    let amp = S.h.z;
    let kMm = S.d.w;
    let wScat = S.i.x;
    let wTherm = S.i.y;
    let colDust = S.c.rgb;
    let colGas = S.d.rgb;
    let colStar = S.e.rgb;
    let pixW = F.pixelAngle * length(ro);
    let tStar = -dot(ro, rd);
    let dStar = length(ro + rd * tStar);
    var col = SKY(p, rd, false);

    // the gaps (radius, half-width) and their planets, one in each on a Kepler orbit (angle);
    // find the planet nearest this ray
    var gaps: array<vec4<f32>, 7>;
    var tPlanet = 0.0;
    var dPlanet = 1e9;
    for (var k = 0; k < PD_GAPS; k++) {
        if (k >= n) { break; }
        let g = pdGap(k, n, gw, seed);
        let a = 6.2831853 * hash13(vec3<f32>(f32(k), seed, 9.1)) + om0 * pow(g.x, -1.5) * T;
        gaps[k] = vec4<f32>(g, a, 1.0 / g.y);
        let P = R * g.x * (e1 * cos(a) + e2 * sin(a));
        let tk = dot(P - ro, rd);
        let dk = length(ro + rd * tk - P);
        if (dk < dPlanet) { dPlanet = dk; tPlanet = tk; }
    }

    // the jets: where this ray passes closest to the spin axis
    var tJet = 0.0;
    var sJet = 0.0;
    var dJet = 1e9;
    if (S.f.w > 0.0) {
        let b = dot(rd, ax);
        let dd = dot(rd, ro);
        let e = dot(ax, ro);
        let den = max(1.0 - b * b, 1e-4);
        tJet = (b * e - dd) / den;
        sJet = (e - b * dd) / den;
        dJet = length(ro + rd * tJet - ax * sJet);
    }

    // where the ray is inside the disk's bounds: a slab, and a cylinder round the axis
    let Rc = 1.35 * R;
    let Zm = 4.8 * hR * R * pow(1.35, 1.25);
    let zo = dot(ro, ax);
    let zd = dot(rd, ax);
    var t0 = 0.0;
    var t1 = -1.0;
    var span = 0.0;
    {
        let ta = (-Zm - zo) / zd;
        let tb = (Zm - zo) / zd;
        let s0 = select(min(ta, tb), -1e9, abs(zd) < 1e-6);
        let s1 = select(max(ta, tb), 1e9, abs(zd) < 1e-6);
        let o = ro - ax * zo;
        let d = rd - ax * zd;
        let A = dot(d, d);
        let B = dot(o, d);
        let C = dot(o, o) - Rc * Rc;
        let disc = B * B - A * C;
        if (disc > 0.0 && A > 1e-8) {
            let q = sqrt(disc);
            t0 = max(max(s0, (-B - q) / A), 0.0);
            t1 = min(s1, (-B + q) / A);
        }
        span = t1 - t0;
        // tighter: the disk lies within the double cone |z| < k r round the star
        let k = Zm / Rc;
        let qa = zd * zd - k * k * A;
        let qb = zo * zd - k * k * B;
        let qc = zo * zo - k * k * dot(o, o);
        let qd = qb * qb - qa * qc;
        if (qa > 0.0) {
            if (qd <= 0.0) {
                t1 = -1.0;
            } else {
                let sq_ = sqrt(qd);
                t0 = max(t0, (-qb - sq_) / qa);
                t1 = min(t1, (-qb + sq_) / qa);
            }
        } else if (qd > 0.0 && t1 > t0) {
            // inside before the first root and after the second (qa < 0); if the ray starts
            // between them, begin at the second
            let rb = (-qb - sqrt(qd)) / qa;
            let f0 = (qa * t0 + 2.0 * qb) * t0 + qc;
            if (f0 > 0.0) { t0 = max(t0, rb); }
        }
    }

    // Starlight scattered off the small grains, marched front to back; those grains also block
    // whatever lies behind (Tr). The clumps, wakes and outburst light are looked up once, where
    // the light along this ray mostly came from.
    var Tr = 1.0;
    var acc = 0.0;
    var wSum = 0.0;
    var wPos = vec3<f32>(0.0);
    var trStar = -1.0;
    var trJet = -1.0;
    var trPlanet = -1.0;
    var trMid = -1.0;
    const kView = 25.0;
    const kStar = 1.5;
    let tMid = select(-1.0, -zo / zd, abs(zd) > 1e-5);      // where the ray crosses the midplane
    if (t1 > t0) {
        // step limits from the looser bounds, which vary smoothly from pixel to pixel
        let dsMin = span / 130.0;
        let dsMax = span / 8.0;
        // jitter the start (against banding), but by no more than a step at the entry point: near
        // the star the ray's path through the disk is short, and a full jitter skipped some of it
        // on some pixels and not others (dark speckle on the star when the disk is thin)
        let X0 = ro + rd * t0;
        let z0 = dot(X0, ax);
        let H0 = hR * R * pdP125(max(length(X0 - ax * z0) / R, 0.08));
        let j0 = min(dsMin * 2.0, max(0.45 * H0, 0.8 * (abs(z0) - 4.0 * H0)));
        var t = t0 + j0 * hash13(vec3<f32>(f32(p.x), f32(p.y), 7.3));
        for (var i = 0; i < 40; i++) {
            if (t >= t1 || Tr * max(wScat, 0.15) < 0.003) { break; }
            let X = ro + rd * t;
            let z = dot(X, ax);
            let x = length(X - ax * z) / R;
            let H = hR * R * pdP125(max(x, 0.08));   // (no thinner than the march can resolve)
            let zh = abs(z) / H;
            // (finer than the usual floor in the thin inner disk, whose lit skin it would skip)
            let ds = min(clamp(max(0.45 * H, 0.8 * (abs(z) - 4.0 * H)), min(dsMin, 0.4 * H), dsMax), t1 - t);
            if (trStar < 0.0 && t + ds > tStar) { trStar = Tr; }
            if (trJet < 0.0 && t + ds > tJet) { trJet = Tr; }
            if (trPlanet < 0.0 && t + ds > tPlanet) { trPlanet = Tr; }
            if (trMid < 0.0 && t + ds > tMid) { trMid = Tr; }
            if (zh < 4.8 && x < 1.35) {
                let cm = pdGas(x, n, &gaps);
                let g = exp(-0.5 * zh * zh);
                let dens = cm.x * g / H * smoothstep(1.34, 0.95, x) * smoothstep(4.8, 3.6, zh);
                // The starlight comes in at a grazing angle alpha to the disk's surface (the
                // height where it's crossed about one optical depth), so it lights only a thin
                // skin, deeper where alpha is steep. The surface rises where the column grows
                // (a gap's outer wall, which shines) and sinks where it thins (the gap's inner
                // side, in shadow).
                let lnc = log(max(10.0 * cm.x, 1.0001));
                let zeta = max(sqrt(2.0 * lnc), 0.6);
                let dzeta = select(0.0, cm.y / zeta, lnc > 0.18);
                let alpha = (H / R) * (dzeta + 0.25 * zeta / max(x, 0.02));
                let above = g * 2.0 / (zh + sqrt(zh * zh + 2.546));
                let lit = exp(-kStar * cm.x * above / max(alpha, 0.008));
                // small grains throw light forward (Henyey-Greenstein, g = 0.45): the near side
                // is brighter
                let v = 1.2025 - 0.9 * dot(X, -rd) * inverseSqrt(max(dot(X, X), 1e-6));
                let phase = 0.48 / (v * sqrt(v)) + 0.4;
                let xf = max(x, 0.15);
                let jS = lit * phase * dens * 4.5 * wScat / (xf * sqrt(xf));
                let od = kView * dens * ds;
                let att = exp(-od);
                var w = Tr * jS * ds;
                if (od > 1e-3) { w *= (1.0 - att) / od; }
                // (an outburst's light reaches each point late: the light echo)
                if (age >= 0.0) { acc += w * pdBoost(X, ro, age, echoV, amp); } else { acc += w; }
                wPos += X * w;
                wSum += w;
                Tr *= att;
            }
            t += ds;
        }
    }
    let outside = t1 <= t0;
    if (trStar < 0.0) { trStar = select(Tr, 1.0, tStar < t0 || outside); }
    if (trJet < 0.0) { trJet = select(Tr, 1.0, tJet < t0 || outside); }
    if (trPlanet < 0.0) { trPlanet = select(Tr, 1.0, tPlanet < t0 || outside); }
    if (trMid < 0.0) { trMid = select(Tr, 1.0, tMid < t0 || outside); }
    var accS = vec3<f32>(0.0);
    if (wSum > 1e-6) {
        let X = wPos / wSum;
        // the lit surface: warmer near the star, bluer far out
        let x = length(X - ax * dot(X, ax)) / R;
        var sc = mix(mix(colStar, colGas, 0.4), colGas, smoothstep(0.08, 0.5, x));
        sc = mix(sc, colGas * vec3<f32>(0.8, 0.9, 1.25), smoothstep(0.6, 1.2, x));
        let tw = pdTexture(X, ax, e1, e2, R, n, &gaps, T, om0, cyc, seed);
        accS = sc * acc * (0.55 + 0.9 * tw.x) * (1.0 + 2.5 * tw.y);
    }

    // The millimeter glow: a thin sheet in the midplane, so taken in one piece where the ray
    // crosses it. The small grains hide it as much as the look asks: their column down to the
    // midplane here, and whatever the march found in front.
    var accM = vec3<f32>(0.0);
    var visMid = 1.0;
    if (tMid > 0.0 && wTherm > 0.0) {
        let X = ro + rd * tMid;
        let x = length(X) / R;
        if (x < 1.35) {
            let cz = max(abs(zd), 0.06);
            let cg = pdGas(x, n, &gaps);
            visMid = pow(max(trMid, 1e-6), kMm) * exp(-kMm * kView * cg.x * 1.2533 / max(cz, 0.1));
            // hotter, yellower rings inside; deep red and magenta at the edge
            var tc = mix(colDust * vec3<f32>(1.0, 1.5, 1.9) + vec3<f32>(0.08, 0.06, 0.0), colDust, smoothstep(0.1, 0.45, x));
            tc = mix(tc, colDust * vec3<f32>(0.95, 0.45, 1.1), smoothstep(0.5, 1.05, x));
            let glow = pdDust(x, n, &gaps) * inverseSqrt(max(x, 0.04)) * 2.5066 / cz * 0.22 * wTherm;
            let boost = pdBoost(X, ro, age, echoV, amp);
            let tw = pdTexture(X, ax, e1, e2, R, n, &gaps, T, om0, cyc, seed);
            accM = tc * glow * (0.45 + 1.1 * tw.x) * (1.0 + 1.5 * tw.y)
                 * (1.0 + 0.8 * (boost - 1.0)) * visMid;
        }
    }
    // what hides the star, planets and jets: the small grains, unless the look sees through them
    let vis = saturate(wScat);
    let visStar = mix(pow(max(trStar, 1e-6), kMm), trStar, vis);
    let visJet = mix(pow(max(trJet, 1e-6), kMm), trJet, vis);
    let visPlanet = mix(pow(max(trPlanet, 1e-6), kMm), trPlanet, vis);
    let visBack = mix(pow(max(Tr, 1e-6), kMm) * visMid, Tr, vis);

    // a faint envelope of leftover cloud, lit by the star, behind and around the disk
    let pe = (ro + rd * tStar) / R * 1.6 + seed;
    // (an outburst reaches it late, as an echo spreading out through the cloud)
    let env = exp(-dStar / (0.9 * R)) * (0.4 + 0.9 * (0.65 * noise3(pe) + 0.35 * noise3(pe * 2.1 + 3.0)));
    let envBoost = 1.0 + 0.5 * (pdBoost(ro + rd * tStar, ro, age, echoV, amp) - 1.0);
    col += mix(colGas, colDust, 0.35) * env * 0.035 * envBoost;
    col = col * visBack + accS + accM;

    // the jets: thin, slowly widening streams with knots of shocked gas moving outward, and the
    // counter jet showing only where the disk doesn't hide it
    if (S.f.w > 0.0 && tJet > 0.0) {
        let as_ = abs(sJet);
        let L = 1.3 * R;
        if (as_ < 1.2 * L) {
            let side = select(1.0, 0.0, sJet > 0.0);
            let wj = 0.003 * R + 0.012 * as_ + pixW * 0.5;
            let base = smoothstep(0.03 * R, 0.15 * R, as_) * smoothstep(1.15 * L, 0.5 * L, as_);
            let stream = (exp(-sq(dJet / wj)) + 0.25 * exp(-dJet / (3.0 * wj))) * base * 0.12;
            var knots = 0.0;
            for (var k = 0; k < 6; k++) {
                let hk = hash13(vec3<f32>(f32(k), side, seed + 4.0));
                let sk = fract(T / 110.0 + f32(k) / 6.0 + 0.12 * hk) * L * 1.15;
                let lk = 0.012 * R + 0.02 * sk;
                let bk = (0.4 + 1.2 * hk) * smoothstep(0.0, 0.15 * L, sk) * smoothstep(1.15 * L, 0.6 * L, sk);
                // a bow shape: brightest at the head, trailing back and widening
                let da = as_ - sk;
                let along = select(exp(da / lk), exp(-sq(da / (0.4 * lk))), da > 0.0);
                let wk = wj * 1.6 + 0.4 * lk * saturate(-da / lk + 0.3);
                knots += bk * along * exp(-sq(dJet / wk));
            }
            let jc = S.f.rgb;
            let jetLight = jc * stream + mix(jc, vec3<f32>(1.0, 0.85, 0.9) * max(jc.r, 0.5), 0.35) * knots * 0.5;
            col += jetLight * visJet;
        }
    }

    // the planets: small and hot, each glowing in its gap, which shows it from above (edge-on,
    // the disk hides it)
    let pr = max(0.007 * R, pixW * 1.2);
    let pc = mix(colDust, vec3<f32>(1.0, 0.85, 0.6), 0.5);
    let seeThrough = 0.5 * smoothstep(0.2, 0.6, abs(zd));
    col += pc * (exp(-sq(dPlanet / pr)) * 4.0 + exp(-dPlanet / (0.03 * R)) * 0.6) * max(visPlanet, seeThrough);

    // the star: a hot point and a soft glow, dimmed where the disk passes in front
    let core = max(pixW * 0.9, 0.004 * R);
    let sb = S.e.w;
    col += colStar * sb * (exp(-sq(dStar / core)) * 6.0 + exp(-dStar / (0.03 * R)) * 0.5 + exp(-dStar / (0.12 * R)) * 0.08) * visStar;
    return finalize(col, p);
}
