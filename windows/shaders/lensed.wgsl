// ---------- per-frame: black hole, tidal disruption and wormhole ---------- (ShaderLensed.swift)

fn diskNoise(r: f32, ang: f32, seed: f32) -> f32 {
    let p = vec3<f32>(cos(ang) * 2.6, sin(ang) * 2.6, r * 3.2 + seed);
    let n = fbm(p);
    let q = vec3<f32>(cos(ang) * 7.0, sin(ang) * 7.0, r * 9.0 - seed);
    return n * 0.75 + noise3(q) * 0.25;
}

// A darker, deeper shade of c: its channels weighted by how much of the strongest one they hold,
// so it stays the same hue at any brightness (c * c only does that when the strongest is 1).
fn deepen(c: vec3<f32>) -> vec3<f32> {
    return c * c / max(max(c.r, max(c.g, c.b)), 1e-4);
}

// Accretion disk at a crossing h = (radius, angle, redshift g, event). rec / app / core: the
// receding, approaching and hottest colors; rin / rout: inner edge and outer radius.
fn shadeDisk(h: vec4<f32>, rec: vec3<f32>, app: vec3<f32>, core: vec3<f32>, rin: f32, rout: f32) -> vec4<f32> {
    let r = h.x;
    let phi = h.y;
    let g = h.z;
    let x = (r - rin) / (rout - rin);
    let prof = smoothstep(-0.02, 0.05, x) * (1.0 - smoothstep(0.45, 1.0, x));
    if (prof <= 0.0) { return vec4<f32>(0.0); }

    // Differential rotation; two phases cross-faded so the shear never winds the texture up.
    let omega = F.diskSpeed * pow(r, -1.5);
    let T = F.flowPeriod;
    let ph = fract(F.time / T);
    let t0 = ph * T;
    let t1 = fract(ph + 0.5) * T;
    let w0 = 1.0 - abs(2.0 * ph - 1.0);
    let n = diskNoise(r, phi - omega * t0, 0.0) * w0
          + diskNoise(r, phi - omega * t1, 41.0) * (1.0 - w0);
    let dens = smoothstep(0.28, 0.80, n);

    let heat = 1.0 - saturate(x);
    var warm = mix(deepen(rec) * 0.5, rec, smoothstep(0.0, 0.6, heat));
    warm = mix(warm, core, smoothstep(0.7, 1.0, heat) * 0.6);
    let appMax = max(app.r, max(app.g, app.b));
    let cool = mix(deepen(app) * 0.85, mix(app, vec3<f32>(appMax), 0.35), smoothstep(0.2, 1.0, heat));
    let shift = smoothstep(0.95, 1.30, g);
    let col = mix(warm, cool, shift);

    let beaming = pow(clamp(g, 0.35, 1.8), 2.2);
    let radial = pow(rin / r, 1.3);
    let emit = prof * radial * beaming * (0.30 + 1.1 * dens);
    let alpha = saturate(prof * (0.55 + 0.7 * dens) * 1.25);
    return vec4<f32>(col * emit * 2.2, alpha);
}

// ---------- star meets black hole ----------
// S: a = (star color, spot activity), b = (stream brightness, jets on, 0, 0),
// c = (jet color, disk outer radius), d / e / f = disk receding / approaching / core colors.
// The bake (bakeBlackHole) traced the star, stream and jets; see its notes for the layout.

fn tdeDisk(h: vec4<f32>) -> vec4<f32> {
    return shadeDisk(h, S.d.rgb, S.e.rgb, S.f.rgb, F.diskIn, S.c.w);
}

// The star's surface at a baked hit: granulation, spots, limb darkening, and the tip toward
// the hole (where the stream leaves) heated and lit by the disk.
fn tdeStarSurface(st: vec4<f32>) -> vec3<f32> {
    let n = octDecode(st.xy);
    let mu = st.z;
    let t = F.time;
    let gran = fbm(n * 16.0 + vec3<f32>(0.0, 0.0, t * 0.02));
    let cells = noise3(n * 45.0 + t * 0.02);
    var spots = 0.0;
    if (S.a.w > 0.0) { spots = smoothstep(0.7, 0.78, fbm(n * 5.0 + 5.3)) * S.a.w; }
    let base = S.a.rgb;
    // limb darkening, deeper in color toward the edge
    let tint = pow(max(base, vec3<f32>(0.001)), vec3<f32>(4.0 - 3.0 * sqrt(mu)));
    var col = tint * (0.25 + 0.95 * pow(mu, 0.7)) * (0.85 + 0.25 * gran + 0.1 * cells);
    col *= 1.0 - spots * (0.85 - 0.5 * base * base);                                // dark umbrae, warmer edges
    let tip = smoothstep(0.6, 0.98, n.x);
    col += mix(base, vec3<f32>(1.0), 0.3) * tip * 0.3 * (0.6 + 0.8 * gran);    // the L1 tip, where gas boils off
    col += S.f.rgb * saturate(n.x) * 0.12 * (0.3 + 0.7 * mu);              // lit by the disk
    return col * 0.8;
}

// Gas in the stream: hot where it leaves the star, cooling and clumping into filaments on the
// way in, shocked bright again where it slams into the disk's rim, then trailing round it.
fn tdeStreamColor(s: f32, u: f32, fil: ptr<function, f32>) -> vec3<f32> {
    let flow = F.time * 0.012;             // the gas drifts toward the hole, slowly
    let streaks = fbm(vec3<f32>((s - flow) * 7.0, u * 3.2, 3.0));
    let clumps = noise3(vec3<f32>((s - flow * 1.3) * 30.0, u * 1.5, 11.0));
    *fil = 0.12 + 1.3 * smoothstep(0.32, 0.78, streaks) * (0.6 + 0.6 * clumps);
    *fil = max(*fil, 1.2 * (1.0 - smoothstep(0.0, 0.12, s)));   // a solid neck where it leaves the star
    let star = S.a.rgb;
    let warm = mix(S.d.rgb, S.f.rgb, 0.25);
    var col = mix(star, warm * 0.8, smoothstep(0.03, 0.32, s));
    // smoothstep(0.9, -0.2, fil) in the Metal; written with ordered edges, which is the same curve
    col = mix(col, deepen(warm) * 0.7, smoothstep(0.1, 0.6, s) * (1.0 - smoothstep(-0.2, 0.9, *fil)));  // dimmer gaps cool and redden
    let shock = exp(-sq((s - 1.0) / 0.14));
    col = mix(col, mix(S.f.rgb, vec3<f32>(1.0), 0.4) * 1.4, shock * 0.7);
    let bright = (1.1 - 0.65 * smoothstep(0.0, 0.5, s)) * (1.0 - 0.5 * smoothstep(1.1, 1.8, s));
    return col * bright;
}

@fragment
fn lensedFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let wormhole = F.scene > 0.5 && F.scene < 1.5;
    let lightCount = i32(F.lightCount);

    // Layers indexed by event order along the ray (0 = nearest), composited back to front.
    // Nothing behind the nearest opaque layer shows, so it isn't shaded (or even read).
    var layers = array<vec4<f32>, 6>(vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0));
    var opaque = 6;
    if (!wormhole) {
        let rec = Pal.receding.rgb;
        let app = Pal.approaching.rgb;
        let core = Pal.core.rgb;
        let A = readTex(hitA, p);
        if (A.w > 0.0) {
            let ia = min(i32(A.w) - 1, 5);
            layers[ia] = shadeDisk(A, rec, app, core, F.diskIn, F.diskOut);
            if (layers[ia].a >= 1.0) { opaque = ia; }
            let B = readTex(hitB, p);              // a second crossing only exists after a first
            let ib = min(i32(B.w) - 1, 5);
            if (B.w > 0.0 && ib < opaque) {
                layers[ib] = shadeDisk(B, rec, app, core, F.diskIn, F.diskOut);
                if (layers[ib].a >= 1.0) { opaque = min(opaque, ib); }
            }
        }
    }
    let count = i32(F.planetCount);
    if (count > 0) {
        var sp = array<vec4<f32>, 2>(readTex(shell0P, p), readTex(shell1P, p));
        var radii = array<f32, 2>(F.shellR0, F.shellR1);
        for (var s = 0; s < 2; s++) {
            for (var k = 0; k < 2; k++) {
                let tp = select(sp[s].zw, sp[s].xy, k == 0);
                if (tp.x <= 0.0) { continue; }
                let packed = tp.x * 25.0 - 0.5;           // see recordShell
                let ev = floor(packed / 4.0);
                let il = min(i32(ev), 5);
                if (il >= opaque) { continue; }
                let theta = packed - ev * 4.0;
                let phi = tp.y * 6.2831853 - 3.1415927;
                let Xs = radii[s] * vec3<f32>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
                if (!planetsNearShellPoint(Xs, radii[s], s, count)) { continue; }
                var sd: vec4<f32>;
                if (s == 0) { sd = readTex(shell0D, p); } else { sd = readTex(shell1D, p); }
                let v = octDecode(select(sd.zw, sd.xy, k == 0));
                let pc = shadePlanetsOnShell(Xs, v, s, count, lightCount);
                if (pc.a > 0.0) { layers[il] = pc; opaque = il; }
            }
        }
    }

    var col = vec3<f32>(0.0);
    let info = readTex(infoTex, p).x;
    if (opaque < 6) {
        // fully covered: the sky, ring and rim would be multiplied by zero
    } else if (!wormhole) {
        if (info >= 1.0) {
            col = SKY(p, octDecode(readTex(dirTex, p).xy), false);
            col += Pal.ring.rgb * exp(-(info - 1.5) * 40.0) * 1.2 * F.ringStrength;  // photon ring
        }
    } else {
        let far = info < 0.0;
        col = SKY(p, octDecode(readTex(dirTex, p).xy), far);
        // thin rim where rays graze the throat, pulsing slowly, with occasional flares running along it
        let graze = abs(abs(info) - 1.0);
        let pulse = 0.8 + 0.2 * sin(F.time * 0.5);
        let rel = vec2<f32>(p) + 0.5 - E.throat.xy;
        var flare = 0.0;
        if (E.flare.y > 0.0) {
            var dAng = atan2(rel.y, rel.x) - E.flare.x;
            dAng -= 6.2831853 * floor(dAng / 6.2831853 + 0.5);
            flare = E.flare.y * exp(-sq(dAng / E.flare.z));
        }
        col += Pal.ring.rgb * exp(-graze * 90.0) * (0.35 * pulse + 2.5 * flare) * F.ringStrength;
        col += Pal.ring.rgb * flare * 0.25 * exp(-graze * 8.0);       // the flare's glow spills inward
        if (E.obj.z > 0.0) {
            // an object crossing between universes, smeared tangentially near the rim
            let d = vec2<f32>(p) + 0.5 - E.obj.xy;
            let radial = normalize(E.obj.xy - E.throat.xy + 1e-4);
            let tang = vec2<f32>(-radial.y, radial.x);
            let sz = E.obj.w;
            let a = dot(d, radial);
            let b = dot(d, tang) / E.objDir.z;
            let head = exp(-(a * a + b * b) / (sz * sz));
            let v = E.objDir.xy;
            let along = dot(d, -v);
            let across = dot(d, vec2<f32>(-v.y, v.x));
            let trail = select(0.0, exp(-along / (sz * 7.0)) * exp(-across * across / (sz * sz * 0.6)), along > 0.0);
            col += (vec3<f32>(1.0, 0.85, 0.6) * head * 2.5 + vec3<f32>(0.55, 0.75, 1.0) * trail * 0.7) * E.obj.z;
        }
    }
    for (var i = 5; i >= 0; i--) { col = col * (1.0 - layers[i].a) + layers[i].rgb; }
    return finalize(col, p);
}

// Star meets black hole: the disk, the star, the stream and the jets, all from the bake.
@fragment
fn tdeFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    var layers = array<vec4<f32>, 6>(vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0), vec4<f32>(0.0));
    var opaque = 6;
    let A = readTex(hitA, p);
    if (A.w > 0.0) {
        let ia = min(i32(A.w) - 1, 5);
        layers[ia] = tdeDisk(A);
        if (layers[ia].a >= 1.0) { opaque = ia; }
        let B = readTex(hitB, p);
        let ib = min(i32(B.w) - 1, 5);
        if (B.w > 0.0 && ib < opaque) {
            layers[ib] = tdeDisk(B);
            if (layers[ib].a >= 1.0) { opaque = min(opaque, ib); }
        }
    }
    let star = readTex(shell1P, p);
    if (star.w > 0.0) {
        let is = min(i32(star.w) - 1, 5);
        if (is < opaque) { layers[is] = vec4<f32>(tdeStarSurface(star), 1.0); opaque = is; }
    }

    var col = vec3<f32>(0.0);
    let info = readTex(infoTex, p);
    if (opaque == 6 && info.x >= 1.0) {
        col = SKY(p, octDecode(readTex(dirTex, p).xy), false);
        col += Pal.ring.rgb * exp(-(info.x - 1.5) * 40.0) * 1.2 * F.ringStrength;  // photon ring
    }

    // Gas (stream and jets) was split at the first disk crossing: what lies behind it goes
    // under the nearest layer, the rest on top.
    let sv = readTex(shell0P, p);
    var gasBack = vec3<f32>(0.0);
    var gasFront = vec3<f32>(0.0);
    var aBack = 0.0;
    var aFront = 0.0;
    if (sv.x + sv.y > 0.002) {
        var fil = 0.0;
        let sc = tdeStreamColor(sv.z, sv.w, &fil) * S.b.x;
        // an emitting, absorbing slab: thick gas saturates at its own color instead of white
        aBack = 1.0 - exp(-sv.y * fil * 1.4);
        aFront = 1.0 - exp(-sv.x * fil * 1.4);
        gasBack = sc * aBack * 1.3;
        gasFront = sc * aFront * 1.3;
    }
    if (S.b.y > 0.0 && info.y + info.z > 0.001) {
        // knots running out along the jets, brightest at the base
        let y = info.w;
        let knots = 0.4 + 0.9 * smoothstep(0.4, 0.85, noise3(vec3<f32>(y * 0.5 - F.time * 0.25, 0.0, 5.0)));
        let jc = S.c.rgb * knots * (0.12 + 0.45 * exp(-y / 3.0));
        gasBack += jc * info.z;
        gasFront += jc * info.y;
    }
    for (var i = 5; i >= 1; i--) { col = col * (1.0 - layers[i].a) + layers[i].rgb; }
    col = col * (1.0 - aBack) + gasBack;
    col = col * (1.0 - layers[0].a) + layers[0].rgb;
    col = col * (1.0 - aFront) + gasFront;
    if (star.w == 0.0) {
        // a tight glow round the star (lensed with it)
        let d = max(-star.z - 0.93, 0.0);
        col += S.a.rgb * (exp(-d * 10.0) * 0.35 + exp(-d * 3.0) * 0.025);
    }
    return finalize(col, p);
}
