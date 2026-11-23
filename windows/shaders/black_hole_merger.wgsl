// ---------- per-frame: black hole merger ----------
// The neutron star merger's loop with black holes: a remnant waits, a companion falls in and is
// worn down by gravitational waves into the chirp, and the two shadows run together into one
// that rings down. Nothing here shines on its own, so the holes show by their shadows, thin
// photon rings and the light they bend. Lensing is done per pixel as two point lenses: a ray
// passing at angle theta from a lens sees the sky at theta - thetaE^2 / theta, which draws each
// star behind a hole into arcs and a ring. What surrounds the pair depends on its size (S.g.w):
// 0 empty space (stellar), 1 a dense star cluster (intermediate), 2 a gas disk with a cleared
// cavity, mini-disks, streams and jets (supermassive).
//
// S.a = remnant center, shadow radius        S.b = companion center, shadow radius
// S.c = orbit normal, wave strength          S.d = orbit basis e1, tau (minus the time since the last merger)
// S.e = photon ring color, the companion's presence for the gas (it fades over seconds after the merger)
// S.f = hot color, age since the last merger S.g = cool color, model
// S.h = K, phi0, tauC, unequal-mass harmonic weight
// S.i = remnant Einstein radius, companion Einstein radius, remnant spin, photon ring boost
// S.j = ringdown angular frequency, ringdown decay time, gas cavity radius, afterglow
// S.k = remnant spin axis, jet strength      S.l = the last remnant's spin axis, its jets' strength
// S.m = disk normal (the total angular momentum, or the quasar disk's), the binary's angle in the orbital plane (for the gas)
// S.n = periapsis angle, eccentricity kept through the chirp, rosette rate, lobes (1 for the pair, fading after the merger)
// S.o = system center (the recoil kick moves it), flags (1 strain trace, 2 background galaxy)
// S.p = remnant velocity, the scene's own time (its Speed applied)
// (S.j.w is the supermassive disk's refill glow, or the quasar disk's flare)

const BBH_V: f32 = 0.6;        // wave speed

// Reflects a pixel coordinate back into [0, n): a lensed ray leaving the frame takes the sky from
// the mirrored side, which a random star field doesn't give away.
fn bbhMirror(x_in: i32, n: i32) -> i32 {
    let m = 2 * n;
    var x = x_in % m;
    if (x < 0) { x += m; }
    return select(m - 1 - x, x, x < n);
}

// Point lens at c with Einstein radius rE (world units at the lens). Returns the shift that takes
// rd to the direction it sees, the impact distance b at the lens, and the unit offset from it.
fn bbhLens(ro: vec3<f32>, rd: vec3<f32>, c: vec3<f32>, rE: f32, b: ptr<function, f32>, perp: ptr<function, vec3<f32>>) -> vec3<f32> {
    let oc = c - ro;
    let dist = length(oc);
    let l = oc / dist;
    let v = rd - l * dot(rd, l);
    let th = max(length(v), 1e-6);
    *b = th * dist;
    *perp = v / th;
    let thE = rE / dist;
    return -(*perp) * min(thE * thE / th, 0.5);
}

// How much farther than a circle's edge a point lies on an outline stretched by e along axis
// (seen from direction l; the stretch shows less as the axis turns toward us). Area is kept.
fn bbhStretch(perp: vec3<f32>, l: vec3<f32>, axis: vec3<f32>, e: f32) -> f32 {
    let a = axis - l * dot(axis, l);
    let la = length(a);
    if (la < 1e-4 || e <= 0.0) { return 1.0; }
    let ee = e * min(la / max(length(axis), 1e-4), 1.0);
    let c = dot(perp, a / la);
    return sqrt(c * c / sq(1.0 + ee) + (1.0 - c * c) * (1.0 + ee));
}

fn bbhSmin(a: f32, b: f32, k: f32) -> f32 {
    let h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// A jet from o along axis j (both ways): a thin bright spine in a soft sheath, with knots
// moving out. Fades toward its tips rather than ending on an edge.
fn bbhJet(ro: vec3<f32>, rd: vec3<f32>, o: vec3<f32>, j: vec3<f32>, T: f32, pixW: f32) -> f32 {
    let w = ro - o;
    let b = dot(rd, j);
    let e = dot(j, w);
    let dd = dot(rd, w);
    let den = max(1.0 - b * b, 1e-4);
    let t = (b * e - dd) / den;
    if (t <= 0.0) { return 0.0; }
    let s = e + t * b;
    let as_ = abs(s);
    if (as_ > 13.0) { return 0.0; }
    let d = length(w + rd * t - j * s);
    let wd = 0.07 + 0.045 * as_;
    let knots = 0.55 + 0.9 * sq(noise3(vec3<f32>(as_ * 0.9 - T * 0.8, select(7.0, 0.0, s > 0.0), 0.0)));
    let along = smoothstep(0.4, 1.5, as_) * (1.0 - smoothstep(5.0, 13.0, as_));
    let wc = max(wd * 0.22, pixW * 0.7);
    return ((exp(-sq(d / wd)) * knots * 0.5 + exp(-d / (wd * 3.0)) * 0.12)
            + exp(-sq(d / wc)) * (wd * 0.22 / wc) * 0.15) * along;
}

// The supermassive pair's gas at X in the disk plane: emission and opacity. A circumbinary disk
// with a cleared middle, a lump riding its inner edge, two streams falling from that edge to
// mini-disks around each hole, hotter (bluer) inward and brighter on the side turning toward us.
fn bbhGas(X: vec3<f32>, rd: vec3<f32>, nD: vec3<f32>, cA: vec3<f32>, cB: vec3<f32>, rA: f32, rB: f32, bDir: vec3<f32>,
          presence: f32, sep: f32, cavity: f32, afterglow: f32,
          hotCol: vec3<f32>, coolCol: vec3<f32>, T: f32) -> vec4<f32> {
    var g1: vec3<f32>;
    if (abs(nD.y) < 0.9) {
        g1 = normalize(cross(nD, vec3<f32>(0.0, 1.0, 0.0)));
    } else {
        g1 = normalize(cross(nD, vec3<f32>(1.0, 0.0, 0.0)));
    }
    let g2 = cross(nD, g1);
    let P = vec2<f32>(dot(X, g1), dot(X, g2));
    let rho = length(P);
    if (rho > 20.0) { return vec4<f32>(0.0); }
    let th = atan2(P.y, P.x);
    let phB = atan2(dot(bDir, g2), dot(bDir, g1));

    // Keplerian shear without winding up forever: two copies of the texture, each sheared for
    // at most one flow period, cross-faded as they reset.
    let om = 0.9 * pow(max(rho, 0.6), -1.5);
    let per = 40.0;
    let f1 = fract(T / per);
    let f2 = fract(T / per + 0.5);
    let a1 = th - om * f1 * per;
    let a2 = th - om * f2 * per;
    let t1 = fbm(vec3<f32>(cos(a1) * rho, sin(a1) * rho, rho * 0.5) * 0.55);
    let t2 = fbm(vec3<f32>(cos(a2) * rho, sin(a2) * rho, rho * 0.5 + 9.0) * 0.55);
    let tex = mix(t1, t2, abs(2.0 * f1 - 1.0));

    // the circumbinary disk: brightest just outside the cavity, two arms raised by the binary
    let inner = smoothstep(cavity * 0.75, cavity * 1.25, rho);
    let prof = inner * exp(-rho / 4.5) * (1.0 - smoothstep(11.0, 20.0, rho)) * 1.1 * pow(cavity / max(rho, cavity * 0.75), 0.5);
    let arms = 1.0 + 0.45 * presence * cos(2.0 * (th - phB) + 2.2 * log(max(rho / cavity, 0.2)));
    let lump = 1.0 + 1.2 * presence * exp(-sq((rho - 1.25 * cavity) / (0.3 * cavity)))
                     * (0.5 + 0.5 * cos(th - T * 0.9 * pow(1.25 * cavity, -1.5)));
    var dens = prof * arms * lump * (0.35 + 1.3 * sq(tex));

    // streams from the cavity's edge down to the holes, trailing their orbit
    let inside = 1.0 - smoothstep(cavity * 0.9, cavity * 1.3, rho);
    let sp = 0.5 + 0.5 * cos(2.0 * (th - phB) - 3.0 * log(max(rho / cavity, 0.05)));
    let stream = pow(sp, 10.0) * inside * smoothstep(0.4 * sep, 0.9 * sep + 0.3, rho) * presence;
    dens += stream * (0.5 + tex) * 0.9;

    // mini-disks around each hole, and the remnant's own inner disk when it is alone
    var hot = vec3<f32>(0.0);
    for (var i = 0; i < 2; i++) {
        let c = select(cB, cA, i == 0);
        let r = select(rB, rA, i == 0);
        let w = select(presence, mix(1.0, 0.6, presence), i == 0);
        if (w <= 0.0 || r <= 0.0) { continue; }
        let size = select(clamp(0.3 * sep, 0.2, 1.4), mix(1.6, clamp(0.3 * sep, 0.4, 1.6), presence), i == 0);
        let d = length(X - c);
        var md = exp(-(d - r) / (0.35 * size)) * smoothstep(r, r * 2.5, d) * (1.0 - smoothstep(size, size * 2.2, d));
        let boost = select(1.0, 1.0 + 2.0 * afterglow, i == 0);
        md *= (0.6 + 0.8 * tex) * boost * w;
        dens += md * 1.5;
        hot += hotCol * md * 1.6;
    }
    if (dens < 1e-4) { return vec4<f32>(0.0); }
    // temperature falls as r^(-3/4): hot near the middle, cool and red outside
    let heat = saturate(1.4 * pow(cavity / max(rho, 0.3), 0.75) - 0.35);
    let c = nsmMix(coolCol, hotCol, heat * 0.7);
    // Doppler: the side turning toward us is brighter
    let vdir = normalize(cross(nD, X / max(rho, 1e-3)));
    let beam = 1.0 + 0.5 * dot(vdir, -rd) * saturate(1.5 / sqrt(max(rho, 0.5)));
    let em = (c * (dens - min(dens, length(hot) / 1.6)) + hot) * beam * (1.0 + 0.6 * afterglow * heat) * 0.6;
    let alpha = 1.0 - exp(-dens * 2.5);
    return vec4<f32>(em, alpha);
}

// The wave signal leaving the pair at tr (the time left before the merger then): amplitude, the
// orbit's angle, the orbital angular frequency (negative for the ringdown's), and the strain a
// detector sees, 1 at the merger (it grows as the frequency to the 2/3).
fn bbhSignal(tr: f32) -> vec4<f32> {
    let K = S.h.x;
    let phi0 = S.h.y;
    let tauC = S.h.z;
    let qnmW = S.j.x;
    let qnmT = S.j.y;
    if (tr > 0.0 && tr < tauC) {
        let trc = max(tr, 0.03);
        var omega = 0.625 * K * pow(trc, -0.375);
        var phiR = phi0 - K * pow(trc, 0.625);
        let fade = smoothstep(tauC, tauC * 0.6, tr);
        var amp = min(pow(omega / 0.4, 0.667), 2.2) * fade;
        var strain = pow(omega / (0.625 * K * 3.72), 0.667) * fade;    // 3.72 = 0.03^(-3/8)
        let ecc = S.n.y * smoothstep(0.3, 4.0, tr);
        if (ecc > 0.0) {
            // On an eccentric orbit the waves come in bursts at each close pass, where the
            // holes move fastest: Kepler's equation gives where the companion was.
            let peri = S.n.x;
            let m = phiR - peri;
            var E = m + ecc * sin(m);
            for (var i = 0; i < 4; i++) { E -= (E - ecc * sin(E) - m) / (1.0 - ecc * cos(E)); }
            let nu = 2.0 * atan2(sqrt(1.0 + ecc) * sin(0.5 * E), sqrt(1.0 - ecc) * cos(0.5 * E));
            let rr = 1.0 - ecc * cos(E);
            amp *= pow(1.0 - ecc, 1.5) / (rr * rr);
            strain *= pow(1.0 - ecc, 1.5) / (rr * rr);
            omega *= sqrt(1.0 - ecc * ecc) / (rr * rr);
            phiR = nu + peri - S.n.z * K * pow(trc, 0.625);
        }
        return vec4<f32>(amp, phiR, omega, strain);
    }
    // the ringdown picks up where the inspiral's phase left off
    if (tr <= 0.0 && tr > -6.0 * qnmT) {
        return vec4<f32>(2.2 * exp(tr / qnmT), phi0 - K * 0.112 + 0.5 * qnmW * tr, -qnmW, exp(tr / qnmT));   // 0.112 = 0.03^(5/8)
    }
    return vec4<f32>(0.0);
}

// A spiral galaxy far behind the pair, a little off the line through it, so the holes draw it
// into an Einstein ring that breaks into arcs as they move. dir is the (lensed) direction seen.
fn bbhGalaxy(dir: vec3<f32>, ro: vec3<f32>) -> vec3<f32> {
    let dist = length(ro);
    let l0 = -ro / dist;
    let v = (dir - l0 * dot(dir, l0)) * dist;
    let w = vec2<f32>(dot(v, F.camRight.xyz), dot(v, F.camUp.xyz)) - vec2<f32>(0.45, 0.3);
    let ca = cos(0.6);
    let sa = sin(0.6);
    let g = vec2<f32>(ca * w.x + sa * w.y, (-sa * w.x + ca * w.y) / 0.5);    // tilted to us
    let r = length(g);
    if (r > 5.0) { return vec3<f32>(0.0); }
    let th = atan2(g.y, g.x);
    let arms = 0.5 + 0.5 * cos(2.0 * th - 3.0 * log(max(r, 0.05)));
    let bulge = exp(-r / 0.2);
    let disk = exp(-r / 0.75) * (0.3 + 1.1 * pow(arms, 3.0)) * smoothstep(0.05, 0.35, r);
    // pink star-forming knots along the arms
    let knots = smoothstep(0.62, 0.8, noise3(vec3<f32>(g * 5.0, 2.0))) * pow(arms, 4.0) * exp(-r / 1.2);
    return vec3<f32>(1.0, 0.78, 0.5) * bulge * 1.2 + vec3<f32>(0.45, 0.65, 1.0) * disk * 0.65
         + vec3<f32>(1.0, 0.3, 0.6) * knots * 1.0;
}

// A quasar's gas disk around a stellar pair. The disk circles a supermassive hole far beyond the
// frame, so here it is a broad sheet flowing one way, faster on the side nearer that hole
// (shear), brighter toward it. The pair has blown a small hollow. After the merger the kicked
// remnant heats the gas round it (the flare) and leaves a hot wake along its path.
fn bbhAgn(X: vec3<f32>, nD: vec3<f32>, cA: vec3<f32>, rA: f32, cB: vec3<f32>, rB: f32, flare: f32, vel: vec3<f32>,
          hotCol: vec3<f32>, coolCol: vec3<f32>, T: f32) -> vec4<f32> {
    var g1: vec3<f32>;
    if (abs(nD.y) < 0.9) {
        g1 = normalize(cross(nD, vec3<f32>(0.0, 1.0, 0.0)));
    } else {
        g1 = normalize(cross(nD, vec3<f32>(1.0, 0.0, 0.0)));
    }
    let g2 = cross(nD, g1);
    let P = vec2<f32>(dot(X, g1), dot(X, g2));
    let R = length(P);
    if (R > 60.0) { return vec4<f32>(0.0); }
    let per = 50.0;
    let f1 = fract(T / per);
    let f2 = fract(T / per + 0.5);
    let sp0 = 0.35 + 0.02 * P.y;
    let t1 = fbm(vec3<f32>((P.x - sp0 * f1 * per) * 0.3, P.y * 0.45, 0.0));
    let t2 = fbm(vec3<f32>((P.x - sp0 * f2 * per) * 0.3, P.y * 0.45, 5.0));
    let tex = mix(t1, t2, abs(2.0 * f1 - 1.0));
    var dens = (0.25 + 1.1 * sq(tex)) * min(exp(P.y / 18.0), 1.6) * (1.0 - smoothstep(25.0, 60.0, R));
    let d = length(X - cA);
    var hollow = smoothstep(rA * 1.5, rA * 7.0, d);
    if (rB > 0.0) { hollow *= smoothstep(rB * 1.5, rB * 7.0, length(X - cB)); }
    dens *= hollow;
    var em = nsmMix(coolCol, hotCol, saturate(0.15 + 0.45 * tex)) * dens * 0.1;
    em += hotCol * flare * exp(-d / 2.2) * (0.3 + 0.4 * tex) * smoothstep(rA * 1.2, rA * 3.0, d);
    let sp = length(vel);
    if (sp > 1e-3) {
        let vd = vel / sp;
        let along = dot(X - cA, -vd);
        let off = length(X - cA + vd * along);
        let wk = exp(-sq(off / (0.25 + 0.06 * max(along, 0.0)))) * smoothstep(0.0, 0.6, along) * exp(-max(along, 0.0) / 4.0);
        em += hotCol * wk * min(sp * 3.0, 1.2);
    }
    return vec4<f32>(em, 1.0 - exp(-dens * 0.45));
}

// The strain a detector would record at tr, scaled to about -1..1, with a little detector noise.
fn bbhStrain(tr: f32) -> f32 {
    let sig = bbhSignal(tr);
    let noise = 0.05 * (hash13(vec3<f32>(floor(tr * 160.0), 3.0, 1.0)) - 0.5);
    return sig.w * cos(2.0 * sig.y) + noise;
}

@fragment
fn blackHoleMergerFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    let T = S.p.w;
    let flags = i32(S.o.w + 0.5);

    let cA = S.a.xyz;
    let cB = S.b.xyz;
    let n = S.c.xyz;
    let e1 = S.d.xyz;
    let e2 = cross(n, e1);
    let rA = S.a.w;
    let rB = S.b.w;
    let tau = S.d.w;
    let presence = S.e.w;
    let age = S.f.w;
    let ringCol = S.e.rgb;
    let hotCol = S.f.rgb;
    let coolCol = S.g.rgb;
    let model = i32(S.g.w + 0.5);
    let harm = S.h.w;
    let O = S.o.xyz;
    let chi = S.i.z;
    let ringBoost = S.i.w;
    let qnmW = S.j.x;
    let qnmT = S.j.y;
    let cavity = S.j.z;
    let afterglow = S.j.w;
    // two lobes: the pair, or, just after the merger, the remnant's two lobes running together
    let pair = S.b.w > 0.0;
    let pixW = F.pixelAngle * length(ro);
    let sep = length(cB - cA);
    let W = S.c.w;

    // ---- lensing: the direction each pixel sees, past both holes ----
    var bA = 0.0;
    var bB = 1e9;
    var perpA = vec3<f32>(0.0);
    var perpB = vec3<f32>(0.0);
    var shift = bbhLens(ro, rd, cA, S.i.x, &bA, &perpA);
    if (pair) { shift += bbhLens(ro, rd, cB, S.i.y, &bB, &perpB); }
    let rs = normalize(rd + shift);

    // ---- the shadows: one per hole, run together as they touch ----
    // In the last moments tides stretch each shadow toward the other, and they join through a
    // widening neck. After the merger the two lobes keep turning as they run together (the
    // CPU side moves them), a peanut rounding out as the ringdown carries its lumps away.
    let dC = 0.8 * (rA + rB);
    let axis = cB - cA;
    var tide = 0.0;
    var neck = 0.0;
    if (pair) {
        tide = 0.35 * smoothstep(2.2 * dC, 1.05 * dC, sep) * S.n.w;
        neck = 0.6 * rB * smoothstep(1.6 * dC, 1.05 * dC, sep);
    }
    // The remnant spins: its shadow is flattened and shifted on the side turning toward us
    // (photons going with the spin can orbit closer), most when we see the spin side-on.
    let lA = normalize(cA - ro);
    let sAx = S.k.xyz - lA * dot(S.k.xyz, lA);
    let side = length(sAx);
    var wA = F.camRight.xyz;
    if (side > 1e-3) { wA = cross(lA, sAx / side); }
    let flat_ = 0.2 * chi * side;
    let x = dot(perpA, wA);
    let rAe = rA * (1.0 + 0.04 * flat_ - flat_ * sq(max(x, 0.0)));
    let dA = bA * bbhStretch(perpA, lA, axis, tide) - rAe;
    var dS = dA;
    var rRef = rA;
    if (pair) {
        let dB = bB * bbhStretch(perpB, normalize(cB - ro), axis, tide) - rB;
        dS = bbhSmin(dA, dB, 0.45 * rB + 0.02 + neck);
        if (dB < dA) { rRef = max(rB, 0.15); }
    }
    let soft = max(pixW * 0.9, 0.025 * rRef);
    let shadow = 1.0 - smoothstep(-soft, soft, dS);
    // close to the shadow the lensed sky is too crushed to resolve: it fades into the ring
    let crush = smoothstep(0.15 * rRef, 0.9 * rRef, dS);

    // ---- gravitational waves in the orbital plane, as in the neutron star merger ----
    let dn = dot(rd, n);
    let tp = -dot(ro - O, n) / select(1e-4, dn, abs(dn) > 1e-4);
    var wave = 0.0;
    var disp = vec2<f32>(0.0);
    if (tp > 0.0 && W > 0.0) {
        let xp = ro + rd * tp - O;
        let rho = length(xp);
        let tr = tau + rho / BBH_V;
        let th = atan2(dot(xp, e2), dot(xp, e1));
        let foot = F.pixelAngle * tp / max(abs(dn), 0.05);
        let sig = bbhSignal(tr);
        var amp = sig.x;
        let psi = 2.0 * (th - sig.y);
        var h3 = 0.0;
        // waves shorter than a few pixels would only alias: fade them out
        amp *= smoothstep(foot * 4.0, foot * 10.0, 3.14159 * BBH_V / abs(sig.z + 1e-4));
        if (sig.z > 0.0) {
            // an unequal pair also radiates at three times the orbital frequency: a third arm
            h3 = harm * 0.6 * min(pow(sig.z / 0.6, 0.333), 1.6);
            // the calm near zone round the source: the pair's size, at least the joined shadow's,
            // so it doesn't vanish when the companion does
            let src = max(select(0.0, sep, pair), 0.8 * (rA + rB));
            amp *= smoothstep(0.5 * src, 1.5 * src + 0.5, rho);
        }
        amp *= smoothstep(0.3, 1.4, rho) / (1.0 + rho / 6.0);
        wave = amp * (cos(psi) + h3 * cos(1.5 * psi));
        let er = xp / max(rho, 1e-3);
        let gw = amp * (sin(psi) + h3 * 1.5 * sin(1.5 * psi)) * W;
        disp = vec2<f32>(dot(er, F.camRight.xyz), -dot(er, F.camUp.xyz)) * gw * 2.4;
    }

    // ---- the sky, seen through both lenses and the waves ----
    let lp = vec2<f32>(dot(rs - rd, F.camRight.xyz), -dot(rs - rd, F.camUp.xyz)) / F.pixelAngle;
    let qp = vec2<i32>(p) + vec2<i32>(round(lp + disp));
    let Wd = i32(F.camRight.w);
    let Hd = i32(F.camUp.w);
    let q = vec2<u32>(u32(bbhMirror(qp.x, Wd)), u32(bbhMirror(qp.y, Hd)));
    var col = SKY(q, rs, false) * crush;
    col *= clamp(1.0 + 0.06 * wave * W, 0.75, 1.3);
    // a faint sheen on the wavefronts against the dark
    col += ringCol * sq(max(wave, 0.0)) * 0.004 * W;
    if ((flags & 2) != 0) { col += bbhGalaxy(rs, ro) * crush; }

    // ---- an intermediate pair's star cluster, lensed like the sky ----
    if (model == 1) {
        let toCam = normalize(ro);
        let tz = -dot(ro, toCam) / min(dot(rs, toCam), -1e-3);
        let X = ro + rs * tz;
        let w2 = vec2<f32>(dot(X, F.camRight.xyz), dot(X, F.camUp.xyz));
        let rc = 4.5;
        let r2 = dot(w2, w2) / (rc * rc);
        let king = pow(1.0 + r2, -1.5);
        // unresolved stars: a soft warm glow
        let glow = mix(coolCol, vec3<f32>(dot(coolCol, vec3<f32>(0.33))), 0.4) * (0.05 * king + 0.006 / (1.0 + r2));
        var stars = vec3<f32>(0.0);
        let cs = pixW * 6.0;
        for (var L = 0; L < 3; L++) {
            // each layer of orbits turns its own way: a cluster's stars move every which way
            let om = select(select(0.005, -0.008, L == 1), 0.012, L == 0);
            let ca = cos(om * T);
            let sa = sin(om * T);
            let wr = vec2<f32>(ca * w2.x - sa * w2.y, sa * w2.x + ca * w2.y);
            let cell = floor(wr / cs);
            let hs = vec3<f32>(cell, f32(L) * 17.0 + 3.0);
            let h0 = hash13(hs);
            let h1 = hash13(hs + 11.0);
            let h2 = hash13(hs + 23.0);
            let h3s = hash13(hs + 37.0);
            if (h0 > 0.5 * king + 0.01) { continue; }
            let c = (cell + 0.2 + 0.6 * vec2<f32>(h1, h2)) * cs;
            let d = length(wr - c);
            let br = 0.15 + 2.5 * pow(h3s, 6.0);
            let sz = pixW * (0.55 + 0.5 * h3s);
            // mostly old red giants, some hot blue stragglers
            let sc = select(mix(coolCol, vec3<f32>(dot(coolCol, vec3<f32>(0.33))) * 1.2, 0.5 * h2), hotCol, h1 > 0.8);
            stars += sc * br * exp(-sq(d / sz));
        }
        col += (glow + stars) * crush;
    }

    // ---- a supermassive pair's gas. Light from the disk's far side passes the holes on its
    // way to us and is bent, more the farther behind them it starts; the near side is seen
    // directly and hides the shadows behind it ----
    var front = vec4<f32>(0.0);
    let nD = S.m.xyz;
    if (model >= 2) {
        let toCam = normalize(ro);
        let df = dot(rd, nD);
        if (abs(df) > 1e-4) {
            let tf = -dot(ro - O, nD) / df;
            let behind = -dot(ro + rd * tf - O, toCam);
            let rg = normalize(rd + shift * smoothstep(0.0, 4.0, behind));
            let dg = dot(rg, nD);
            var tg = -1.0;
            if (abs(dg) > 1e-4) { tg = -dot(ro - O, nD) / dg; }
            if (tg > 0.0) {
                let X = ro + rg * tg - O;
                var g: vec4<f32>;
                if (model == 2) {
                    g = bbhGas(X, rg, nD, cA - O, cB - O, rA, rB, cos(S.m.w) * e1 + sin(S.m.w) * e2, presence, sep, cavity, afterglow, hotCol, coolCol, T);
                } else {
                    g = bbhAgn(X + O, nD, cA, rA, cB, select(0.0, rB, pair), afterglow, S.p.xyz, hotCol, coolCol, T);
                }
                if (dot(X, toCam) > 0.0) {
                    front = g;
                } else {
                    col = col * (1.0 - g.a) + g.rgb * crush;
                }
            }
        }
        // jets along the remnant's spin, and the fading ones of the remnant before it
        var jn = 0.0;
        var jo = 0.0;
        if (S.k.w > 0.0) { jn = bbhJet(ro, rd, cA, S.k.xyz, T, pixW) * S.k.w; }
        if (S.l.w > 0.0) { jo = bbhJet(ro, rd, cA, S.l.xyz, T, pixW) * S.l.w; }
        col += mix(hotCol, vec3<f32>(dot(hotCol, vec3<f32>(0.33))), 0.3) * (jn + jo) * 0.6;
        if (model == 3 && afterglow > 0.0) {
            // the flare's light, a soft glow round the remnant
            let d0 = length(cross(rd, cA - ro));
            col += hotCol * afterglow * (exp(-d0 / 1.2) * 0.45 + exp(-d0 / 5.0) * 0.1);
        }
    }

    // ---- shadows and photon rings ----
    col *= 1.0 - shadow;
    let wR = max(0.1 * rRef, pixW * 1.2);
    var ring = exp(-sq(dS / wR)) * 0.7 + exp(-max(dS, 0.0) / (0.3 * rRef)) * 0.2 * (1.0 - shadow);
    // the faint inner ring of light that went round the hole once more
    ring += exp(-sq((dS - 0.06 * rRef) / (wR * 0.5))) * 0.25;
    col += ringCol * ring * ringBoost;

    col = col * (1.0 - front.a) + front.rgb;

    // ---- the strain trace: the signal as a detector records it, the newest at the right ----
    if ((flags & 1) != 0) {
        let Hf = F.camUp.w;
        let Wf = F.camRight.w;
        let yc = Hf * 0.86;
        let hh = Hf * 0.055;
        let px = in.pos.x;
        let py = in.pos.y;
        let dy = abs(py - yc);
        if (dy < hh * 1.8) {
            let span = 4.0;      // seconds across the screen
            let yA = yc - bbhStrain(tau + (1.0 - px / Wf) * span) * hh;
            let yB = yc - bbhStrain(tau + (1.0 - (px + 1.0) / Wf) * span) * hh;
            let lo = min(yA, yB) - 0.5;
            let hi = max(yA, yB) + 0.5;
            let dd = max(max(lo - py, py - hi), 0.0);
            let fade = smoothstep(0.0, 0.3, px / Wf) * smoothstep(1.0, 0.98, px / Wf);
            col *= 1.0 - 0.45 * smoothstep(hh * 1.8, hh * 1.2, dy) * fade;
            col += ringCol * exp(-sq(dd / 0.8)) * fade;
        }
    }
    return finalize(col, p);
}
