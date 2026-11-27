// ---------- per-frame: planetary nebula ---------- (ShaderPlanetary.swift)
// A dying star's shed envelope, lit by the hot white dwarf left behind. Every layer is optically
// thin glowing gas, so each is drawn as its column along the ray: the length of the chord through
// it (found in closed form) times a 3D texture sampled where the ray is inside it. A uniform shell
// seen this way brightens toward its edge, which is what makes the ring.
//
// S.a = barrel axis (unit), outer equatorial radius R
// S.b = inner gas color (doubly ionized oxygen), elongation (polar semi-axis / R)
// S.c = rim color (hydrogen and nitrogen), knots (0..1.5)
// S.d = halo color, halo on (0/1)
// S.e = x unused, y seed, z ejected shell radius (fraction of R, 0 = none), w its brightness
// S.f = central star color, w = brightness
// sphereSpan lives in common.wgsl.

// Where a ray is inside a spheroid with equatorial radius a and polar semi-axis c along ax:
// (enter, exit) in ray lengths, enter > exit when it misses.
fn spheroidSpan(ro: vec3<f32>, rd: vec3<f32>, ax: vec3<f32>, a: f32, c: f32) -> vec2<f32> {
    let k = 1.0 / c - 1.0 / a;
    let o = ro / a + ax * (dot(ro, ax) * k);
    let d = rd / a + ax * (dot(rd, ax) * k);
    let A = dot(d, d);
    let B = dot(o, d);
    let C = dot(o, o) - 1.0;
    let disc = B * B - A * C;
    if (disc <= 0.0) { return vec2<f32>(1.0, 0.0); }
    let q = sqrt(disc);
    return vec2<f32>((-B - q) / A, (-B + q) / A);
}

fn spanLength(s: vec2<f32>) -> f32 { return max(s.y - s.x, 0.0); }

// The rim's gas: bright clumps with dark gaps and dust lanes between them, and filaments
// streaming outward from the star. Thin over the barrel's open ends, so looking down its axis
// shows the inner glow rather than a red cap.
fn pnRimTexture(x: vec3<f32>, ax: vec3<f32>, R: f32, T: f32, seed: f32) -> f32 {
    let r = length(x);
    let u = x / max(r, 1e-4);
    let caps = 1.0 - 0.97 * smoothstep(0.35, 0.8, abs(dot(u, ax)));
    let clumps = fbm(x / R * 3.2 + vec3<f32>(seed, 0.0, T * 0.004));
    let fil = fbm(u * 7.0 + vec3<f32>(seed * 0.7, 0.0, r / R * 1.6 - T * 0.006));
    let streaks = pow(max(1.0 - abs(2.0 * fil - 1.0), 0.0), 3.0);
    let lanes = smoothstep(0.52, 0.68, fbm(x / R * 6.5 + vec3<f32>(seed + 2.0, T * 0.003, 0.0)));
    let body = 0.06 + 2.4 * pow(smoothstep(0.36, 0.76, clumps), 1.6);
    return caps * body * (0.4 + 1.3 * streaks) * (1.0 - 0.75 * lanes);
}

// The rim's color across its thickness (s: 0 at the inner edge, 1 at the outer): golden where it
// meets the oxygen glow, the picked color through the middle, crimson to magenta at the outside.
fn pnRimColor(c: vec3<f32>, s: f32) -> vec3<f32> {
    let gold = c * vec3<f32>(1.0, 1.9, 0.55) + vec3<f32>(0.0, 0.03, 0.0);
    let deep = c * vec3<f32>(0.95, 0.5, 1.3);
    return select(mix(c, deep, smoothstep(0.45, 1.0, s)), mix(gold, c, smoothstep(0.0, 0.45, s)), s < 0.45);
}

// Normalized spheroidal radius: 1 on the surface with equatorial radius R.
fn pnRadius(x: vec3<f32>, ax: vec3<f32>, R: f32, el: f32) -> f32 {
    let h = dot(x, ax);
    return length(x - ax * h + ax * (h / el)) / R;
}

// The rim's light along the ray: the front and back walls of a thick shell, each textured at its
// middle, so the texture is the same 3D gas from any viewing angle. The wall lengths are averaged
// over a few nested shells (and the outer edge is roughened by `jitter`), so both edges fade out
// rather than end on a line.
fn pnShell(ro: vec3<f32>, rd: vec3<f32>, ax: vec3<f32>, R: f32, el: f32, jitter: f32, colRim: vec3<f32>,
           T: f32, seed: f32) -> vec3<f32> {
    var front = 0.0;
    var back = 0.0;
    var outer = vec2<f32>(1.0, 0.0);
    for (var k = 0; k < 3; k++) {
        let ko = (0.8 + 0.16 * f32(k)) * jitter;
        let ki = 0.6 + 0.09 * f32(k);
        let so = spheroidSpan(ro, rd, ax, R * ko, R * el * ko);
        if (so.x >= so.y) { continue; }
        let si = spheroidSpan(ro, rd, ax, R * ki, R * el * ki);
        if (si.x < si.y) {
            front += si.x - so.x;
            back += so.y - si.y;
        } else {
            front += 0.5 * (so.y - so.x);
            back += 0.5 * (so.y - so.x);
        }
        outer = so;
    }
    if (outer.x >= outer.y) { return vec3<f32>(0.0); }
    // Texture each wall a fixed depth in from where the ray enters (or leaves) the outermost shell,
    // capped at the middle of the chord: the sample points move smoothly from pixel to pixel.
    let depth = min(0.2 * R, 0.5 * (outer.y - outer.x));
    let pf = ro + rd * (outer.x + depth);
    let pb = ro + rd * (outer.y - depth);
    // The color gradient: looking down the barrel it follows where the ray passes the star, so it
    // runs cleanly across the ring; seen from the side, where that says little, it follows each
    // wall's own distance from the star.
    let ca = abs(dot(ax, normalize(-ro)));
    let sp = saturate((pnRadius(ro + rd * dot(-ro, rd), ax, R, el) - 0.6) / 0.5);
    let sf = mix(saturate((pnRadius(pf, ax, R, el) - 0.8) / 0.35), sp, ca * ca);
    let sb = mix(saturate((pnRadius(pb, ax, R, el) - 0.8) / 0.35), sp, ca * ca);
    return (front * pnRimTexture(pf, ax, R, T, seed) * pnRimColor(colRim, sf)
          + back * pnRimTexture(pb, ax, R, T, seed + 3.1) * pnRimColor(colRim, sb)) / 3.0;
}

// Cometary knots around the inside of the rim, as in the Helix: dense droplets of gas lit on the
// side facing the star, with a darker head and a shadowed tail trailing away from it. Each one
// differs: size, stretch, how far round its lit side wraps and which way it leans, brightness,
// tail length and curl, and color (from the rim's gradient, now and then nearly white-hot); some
// are only dark smudges. Placed on a grid in the nebula's projected ellipse (angle and normalized
// radius), so each pixel only checks a few cells. Returns (light, absorption).
fn pnKnots(X: vec3<f32>, v: vec3<f32>, ap: vec3<f32>, bp: vec3<f32>, sa: f32, R: f32, amount: f32,
           colRim: vec3<f32>, pixW: f32, T: f32, seed: f32) -> vec4<f32> {
    let q = vec2<f32>(dot(X, ap) / sa, dot(X, bp) / R);
    let rho = length(q);
    let rho0 = 0.6;
    let dr = 0.075;
    let N = 72;
    if (rho < rho0 - 2.0 * dr || rho > rho0 + 6.0 * dr) { return vec4<f32>(0.0); }
    let th = atan2(q.y, q.x);
    let ci = i32(floor((th / 6.2831853 + 0.5) * f32(N)));
    let cj = i32(floor((rho - rho0) / dr));
    var light = vec3<f32>(0.0);
    var absorb = 0.0;
    for (var dj = -2; dj <= 1; dj++) {
        let j = cj + dj;
        if (j < 0 || j > 4) { continue; }
        for (var di = -1; di <= 1; di++) {
            let i = (ci + di + N) % N;
            let h3 = vec3<f32>(f32(i), f32(j), seed);
            // denser toward the inner edge, where the knots are freshest
            let keep = amount * (0.42 - 0.07 * f32(j));
            if (hash13(h3) > keep) { continue; }
            let tk = (f32(i) + 0.15 + 0.7 * hash13(h3 + 1.7)) / f32(N) * 6.2831853 - 3.14159265;
            let rk = rho0 + (f32(j) + 0.15 + 0.7 * hash13(h3 + 4.3)) * dr;
            let K = ap * (cos(tk) * rk * sa) + bp * (sin(tk) * rk * R);
            let er = normalize(K);
            let et = cross(v, er);
            let d = X - K;
            let along = dot(d, er);
            let perp = dot(d, et);
            let hA = hash13(h3 + 11.1);
            let hB = hash13(h3 + 13.7);
            let hC = hash13(h3 + 17.3);
            let hD = hash13(h3 + 19.9);
            let hE = hash13(h3 + 23.5);
            let hF = hash13(h3 + 29.3);
            let h = max(R * (0.012 + 0.022 * hash13(h3 + 7.9) * hash13(h3 + 8.3)), pixW * 1.4);
            // the head: an egg stretched along the line to the star, leaning a little to one side
            let lean = (hA - 0.5) * 1.1;
            let cl = cos(lean);
            let sl = sin(lean);
            let a2 = cl * along + sl * perp;
            let p2 = -sl * along + cl * perp;
            let stretch = 1.0 + 1.4 * hB;
            let hd = length(vec2<f32>(a2 / (h * stretch), p2 / h));
            // lit side: a soft glow that wraps further round some knots than others
            let wrap = mix(0.6, -0.3, hC);
            let side = smoothstep(wrap, -1.0, a2 / (h * stretch));
            let lit = exp(-sq((hd - 0.85) / 0.6)) * side + 0.05 * exp(-hd * hd);
            let bright = select(0.35 + 1.3 * hD * hD, 0.0, hF < 0.15);      // some are only dark smudges
            let flick = 0.85 + 0.3 * noise3(vec3<f32>(f32(i), f32(j), T * 0.12));
            var kc = pnRimColor(colRim, 0.3 + 0.6 * hE);
            if (hE > 0.93) { kc = mix(kc, vec3<f32>(1.0, 0.92, 0.8), 0.55); }
            light += kc * lit * bright * flick;
            // a tail curling slightly as it trails away
            let L = h * (2.0 + 6.0 * hash13(h3 + 2.2));
            let curl = (hash13(h3 + 31.1) - 0.5) * 1.2 / L;
            let pc = perp - curl * along * along;
            let tail = select(0.0, exp(-sq(pc / (h * (0.7 + 0.6 * along / L)))) * exp(-along / L), along > 0.0);
            absorb = max(absorb, max(exp(-hd * hd * 1.2) * (0.35 + 0.4 * hB), tail * (0.2 + 0.35 * hA)));
        }
    }
    return vec4<f32>(light, absorb);
}

@fragment
fn planetaryFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    let T = F.time;
    let ax = S.a.xyz;
    let R = S.a.w;
    let el = S.b.w;
    let seed = S.e.y;
    let colIn = S.b.rgb;
    let colRim = S.c.rgb;
    let colHalo = S.d.rgb;
    let tc = -dot(ro, rd);
    let X = ro + rd * tc;               // closest point to the star, in the plane facing us
    let dmin = length(X);
    let pixW = F.pixelAngle * length(ro);
    var col = SKY(p, rd, false);

    var neb = vec3<f32>(0.0);
    var absorb = 0.0;
    var knotLight = vec3<f32>(0.0);
    if (dmin < R * 3.6) {
        // the rim: hydrogen and nitrogen in a thick barrel, with a faint skirt beyond it
        let jitter = 0.9 + 0.22 * fbm(normalize(X + 1e-4) * 1.7 + vec3<f32>(seed, 1.0, 0.0));
        neb += pnShell(ro, rd, ax, R, el, jitter, colRim, T, seed) * 0.24;
        // a faint, uneven skirt fading out beyond the rim
        let skirt = exp(-pow(max(dmin - 0.9 * R, 0.0) / (0.45 * R), 1.5)) * smoothstep(0.55 * R, 0.95 * R, dmin);
        neb += pnRimColor(colRim, 1.0) * skirt * 0.14 * sq(fbm(X / R * 2.2 + seed + 4.0));

        // the inside: oxygen ionized twice over by the star's hard light, thinning at the very middle
        var inner = 0.0;
        for (var k = 0; k < 4; k++) {
            let ki = 0.54 + 0.11 * f32(k);
            inner += spanLength(spheroidSpan(ro, rd, ax, R * ki, R * el * ki * 1.04));
        }
        if (inner > 0.0) {
            let tex = 0.45 + 1.1 * pow(max(fbm(X / R * 2.4 + vec3<f32>(seed + 5.0, 0.0, T * 0.006)), 0.0), 1.5);
            let hollow = spanLength(spheroidSpan(ro, rd, ax, R * 0.32, R * el * 0.32));
            // hotter and bluer toward the star, greener toward the rim
            let c = saturate(dmin / (0.7 * R));
            let tint = mix(colIn * vec3<f32>(0.55, 0.8, 1.5), colIn * vec3<f32>(0.8, 1.15, 0.75), c * c);
            neb += tint * (inner / 4.0 - 0.55 * hollow) * tex * 0.046;
        }

        // the halo: older, fainter shells from earlier puffs, drifting outward and fading
        if (S.d.w > 0.5) {
            // a soft glow falling away beyond the rim, and the thin edges of older shells
            let out_ = smoothstep(0.9 * R, 1.3 * R, dmin) * exp(-max(dmin - 1.1 * R, 0.0) / (0.6 * R)) * smoothstep(3.5 * R, 2.2 * R, dmin);
            neb += colHalo * out_ * 0.03 * pow(max(fbm(X / R * 1.8 + seed + 9.0) * 1.6, 0.0), 2.5);
            for (var k = 0; k < 4; k++) {
                let ph = fract(T / 400.0 + f32(k) * 0.25);
                let rr = R * (1.15 + 0.85 * ph);
                let w = R * 0.07;
                // a thin shell seen edge-on: a soft ring at its radius, broken into arcs
                let ring = exp(-sq((dmin - rr) / w));
                if (ring < 0.01) { continue; }
                let u = normalize(X + 1e-4);
                let arcs = smoothstep(0.4, 0.75, fbm(u * 2.2 + vec3<f32>(f32(k) * 7.3 + seed, 0.0, 0.0)));
                let life = sq(sin(3.14159265 * ph)) * (1.0 - 0.6 * ph);
                neb += mix(colHalo, colHalo * vec3<f32>(1.0, 0.6, 1.4), ph) * ring * arcs * life * 0.09;
            }
        }

        // a fresh shell blown off the star (event)
        if (S.e.w > 0.001) {
            // seen edge-on it's a soft bright ring at its radius, with a fainter fill across it
            let rr = S.e.z * R;
            let w = R * (0.05 + 0.06 * S.e.z);
            let shell = exp(-sq((dmin - rr) / w)) + 0.25 * smoothstep(rr, 0.5 * rr, dmin);
            let clumpy = 0.55 + 0.9 * fbm(normalize(X + 1e-4) * 4.0 + vec3<f32>(seed, 3.0, 0.0));
            neb += mix(colIn, vec3<f32>(1.0, 0.95, 0.9), 0.35) * shell * clumpy * S.e.w * 0.32;
        }

        // the cometary knots
        if (S.c.w > 0.0) {
            let v = normalize(-ro);
            var ap = ax - v * dot(ax, v);
            ap = select(F.camRight.xyz, normalize(ap), length(ap) > 1e-3);
            let bp = cross(v, ap);
            let ca = abs(dot(ax, v));
            let sa = R * sqrt(el * el * (1.0 - ca * ca) + ca * ca);
            // the knots are placed on the projected ring, which only matches the barrel's inner
            // edge when we look down it; seen from the side they thin out
            let kn = pnKnots(X, v, ap, bp, sa, R, S.c.w * mix(0.15, 1.0, smoothstep(0.35, 0.85, ca)), colRim, pixW, T, seed);
            knotLight = kn.rgb;
            absorb = kn.w;
        }
    }
    col = (col + neb) * (1.0 - 0.8 * absorb);
    col += knotLight * 0.9;

    // the white dwarf: tiny and very hot, with a soft blue glow of its own
    let core = max(pixW * 0.9, R * 0.006);
    col += S.f.rgb * S.f.w * (exp(-(dmin * dmin) / (core * core)) * 5.0 + exp(-dmin / (R * 0.05)) * 0.35 + exp(-dmin / (R * 0.25)) * 0.05);
    return finalize(col, p);
}
