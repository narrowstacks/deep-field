// ---------- per-frame: pulsar ---------- (ShaderPulsar.swift)
// S.a = magnetic axis, beam half-width (rad); S.b = spin axis, flash;
// S.c = beam color x intensity, beams on (bit 0: the pole on the spin axis' north side, bit 1: the other);
// S.d = nebula color x intensity (0 = off), field style (0 off, 1 lines, 2 magnetar lobes);
// S.e = field color x intensity, beam trail (radians the beam winds back per unit of length);
// S.f = dust ring color x intensity (0 = off).
// (rotateAbout, also from this Metal file, lives in common.wgsl.)

// The span of segment s (t0, t1) where A t^2 + B t + C >= 0, as a hull (x > y when empty).
fn quadSpan(A: f32, B: f32, C: f32, s: vec2<f32>) -> vec2<f32> {
    let disc = B * B - 4.0 * A * C;
    if (abs(A) < 1e-6) { return s; }                    // nearly linear: keep the whole segment
    if (disc < 0.0) { return select(vec2<f32>(1.0, 0.0), s, A > 0.0); }
    let q = sqrt(disc);
    let r0 = (-B - q) / (2.0 * A);
    let r1 = (-B + q) / (2.0 * A);
    let lo = min(r0, r1);
    let hi = max(r0, r1);
    if (A < 0.0) { return vec2<f32>(max(s.x, lo), min(s.y, hi)); }
    // inside on both sides of the roots
    return vec2<f32>(select(max(s.x, hi), s.x, lo > s.x), select(min(s.y, lo), s.y, hi < s.y));
}

fn spanUnion(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    if (a.x > a.y) { return b; }
    if (b.x > b.y) { return a; }
    return vec2<f32>(min(a.x, b.x), max(a.y, b.y));
}

// One lighthouse beam, integrated along the ray in closed form instead of marched (it is far
// thinner than a march step): a narrow cone around the half-line s * axis, s > 0, wound back
// behind the rotation by `trail` radians per unit of length. Returns (glow, hot core) and, in
// tHit, the ray distance where the ray passes closest to it.
fn beamLight(ro: vec3<f32>, rd: vec3<f32>, axis: vec3<f32>, spin: vec3<f32>, w: f32, trail: f32,
             pixAng: f32, T: f32, tHit: ptr<function, f32>) -> vec2<f32> {
    var ax = axis;
    var t = 0.0;
    var s = 0.0;
    var den = 1.0;
    for (var it = 0; it < 2; it++) {
        // closest approach between the ray and the line through the star along ax
        let b = dot(rd, ax);
        let e = dot(ax, ro);
        let dd = dot(rd, ro);
        den = max(1.0 - b * b, 1e-5);
        t = (b * e - dd) / den;
        s = e + t * b;
        // (straightened where we look along it: there the closest point is ill-defined)
        if (it == 0) { ax = rotateAbout(axis, spin, -trail * clamp(s, 0.0, 40.0) * smoothstep(0.05, 0.4, sqrt(den))); }
    }
    *tHit = t;
    if (s < 0.15 || t < 0.0) { return vec2<f32>(0.0); }
    let d0 = length(ro + rd * t - ax * s);
    let ws = w * s;
    if (d0 > ws * 12.0) { return vec2<f32>(0.0); }
    // fades with distance from the star, and where it passes close to the camera
    let along = smoothstep(0.15, 0.9, s) * exp(-s / 16.0) * smoothstep(6.0, 16.0, length(ax * s - ro));
    // A longer path through it when it points our way. Seen almost end-on the closest point is
    // ill-defined, so there the beam hands over to the flash glare (computed on the CPU).
    let sinPhi = sqrt(den);
    let path = smoothstep(0.08, 0.3, sinPhi) / max(sinPhi, 0.25);
    let wc = max(ws * 0.13, pixAng * t * 0.6);        // the hot core, at least a pixel wide
    // knots streaming outward (smoothed out where we look down the beam, or they read as rings)
    let knots = mix(1.0, 0.7 + 0.6 * noise3(vec3<f32>(s * 0.8 - T * 3.0, dot(axis, spin) * 7.0, 0.0)), max(sinPhi, 0.25));
    let wg = ws * 0.4;
    let glow = (exp(-(d0 * d0) / (wg * wg)) * knots + exp(-(d0 * d0) / (ws * ws)) * 0.25 + exp(-d0 / (ws * 1.5)) * 0.03) * along * path;
    let core = exp(-(d0 * d0) / (wc * wc)) * (ws * 0.13 / wc) * along * path * (0.85 + 0.3 * knots);
    return vec2<f32>(glow, core);
}

@fragment
fn pulsarFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    let T = F.time;

    let m = S.a.xyz;
    let spin = S.b.xyz;
    let b1 = normalize(cross(spin, m) + vec3<f32>(1e-6, 0.0, 0.0));
    let b2 = cross(m, b1);
    let w = S.a.w;
    let beamCol = S.c.rgb;
    let nebCol = S.d.rgb;
    let fieldCol = S.e.rgb;
    let ringCol = S.f.rgb;
    let beams = i32(S.c.w + 0.5);
    let fieldStyle = i32(S.d.w + 0.5);
    let nebulaOn = dot(nebCol, vec3<f32>(1.0)) > 0.0;
    let ringOn = dot(ringCol, vec3<f32>(1.0)) > 0.0;
    let tc = -dot(ro, rd);
    let dmin = length(ro + rd * tc);

    // dust ring: a thin, clumpy sheet in the spin plane, lit by the star from inside and
    // brightest where it scatters starlight toward us. Whatever lies behind it is dimmed.
    var tRing = 1e9;
    var ringT = 1.0;
    var ringEm = vec3<f32>(0.0);
    if (ringOn) {
        let sd = dot(rd, spin);
        let tp = -dot(ro, spin) / select(1e-4, sd, abs(sd) > 1e-4);
        let xp = ro + rd * tp;
        let rp = length(xp);
        if (tp > 0.0 && rp > 1.5 && rp < 7.6) {
            let e1 = normalize(cross(spin, vec3<f32>(1.0, 0.0, 0.0)));
            let e2 = cross(spin, e1);
            // turning slowly as a whole (true Keplerian shear would wind the clumps into grooves),
            // while the clumps themselves churn
            let az = atan2(dot(xp, e2), dot(xp, e1)) - T * 0.04;
            let pp = vec2<f32>(cos(az), sin(az)) * rp;
            let prof = smoothstep(1.6, 2.1, rp) * (1.0 - smoothstep(4.0, 7.5, rp));
            let lanes = 0.75 + 0.25 * sin(rp * 5.0 + 3.0 * noise3(vec3<f32>(pp * 0.6, T * 0.01)));
            let clumps = fbm(vec3<f32>(pp * 1.6, 3.0 + T * 0.015));
            let dens = prof * lanes * (0.15 + 1.4 * smoothstep(0.3, 0.8, clumps));
            let slant = 1.0 / max(abs(sd), 0.18);
            let fwd = pow(max(dot(normalize(xp), -rd), 0.0), 6.0);
            let lit = 2.5 / (rp * rp) * (0.3 + 2.5 * fwd) + 0.6 * exp(-(rp - 1.9) * 4.0);   // hot inner rim
            ringEm = ringCol * dens * lit * min(slant, 3.0) * 0.6;
            ringT = exp(-dens * 1.6 * slant);
            tRing = tp;
        }
    }
    var col = SKY(p, rd, false) * ringT;

    const Rv: f32 = 14.0;
    if (dmin < Rv) {
        let half_ = sqrt(Rv * Rv - dmin * dmin);
        const N: i32 = 48;
        let dt = 2.0 * half_ / f32(N);
        // Each feature only touches a bounded region, so every sample first checks cheaply
        // whether it is inside one (cut-offs are where a term falls below about e^-12) and
        // only then pays for its exp and noise. Only the stretch of the ray that can reach a
        // feature is marched: the jet cylinder (radius 3.8 around the spin axis) and the
        // sphere holding the torus and the field (radius 7.8). The samples stay on one grid.
        let fieldOn = fieldStyle > 0;
        var lineAcc = 0.0;
        var lobeAcc = 0.0;
        var nebAcc = 0.0;
        let t0 = tc - half_;
        let seg = vec2<f32>(t0, tc + half_);
        let ro2 = dot(ro, ro);
        let rord = dot(ro, rd);
        var span = vec2<f32>(1.0, 0.0);
        if (nebulaOn) {
            let s0 = dot(ro, spin);
            let s1 = dot(rd, spin);
            span = quadSpan(s1 * s1 - 1.0, -2.0 * (rord - s0 * s1), 3.8 * 3.8 - ro2 + s0 * s0, seg);
        }
        let Rs = select(6.6, 7.8, nebulaOn);
        if (fieldOn || nebulaOn) { span = spanUnion(span, quadSpan(-1.0, -2.0 * rord, Rs * Rs - ro2, seg)); }
        var iLo = 0;
        var iHi = -1;
        if (span.x <= span.y) {
            iLo = max(i32(floor((span.x - t0) / dt - 0.5)), 0);
            iHi = min(i32(ceil((span.y - t0) / dt - 0.5)), N - 1);
        }
        for (var i = iLo; i <= iHi; i++) {
            let ti = t0 + (f32(i) + 0.5) * dt;
            let x = ro + rd * ti;
            let r2 = dot(x, x);
            if (r2 < 0.09) { continue; }
            let r = sqrt(r2);
            let wgt = select(1.0, ringT, ti > tRing);
            if (fieldOn && r < 6.5) {
                let c = dot(x, m) / r;
                let s2 = max(1.0 - c * c, 1e-3);
                let L = r / s2;                       // dipole field lines: r = L sin^2(theta)
                if (fieldStyle == 1) {
                    // three planes around the magnetic axis
                    if (L > 1.5 && L < 6.5) {
                        // cos(3 * azimuth) from cos(azimuth), instead of atan2 then cos
                        let u = dot(x, b1);
                        let v = dot(x, b2);
                        let rho = sqrt(u * u + v * v);
                        let ca = select(1.0, u / rho, rho > 1e-6);
                        let c3 = ca * (4.0 * ca * ca - 3.0);
                        if (c3 > 0.0) {
                            var lines = 0.0;
                            for (var k = 0; k < 3; k++) {
                                let Lk = 2.0 + 1.6 * f32(k);
                                let e = (L - Lk) / (0.06 * Lk);
                                lines += exp(-e * e);
                            }
                            let h1 = 0.5 + 0.5 * c3;
                            let h2 = h1 * h1;
                            let h4 = h2 * h2;
                            let h8 = h4 * h4;
                            // charges streaming along the lines, pole to pole
                            let flow = 0.6 + 0.8 * smoothstep(0.55, 0.95, sin(c * 9.0 - T * 2.0 + L * 2.0) * 0.5 + 0.5);
                            lineAcc += lines * (h8 * h8 * h8) * smoothstep(0.3, 0.6, r) * flow * wgt;   // ^24
                        }
                    }
                } else if (L < 7.0) {
                    // magnetar: the whole field glows, in nested shells drifting outward
                    let sh = 0.5 + 0.5 * cos(6.2831853 * (L * 0.85 - T * 0.12));
                    let lobe = exp(-L / 1.7) * (0.3 + 0.7 * sh * sh) * smoothstep(1.0, 1.7, L) * smoothstep(6.8, 5.5, L);
                    lobeAcc += lobe * (0.7 + 0.6 * noise3(x * 1.3 + vec3<f32>(0.0, T * 0.25, 0.0))) * wgt;
                }
            }
            if (nebulaOn) {
                // pulsar wind nebula: an equatorial torus and two polar jets, both churning
                let hgt = dot(x, spin);
                let ah = abs(hgt);
                let perp = sqrt(max(r2 - hgt * hgt, 0.0));
                let dp = perp - 4.2;
                let tq = (dp * dp + hgt * hgt * 3.0) / 0.9;
                if (tq < 12.0) {
                    let churn = noise3(x * 0.9 + vec3<f32>(0.0, T * 0.15, 0.0));
                    nebAcc += exp(-tq) * (0.4 + 0.9 * churn) * 0.07 * wgt;
                }
                let jq = perp / (0.25 + 0.06 * ah);
                if (ah > 0.6 && jq < 3.5) {
                    let churn = noise3(x * 1.4 - vec3<f32>(0.0, T * 0.6 * sign(hgt), 0.0));
                    nebAcc += exp(-jq * jq) * exp(-ah / 5.0) * smoothstep(0.6, 1.6, ah) * (0.4 + 0.9 * churn) * 0.22 * wgt;
                }
            }
        }
        col += (fieldCol * (lineAcc * 0.14 + lobeAcc * 0.16) + nebCol * nebAcc) * dt;
    }

    // the lighthouse beams: a white-hot core inside a colored glow
    if (beams > 0) {
        let coreCol = mix(beamCol, vec3<f32>(dot(beamCol, vec3<f32>(0.33))), 0.6) * 1.6;
        for (var k = 0; k < 2; k++) {
            if ((beams & (1i << u32(k))) == 0) { continue; }
            var tHit = 0.0;
            let bl = beamLight(ro, rd, select(-m, m, k == 0), spin, w, S.e.w, F.pixelAngle, T, &tHit);
            let vis = select(1.0, ringT, tHit > tRing);
            col += (beamCol * bl.x * 1.0 + coreCol * bl.y * 2.4) * vis;
        }
    }

    // the neutron star: tiny, white-hot, brightest at its magnetic poles
    let starVis = select(1.0, ringT, tc > tRing);
    let b = dot(ro, rd);
    let disc = b * b - (dot(ro, ro) - 0.09);
    if (disc > 0.0) {
        let P = ro + rd * (-b - sqrt(disc));
        let pole = pow(abs(dot(normalize(P), m)), 8.0);
        col = mix(col, vec3<f32>(0.85, 0.92, 1.0) * (2.0 + 4.0 * pole), starVis);
    }
    col += vec3<f32>(0.8, 0.9, 1.0) * (exp(-dmin / 0.35) * 1.2 + exp(-dmin / 1.5) * 0.12) * starVis;
    col += ringEm;

    // the lighthouse flash when a beam sweeps past us: a glare around the star with a glint
    // of spikes, not a full-screen blink
    let fl = S.b.w;
    if (fl > 0.001) {
        let wv = ro + rd * tc;
        let wx = abs(dot(wv, F.camRight.xyz));
        let wy = abs(dot(wv, F.camUp.xyz));
        let spikes = exp(-wy / 0.04) * exp(-wx / 1.6) + exp(-wx / 0.04) * exp(-wy / 1.1);
        col += (beamCol * (exp(-dmin / 1.1) * 1.8 + exp(-dmin / 2.5) * 0.15) + mix(beamCol, vec3<f32>(1.0), 0.5) * spikes * 1.2) * fl * starVis;
    }
    return finalize(col, p);
}
