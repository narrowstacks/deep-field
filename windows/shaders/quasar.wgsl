// ---------- per-frame: quasar ----------
// Port of ShaderQuasar.swift. Uses galaxyVelocity and flowingDisk from galaxy.wgsl.
// An active galaxy: a spiral disk around a blazing nucleus, a clumpy dusty torus, and two
// relativistic jets along the spin axis ending in radio lobes. World space, nucleus at the origin.
// S.a = jet axis (toward the approaching jet), jet length; S.b = disk axis e1, approaching knot travel;
// S.c = jet color, receding knot travel; S.d = lobe color, jet brightness;
// S.e = approaching beaming, receding beaming, galaxy brightness, arm pattern angle;
// S.f = core flare boost, flare knot position (approaching), flare knot brightness, flare knot position (receding);
// S.g = helix phase, lobe drift, hot spot boost, torus transmission toward us.

const QSR_GALAXY_R: f32 = 4.4;
const QSR_TORUS_R: f32 = 0.55;
const QSR_TORUS_A: f32 = 0.22;
const QSR_TORUS_K: f32 = 5.0;
const QSR_KNOT_GAP: f32 = 1.4;

// Dust density of the clumpy torus at P (axis n): a ring of clouds orbiting the nucleus.
fn qsrTorus(P: vec3<f32>, n: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, time: f32) -> f32 {
    let h = dot(P, n);
    let pl = vec2<f32>(dot(P, e1), dot(P, e2));
    let rho = length(pl);
    let d2 = ((rho - QSR_TORUS_R) * (rho - QSR_TORUS_R) + h * h) / (QSR_TORUS_A * QSR_TORUS_A);
    if (d2 > 9.0) { return 0.0; }
    // clouds carried round at the orbital speed (slowed down)
    let a = atan2(pl.y, pl.x) - time * 0.06;
    let clump = noise3(vec3<f32>(cos(a) * 2.6, sin(a) * 2.6, h * 14.0) + vec3<f32>(rho * 18.0, 0.0, 0.0));
    return QSR_TORUS_K * exp(-d2) * (0.25 + 1.5 * clump * clump);
}

// The jet's centerline: the axis plus a slowly precessing helix whose pattern moves outward.
fn qsrJetPoint(z: f32, J: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, phase: f32, side: f32) -> vec3<f32> {
    let amp = 0.045 * smoothstep(0.3, 3.5, z) * (1.0 + 0.05 * z);
    let psi = z * 1.1 - phase + side * 1.3;
    return J * z + amp * (cos(psi) * e1 + sin(psi) * e2);
}

// Radio lobe density at X for the jet along J ending at length L: a cocoon of plasma that
// backflows from the hot spot toward the core, broad at the head and tapering behind it.
fn qsrLobe(X: vec3<f32>, J: vec3<f32>, L: f32, drift: f32, side: f32) -> f32 {
    let zl = dot(X, J) - 0.86 * L;
    let q = length(X - J * dot(X, J));
    let rad = L * (0.05 + 0.09 * smoothstep(-0.4 * L, 0.06 * L, zl));
    let shape = exp(-(zl * zl) / (0.03 * L * L) - (q * q) / (rad * rad));
    if (shape < 0.004) { return 0.0; }
    let w = X / L * 4.0 + vec3<f32>(side * 11.0, drift, -drift * 0.7);
    let warp = vec3<f32>(noise3(w * 0.8 + 5.0), noise3(w * 0.8 - 3.0), noise3(w * 0.8 + 9.0)) - 0.5;
    let tex = fbm(w + warp * 1.6);
    return shape * smoothstep(0.3, 0.85, tex) * (0.3 + 1.2 * tex);
}

@fragment
fn quasarFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    var col = SKY(p, rd, false);

    let n = S.a.xyz;
    let e1 = S.b.xyz;
    let e2 = cross(n, e1);
    let L = S.a.w;
    let jetCol = S.c.rgb;
    let lobeCol = S.d.rgb;
    let jetB = S.d.w;
    let galB = S.e.z;
    let coreBoost = S.f.x;
    let time = F.time;
    let R = QSR_GALAXY_R;
    let tClose = -dot(ro, rd);
    let dCore = length(ro + rd * tClose);

    // ---- host galaxy ----
    // the bulge, an ellipsoid flattened along the axis, integrated along the ray
    let o2 = vec3<f32>(dot(ro, e1), dot(ro, e2), dot(ro, n) / 0.55);
    let d2 = normalize(vec3<f32>(dot(rd, e1), dot(rd, e2), dot(rd, n) / 0.55));
    let s = length(o2 + d2 * max(-dot(o2, d2), 0.0)) / (0.1 * R);
    let oldCol = vec3<f32>(1.0, 0.68, 0.4) * 0.75;
    let youngCol = vec3<f32>(0.45, 0.62, 1.0) * 0.8;
    let hiiCol = vec3<f32>(1.0, 0.3, 0.45) * 0.9;
    var bulge = oldCol * (exp(-3.2 * pow(s, 0.65)) * 2.4 + exp(-s * 0.4) * 0.05) * galB;
    bulge *= mix(vec3<f32>(1.0), vec3<f32>(1.08, 0.95, 0.82), exp(-s * 1.5));
    col += oldCol * exp(-dCore / (0.45 * R)) * 0.03 * galB;   // faint stellar halo

    let dn = dot(rd, n);
    let tD = -dot(ro, n) / dn;
    var emission = vec3<f32>(0.0);
    var dustOpacity = 0.0;
    var frontFrac = 1.0;
    var rDisk = 1e4;
    if (tD > 0.0) {
        let P = ro + rd * tD;
        let pl = vec2<f32>(dot(P, e1), dot(P, e2));
        rDisk = length(pl);
        let r = rDisk / R;
        frontFrac = smoothstep(-1.0, 1.0, clamp((tD - tClose) / (0.12 * R), -1.0, 1.0));
        if (r < 1.2 && galB > 0.0) {
            let phi = atan2(pl.y, pl.x);
            let path = clamp(0.3 / abs(dn), 1.0, 4.0);
            let fp = F.pixelAngle * tD / (R * max(abs(dn), 0.08));
            // flat rotation curve: an edge star goes round in eight minutes
            let omega = 0.0131 * galaxyVelocity(r, true) / max(r, 0.01);
            let clumps = flowingDisk(r, phi, omega, time, 72.0, 9.0, fp * 9.0);
            let fine = flowingDisk(r, phi, omega, time, 72.0, 26.0, fp * 26.0);
            let smoothDisk = exp(-r / 0.3) * (1.0 - smoothstep(0.7, 1.1, r));
            // two density-wave arms turning at the pattern speed
            let r0 = 0.12;
            let psi = 2.0 * (phi - S.e.w - log(max(r, 0.02) / r0) / 0.62);
            let env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
            let wave = 0.5 + 0.5 * cos(psi);
            let arm = (pow(wave, 3.0) * 0.8 + pow(wave, 12.0) * 0.5) * env * (0.55 + 0.75 * fine);
            // dust lane on the arm's inner edge, star-forming knots just past it
            let lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * smoothstep(r0 * 0.3, r0 * 1.1, r) * (1.0 - smoothstep(0.7, 1.05, r));
            let knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
            dustOpacity = lane * (0.3 + 0.7 * clumps) * (0.35 + 0.9 * fine) * 1.45
                        + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12
                        + exp(-r / 0.35) * (1.0 - smoothstep(0.6, 1.0, r)) * (0.05 + 0.08 * clumps);
            let knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            let armCol = mix(youngCol, mix(youngCol, vec3<f32>(1.0), 0.45), exp(-r / 0.25));
            emission = (oldCol * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                      + armCol * arm * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 0.8
                      + hiiCol * knots * 1.1) * mix(1.0, path, 0.35) * galB;
            dustOpacity = saturate(dustOpacity * clamp(0.3 / abs(dn), 1.0, 7.0)) * saturate(galB * 2.0);
        }
    }
    let dusty = mix(vec3<f32>(1.0), vec3<f32>(0.12, 0.06, 0.03), dustOpacity);

    // edge-on, the disk has thickness: a soft glow of old stars hugging the midplane
    let edgeOn = (1.0 - smoothstep(0.06, 0.4, abs(dn))) * galB;
    if (edgeOn > 0.0) {
        let P0 = ro + rd * tClose;
        let h = abs(dot(P0, n)) / R;
        let rr = length(P0 - n * dot(P0, n)) / R;
        col += oldCol * exp(-rr / 0.32) * (exp(-h / 0.025) * 0.35 + exp(-h / 0.08) * 0.08) * edgeOn;
    }

    // ---- jets, hot spots and lobes ----
    var tJet = array<f32, 2>(0.0, 0.0);
    var jetLight = array<vec3<f32>, 2>(vec3<f32>(0.0), vec3<f32>(0.0));
    for (var j = 0; j < 2; j++) {
        let side = select(-1.0, 1.0, j == 0);
        let J = n * side;
        let beam = select(S.e.y, S.e.x, j == 0);
        let travel = select(S.c.w, S.b.w, j == 0);
        // closest approach between the ray and the jet's axis line
        let b = dot(rd, J);
        let e = dot(J, ro);
        let dd = dot(rd, ro);
        let den = max(1.0 - b * b, 1e-4);
        let z = (e - b * dd) / den;
        var jl = vec3<f32>(0.0);
        var tc = 0.0;
        if (z > -0.3 && z < L * 1.15) {
            let zc = max(z, 0.0);
            let C = qsrJetPoint(zc, J, e1, e2, S.g.x, side);
            tc = dot(C - ro, rd);
            let dist = length(C - ro - rd * tc);
            let w = 0.022 + 0.02 * zc;
            if (dist < w * 14.0) {
                // knots: shocks in the flow, spaced irregularly, swelling as they travel out
                let u = (zc - travel) / QSR_KNOT_GAP;
                let cell = floor(u);
                var knot = 0.0;
                for (var k = -1; k <= 1; k++) {
                    let ck = cell + f32(k);
                    let h = hash13(vec3<f32>(ck, side * 7.0, 3.0));
                    let c0 = ck + 0.15 + 0.7 * h;
                    let len = (0.1 + 0.025 * zc) / QSR_KNOT_GAP;
                    let g = (u - c0) / len;
                    let strength = 0.3 + 1.3 * hash13(vec3<f32>(ck, side * 7.0, 9.0));
                    knot += exp(-g * g) * strength * strength;
                }
                // the flare's fresh knot
                let zf = select(S.f.w, S.f.y, j == 0);
                if (S.f.z > 0.0 && zf > 0.0) {
                    let g = (zc - zf) / (0.12 + 0.03 * zf);
                    knot += exp(-g * g) * S.f.z * 6.0;
                }
                let along = (exp(-zc / 1.1) * 2.2 + 0.5 * exp(-zc / (0.55 * L)) + 0.14)
                          * smoothstep(-0.02, 0.25, z) * (1.0 - smoothstep(0.93 * L, 1.03 * L, zc))
                          * (1.0 + coreBoost * 0.4 * exp(-zc / 1.5));
                let ripple = 0.8 + 0.4 * noise3(vec3<f32>(zc * 2.2 - travel * 2.2, dist / w, side * 5.0));
                let x = dist / w;
                let prof = exp(-x * x) + 0.35 * exp(-x * 1.1) + 0.08 * exp(-x * 0.3);
                // knots sit inside the jet, so they skip its wide halo (the bloom glows them)
                let kprof = exp(-x * x * 0.7) + 0.25 * exp(-x * 1.4);
                let I = along * (0.4 * prof + 1.4 * knot * kprof) * ripple * beam * jetB;
                // whitest at the base, drifting toward the lobe color near the end
                var c = mix(mix(jetCol, vec3<f32>(1.0), 0.55), jetCol, smoothstep(0.0, 3.0, zc));
                c = mix(c, mix(jetCol, lobeCol, 0.6), smoothstep(0.55 * L, L, zc));
                jl += c * I * 2.0;
            }
        }
        // hot spot: where the jet slams into the surrounding gas
        let H = qsrJetPoint(L, J, e1, e2, S.g.x, side);
        let th = dot(H - ro, rd);
        let dh = length(H - ro - rd * th);
        let hot = (exp(-(dh * dh) / 0.03) * 2.5 + exp(-dh / 0.45) * 0.35) * (1.0 + select(0.0, S.g.z, j == 0));
        jl += mix(jetCol, vec3<f32>(1.0), 0.4) * hot * jetB * select(0.8, 1.0, j == 0);
        // lobe: a few samples through the cocoon
        let Lc = J * (0.86 * L);
        let tl = dot(Lc - ro, rd);
        let dl = length(Lc - ro - rd * tl);
        let span = 0.42 * L;
        if (dl < span) {
            let half_ = sqrt(span * span - dl * dl);
            var acc = 0.0;
            var head = 0.0;
            let N = 6;
            for (var k = 0; k < N; k++) {
                let tk = tl + half_ * ((f32(k) + 0.5) / f32(N) * 2.0 - 1.0);
                let X = ro + rd * tk;
                let d = qsrLobe(X, J, L, S.g.y, side);
                acc += d;
                head += d * smoothstep(0.55 * L, 0.98 * L, dot(X, J));
            }
            let scale = 2.0 * half_ / f32(N);
            acc *= scale;
            head *= scale;
            // spectral aging: fresh plasma at the head, older and bluer toward the core
            let old_ = mix(lobeCol, vec3<f32>(0.25, 0.4, 1.0), 0.55);
            let fresh = head / max(acc, 1e-4);
            let lc = mix(old_, mix(lobeCol, vec3<f32>(1.0), 0.2), fresh);
            jl += lc * acc * 0.6 * jetB * select(0.85, 1.0, j == 0);
        }
        jetLight[j] = jl;
        tJet[j] = tc;
    }

    // ---- nucleus: accretion glow, scattered light, dusty torus ----
    let flicker = 1.0 + 0.18 * (noise3(vec3<f32>(time * 0.35, 1.0, 2.0)) - 0.5);
    // the accretion disk, a thin hot ellipse in the plane right around the hole
    let accretion = exp(-(rDisk * rDisk) / 0.012) * 1.6;
    let coreCol = vec3<f32>(0.85, 0.92, 1.1);
    // scattered light reaches us around the torus, so only the compact core is fully hidden
    let coreT = S.g.w;
    let coreSeen = coreCol * ((exp(-(dCore * dCore) / 0.0015) * 16.0 + exp(-dCore / 0.07) * 2.5 + accretion) * coreT
                 + (exp(-dCore / 0.4) * 0.35 + exp(-dCore / 2.0) * 0.05) * mix(coreT, 1.0, 0.6))
                 * flicker * (1.0 + coreBoost);

    // torus: march the short stretch of ray near the nucleus, tracking how much dust lies in
    // front of each emitter (the jets' bases and the back of the scene)
    var torusGlow = vec3<f32>(0.0);
    var tauAll = 0.0;
    var tauA = 0.0;
    var tauR = 0.0;
    if (dCore < 1.2) {
        let M = 28;
        let seg = 1.2;
        let dt = 2.0 * seg / f32(M);
        for (var k = 0; k < M; k++) {
            let tk = tClose - seg + (f32(k) + 0.5) * dt;
            let X = ro + rd * tk;
            let dens = qsrTorus(X, n, e1, e2, time) * dt;
            if (dens <= 0.0) { continue; }
            let rho = length(X - n * dot(X, n));
            // lit on its inner face by the nucleus, re-radiating as warm dust
            let lit = 0.25 + 1.6 * smoothstep(QSR_TORUS_R + 0.02, QSR_TORUS_R - QSR_TORUS_A, rho);
            torusGlow += vec3<f32>(1.0, 0.42, 0.18) * dens * lit * 0.22 * exp(-tauAll) * (1.0 + coreBoost * 0.5);
            tauAll += dens;
            if (tk < tJet[0]) { tauA += dens; }
            if (tk < tJet[1]) { tauR += dens; }
        }
    }
    let transAll = exp(-tauAll);

    // compose: sky, back of the bulge and the receding jet sit behind the disk's dust
    let behind = col + bulge * (1.0 - frontFrac) + jetLight[1] * exp(-tauR);
    col = behind * dusty * transAll + emission * (1.0 - 0.8 * dustOpacity) * mix(1.0, transAll, 0.5)
        + bulge * frontFrac + jetLight[0] * exp(-tauA) + coreSeen + torusGlow;
    return finalize(col, p);
}
