// ---------- per-frame: neutron star merger ----------
// A loop with no empty moment. A magnetar, the remnant of the last merger, sits in its fading
// kilonova nebula. A new neutron star falls in from beyond the frame on a long eccentric orbit;
// gravitational waves wear the orbit round and small (the chirp), and the pair merge in a flash,
// a short jet and a fresh kilonova, leaving a new remnant at the center. Once the orbit is
// circular it follows the quadrupole chirp: with tau the time left before the merger, the phase
// is phi = phi0 - K tau^(5/8). The waves leave at speed v, so a point at distance rho in the
// orbital plane sees the orbit as it was at tau + rho / v: a trailing two-armed spiral that
// winds tighter as the chirp climbs, and that bends the starlight behind it slightly.
// The system sits at the origin, in the camera's usual frame.
//
// S.a = remnant center, remnant glow (its magnetar beat and early spin-down brightening; 1 = plain)
// S.b = companion center, tidal stretch (long axis over radius)
// S.c = orbit normal, wave ripple strength
// S.d = orbit basis e1 (e2 = n x e1), tau: time to the next merger, or minus the time since the last
// S.e = star glow color x brightness, companion presence (0..1)
// S.f = kilonova hot color, age since the last merger (s)
// S.g = kilonova cool color, kilonova brightness (1 fresh, lower for the lingering nebula)
// S.h = remnant magnetic axis, jet on
// S.i = companion magnetic axis, glow size
// S.j = K, phi0, tauC (before it the orbit was still eccentric, so its waves are left out), flash

const NSM_R: f32 = 0.2;      // star radius
const NSM_V: f32 = 0.6;      // wave speed

// Ray against an ellipsoid of radius R stretched by s along unit axis u (volume kept, so the
// cross section shrinks by sqrt(s)). Returns the entry distance (or -1) and the normal there.
fn nsmEllipsoid(ro: vec3<f32>, rd: vec3<f32>, c: vec3<f32>, u: vec3<f32>, R: f32, s: f32, nrm: ptr<function, vec3<f32>>) -> f32 {
    let o = ro - c;
    let k = sqrt(s);
    // into the unit sphere's frame: divide by R s along u and by R / sqrt(s) across it
    let ou = dot(o, u);
    let du = dot(rd, u);
    let op = o - u * ou;
    let dp = rd - u * du;
    let O = op * (k / R) + u * (ou / (R * s));
    let D = dp * (k / R) + u * (du / (R * s));
    let a = dot(D, D);
    let b = dot(O, D);
    let cc = dot(O, O) - 1.0;
    let disc = b * b - a * cc;
    if (disc < 0.0) { return -1.0; }
    let t = (-b - sqrt(disc)) / a;
    if (t < 0.0) { return -1.0; }
    let P = O + D * t;
    // the gradient of the implicit surface, back in world space
    let pu = dot(P, u);
    let pp = P - u * pu;
    *nrm = normalize(pp * (k / R) + u * (pu / (R * s)));
    return t;
}

// Blends two colors keeping their saturation, so a hue change doesn't pass through gray.
fn nsmMix(a: vec3<f32>, b: vec3<f32>, t: f32) -> vec3<f32> {
    let c = mix(a, b, t);
    let ma = dot(a, vec3<f32>(0.333));
    let mb = dot(b, vec3<f32>(0.333));
    let m = dot(c, vec3<f32>(0.333));
    let sa = length(a - ma) / max(ma, 1e-4);
    let sb = length(b - mb) / max(mb, 1e-4);
    let sc = length(c - m) / max(m, 1e-4);
    return max(m + (c - m) * mix(sa, sb, t) / max(sc, 1e-3), vec3<f32>(0.0));
}

// Dipole field lines seen around a star: the slice through its center facing us, where the
// lines r = L sin^2(theta) are drawn as soft threads with charges streaming along them.
fn nsmField(q: vec3<f32>, m: vec3<f32>, R: f32, T: f32, seed: f32) -> f32 {
    let r = length(q);
    if (r < R * 1.05 || r > R * 12.0) { return 0.0; }
    let c = dot(q, m) / r;
    let s2 = max(1.0 - c * c, 1e-3);
    let L = r / s2;
    var lines = 0.0;
    for (var k = 0; k < 3; k++) {
        let Lk = R * (2.6 + 2.0 * f32(k));
        let e = (L - Lk) / (0.1 * Lk);
        lines += (exp(-e * e) + 0.08 * exp(-abs(e) * 0.7)) * (1.0 - 0.3 * f32(k));
    }
    let flow = 0.55 + 0.45 * sin(c * 7.0 - T * 2.5 + seed);
    return lines * flow * smoothstep(R * 1.05, R * 1.8, r) * (1.0 - smoothstep(R * 6.0, R * 12.0, r));
}

@fragment
fn neutronMergerFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    let T = F.time;

    let cA = S.a.xyz;
    let cB = S.b.xyz;
    let n = S.c.xyz;
    let e1 = S.d.xyz;
    let e2 = cross(n, e1);
    let R = NSM_R;
    let vw = NSM_V;
    let remGlow = S.a.w;
    let stretch = S.b.w;
    let tau = S.d.w;
    let presence = S.e.w;
    let glowCol = S.e.rgb;
    let age = S.f.w;
    let kfade = S.g.w;
    let hotCol = S.f.rgb;
    let coolCol = S.g.rgb;
    let K = S.j.x;
    let phi0 = S.j.y;
    let tauC = S.j.z;
    let flash = S.j.w;
    let glowSize = S.i.w;
    let pair = presence > 0.0;
    let pixW = F.pixelAngle * length(ro);              // world size of a pixel at the system
    let sepV = cB - cA;
    let sep = select(0.0, length(sepV), pair);

    // ---- gravitational waves in the orbital plane ----
    let dn = dot(rd, n);
    let tp = -dot(ro, n) / select(1e-4, dn, abs(dn) > 1e-4);
    var wave = 0.0;
    var disp = vec2<f32>(0.0);
    if (tp > 0.0 && S.c.w > 0.0) {
        let x = ro + rd * tp;
        let rho = length(x);
        let tr = tau + rho / vw;                       // time to merger when this bit left
        let th = atan2(dot(x, e2), dot(x, e1));
        // a pixel's footprint on the plane, stretched where we look along it at a slant
        let foot = F.pixelAngle * tp / max(abs(dn), 0.05);
        var amp = 0.0;
        var psi = 0.0;
        if (tr > 0.0 && tr < tauC) {
            let trc = max(tr, 0.03);
            let omega = 0.625 * K * pow(trc, -0.375);
            let phiR = phi0 - K * pow(trc, 0.625);
            psi = 2.0 * (th - phiR);
            // strain grows as omega^(2/3); the local wavelength is pi v / omega, faded out
            // where it gets down to a few pixels, and the near zone inside the orbit is calm
            let lam = 3.14159 * vw / omega;
            amp = min(pow(omega / 0.4, 0.667), 2.0) * smoothstep(foot * 4.0, foot * 10.0, lam);
            amp *= smoothstep(0.5 * sep, 1.5 * sep + 0.4, rho) * smoothstep(tauC, tauC * 0.6, tr);
        } else if (tr <= 0.0 && tr > -0.8) {
            // the ringdown of the merged remnant: one last fast, fading burst
            let omega = 14.0;
            psi = 2.0 * th - omega * tr * 2.0;
            amp = 1.5 * exp(tr / 0.2) * smoothstep(foot * 4.0, foot * 10.0, 3.14159 * vw / omega);
        }
        // falls off with distance, and is soft at both ends
        amp *= smoothstep(0.2, 1.0, rho) / (1.0 + rho / 5.0);
        wave = amp * cos(psi);
        // the light is nudged across the wavefronts (the strain's gradient points radially)
        let er = x / max(rho, 1e-3);
        let g = amp * sin(psi) * S.c.w;
        disp = vec2<f32>(dot(er, F.camRight.xyz), -dot(er, F.camUp.xyz)) * g * 2.2;
    }
    var q = vec2<i32>(p) + vec2<i32>(round(disp));
    q = clamp(q, vec2<i32>(0), vec2<i32>(i32(F.camRight.w) - 1, i32(F.camUp.w) - 1));
    var col = SKY(vec2<u32>(q), rd, false);
    // where the waves squeeze space the stars behind brighten a touch, and a faint sheen
    // shows the wavefronts against the dark
    col *= clamp(1.0 + 0.06 * wave * S.c.w, 0.75, 1.3);
    col += glowCol * vec3<f32>(0.45, 0.6, 1.0) * sq(max(wave, 0.0)) * 0.004 * S.c.w;

    let tc0 = -dot(ro, rd);
    let d0 = length(ro + rd * tc0);
    let x0 = ro + rd * tc0;
    // the hot color's hue at unit strength (a saturated pick can carry several units of light)
    let hotN = hotCol / max(max(hotCol.r, hotCol.g), max(hotCol.b, 1e-3));

    // ---- the kilonova, then the nebula it leaves ----
    // Radioactive ejecta glowing as it expands. Two outflows: a fast, lanthanide-poor polar wind
    // that glows hot blue and fades first, and a slower, heavier equatorial torus that turns
    // red. Fingers of ejecta streak outward. Long after, a faint red and gold shell lingers.
    let Rk = 0.3 + 3.6 * (1.0 - exp(-age / 14.0)) + age * 0.004;
    let Rb = Rk * 1.45;
    if (d0 < Rb && kfade > 0.0) {
        let half_ = sqrt(Rb * Rb - d0 * d0);
        // the faint lingering nebula is smooth enough for fewer samples
        let N = select(12, 22, kfade > 0.5);
        let dt = 2.0 * half_ / f32(N);
        let jitter = hash13(vec3<f32>(vec2<f32>(p), 7.0));
        var acc = vec3<f32>(0.0);
        let heat0 = exp(-age / 7.0);
        // Cooling runs like a blackbody's colors (blue-white, gold, red), so each outflow
        // has its own color: the polar wind stays hot blue for a while and cools to gold;
        // the equatorial torus starts gold-white and soon turns red.
        let bright = (dot(hotCol, vec3<f32>(0.33)) + dot(coolCol, vec3<f32>(0.33))) * 0.5;
        let warm = vec3<f32>(1.2, 0.8, 0.4) * bright;
        let white = vec3<f32>(1.0, 0.97, 0.92) * bright * 1.3;
        let polarC = nsmMix(warm, nsmMix(hotCol, white, heat0 * 0.3), exp(-age / 24.0));
        var equatC: vec3<f32>;
        if (heat0 > 0.5) {
            equatC = nsmMix(warm, white, heat0 * 2.0 - 1.0);
        } else {
            equatC = nsmMix(coolCol, warm, heat0 * 2.0);
        }
        for (var i = 0; i < N; i++) {
            let ti = tc0 - half_ + (f32(i) + jitter) * dt;
            let x = ro + rd * ti;
            let r = length(x) / Rk;
            if (r > 1.45) { continue; }
            let dir = x / max(length(x), 1e-4);
            let z = dot(dir, n);
            let z2 = z * z;
            // radial streaks: noise on the direction alone keeps them radial; they thin
            // out toward their tips instead of ending on an edge
            let sN = noise3(dir * 13.0 + 3.0) * 0.65 + noise3(dir * 29.0 + 9.0) * 0.35;
            let streak = sq(smoothstep(0.48, 0.82, sN));
            let clump = fbm(x / Rk * 2.6 + vec3<f32>(0.0, 0.0, age * 0.04));
            let rr = r * (1.0 + 0.35 * (0.5 - clump));        // a ragged, not round, edge
            let edge = 1.0 - smoothstep(0.45, 1.05, rr);
            let blue = exp(-sq((rr - 0.5 - 0.3 * z2) / 0.32)) * (0.08 + z2 * 1.6) * edge;
            let red = exp(-sq(rr / 0.6)) * (1.0 - 0.75 * z2) * edge * 1.3;
            let lumpy = 0.15 + 1.8 * sq(clump);
            let st = streak * (1.0 - smoothstep(0.5, 1.45, r)) * smoothstep(0.15, 0.6, r) * (0.5 + 1.1 * clump);
            // the streaks take the color of the outflow they fly out with
            let pw = smoothstep(0.15, 0.6, z2);
            acc += polarC * (blue * lumpy * 1.3 + st * pw) + equatC * (red * lumpy + st * (1.0 - pw));
        }
        // brightness: up within a second or so, then down as the ejecta thins out
        let lum = smoothstep(0.0, 1.2, age) * (0.3 + 1.3 * exp(-age / 9.0)) / (Rk * 0.5 + 0.4);
        col += acc * dt * lum * kfade * 0.6;
    }

    // ---- the stars: the remnant always, and the companion once it has arrived ----
    let u = select(n, sepV / max(sep, 1e-4), pair);
    let close = select(0.0, smoothstep(2.2, 0.6, sep), pair);    // the last seconds of the chirp
    if (close > 0.0) {
        // stripped matter: two tidal tails winding out of the pair and a hot common glow
        if (tp > 0.0) {
            let x = ro + rd * tp;
            let rho = length(x);
            let th = atan2(dot(x, e2), dot(x, e1));
            let phi = phi0 - K * pow(max(tau, 0.0), 0.625);
            let arms = 0.5 + 0.5 * cos(2.0 * (th - phi) + log(max(rho, 0.05)) * 5.0);
            let tail = exp(-rho / (0.5 + 0.6 * sep)) * pow(arms, 3.0) * smoothstep(0.3 * sep, 0.6 * sep, rho);
            col += mix(glowCol, hotCol, 0.5) * tail * close * 1.4;
        }
        col += mix(glowCol, hotCol, 0.4) * exp(-d0 / (0.35 + 0.3 * sep)) * close * close * 1.5;
    }
    var tHit = 1e9;
    var surfVis = 1.0;
    var surf = vec3<f32>(0.0);
    for (var k = 0; k < 2; k++) {
        let vis = select(presence, 1.0, k == 0);
        if (vis <= 0.0) { continue; }
        let c = select(cB, cA, k == 0);
        let m = select(S.i.xyz, S.h.xyz, k == 0);
        let toward = select(-u, u, k == 0);
        // the remnant's magnetar beat swells its halo and its field together, and its
        // young, hot surface leans toward the kilonova's hot color
        let gain = select(1.0, remGlow, k == 0);
        let sc = select(glowCol, nsmMix(glowCol, hotN * dot(glowCol, vec3<f32>(0.33)), 0.5 * saturate(remGlow - 1.0)), k == 0);
        // glow: a soft halo around a bright core, hotter as they close in
        let tcs = dot(c - ro, rd);
        let qv = ro + rd * tcs - c;
        let d = length(qv);
        let gs = glowSize * (1.0 + 0.6 * close);
        col += sc * (exp(-d / (R * 0.9 * gs)) * 1.6 + exp(-d / (R * 3.0 * gs)) * 0.15 * gain
                     + exp(-d / (R * 10.0 * gs)) * 0.012 * gain) * vis;
        // magnetic field hints, brighter as the magnetospheres are squeezed together
        let fl = nsmField(qv, m, R, T, f32(k) * 2.1);
        let fieldCol = mix(sc, vec3<f32>(0.45, 0.55, 1.0) * dot(sc, vec3<f32>(0.33)), 0.55);
        col += fieldCol * fl * (0.22 + 0.4 * close) * gain * gain * vis;
        // the star itself, stretched by tides only while it has a partner
        var nrm = vec3<f32>(0.0, 0.0, 1.0);
        let th = nsmEllipsoid(ro, rd, c, u, R, select(1.0, stretch, pair), &nrm);
        if (th > 0.0 && th < tHit) {
            tHit = th;
            surfVis = vis;
            let mu = max(dot(nrm, -rd), 0.0);
            let limb = 0.55 + 0.45 * mu;
            let pole = pow(abs(dot(nrm, m)), 10.0);
            let tidal = pow(max(dot(nrm, toward), 0.0), 3.0) * close;   // the heated near side
            let white = mix(sc, vec3<f32>(dot(sc, vec3<f32>(0.33))), 0.6);
            surf = white * (3.0 * limb + 3.0 * pole) + hotCol * tidal * 3.0;
        }
    }
    if (tHit < 1e9) { col = mix(col, surf, surfVis); }

    // ---- the jet: punches out along the orbit axis in the first seconds, then fades ----
    if (S.h.w > 0.5 && age < 20.0) {
        var jl = 0.0;
        let head = min(age * 6.0, 7.0);
        let b = dot(rd, n);
        let e = dot(n, ro);
        let dd = dot(rd, ro);
        let den = max(1.0 - b * b, 1e-4);
        let t = (b * e - dd) / den;
        let s = e + t * b;
        let as_ = abs(s);
        if (t > 0.0 && as_ < head) {
            let d = length(ro + rd * t - n * s);
            let w = 0.06 + 0.05 * as_;
            let knots = 0.6 + 0.8 * noise3(vec3<f32>(as_ * 1.2 - age * 6.0, select(5.0, 0.0, s > 0.0), 0.0));
            let along = smoothstep(0.05, 0.6, as_) * (1.0 - smoothstep(head * 0.4, head, as_)) * exp(-as_ / 5.0);
            let wc = max(w * 0.25, pixW * 0.7);
            jl = (exp(-sq(d / w)) * knots * 0.6 + exp(-d / (w * 3.0)) * 0.15) * along
               + exp(-sq(d / wc)) * along * (w * 0.3 / wc) * 0.35;
        }
        let jt = smoothstep(0.2, 0.8, age) * exp(-age / 3.0);
        col += mix(hotN, vec3<f32>(1.0), 0.3) * jl * jt * 3.2;
    }

    // ---- the flash: a bright burst around the merger with a few diffraction spikes; only
    // the first instant lifts the whole screen, and only slightly ----
    if (flash > 0.001) {
        let wx = abs(dot(x0, F.camRight.xyz));
        let wy = abs(dot(x0, F.camUp.xyz));
        let spikes = exp(-wy / 0.05) * exp(-wx / 3.0) + exp(-wx / 0.05) * exp(-wy / 2.0);
        let fc = mix(hotN, vec3<f32>(1.0), 0.6);
        col += fc * (exp(-d0 / 0.4) * 14.0 + exp(-d0 / 1.6) * 1.8 + exp(-d0 / 5.0) * 0.05 + spikes * 2.5) * flash;
        col += fc * 0.015 * flash * flash * flash;
    }
    return finalize(col, p);
}
