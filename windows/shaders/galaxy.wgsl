// ---------- per-frame: galaxy ----------
// Port of ShaderGalaxy.swift. `G` is the Galaxy uniform (GalaxyModel.gpu in Scenes/Galaxy.swift).

// Mirrors GalaxyModel in Galaxy.swift: flat rotation curve with a dark matter halo,
// falling (Keplerian) curve from visible mass alone.
fn galaxyVelocity(r: f32, darkMatter: bool) -> f32 {
    if (darkMatter) { return 1.0 - exp(-r / 0.12); }
    let a = 0.08;
    return r / pow(r * r + a * a, 0.75) * sqrt(a) / 0.6204;
}

// Stellar texture of the disk, carried around at each radius's own angular speed.
// Two phases cross-fade so differential rotation never shears it into streaks.
fn flowingDisk(r: f32, phi: f32, omega: f32, time: f32, T: f32, scale: f32, fp: f32) -> f32 {
    let ph = fract(time / T);
    let w0 = 1.0 - abs(2.0 * ph - 1.0);
    let a0 = phi - omega * ph * T;
    let a1 = phi - omega * fract(ph + 0.5) * T;
    let n0 = fbmLOD(vec3<f32>(cos(a0) * r * scale, sin(a0) * r * scale, 1.0), fp);
    let n1 = fbmLOD(vec3<f32>(cos(a1) * r * scale, sin(a1) * r * scale, 9.0), fp);
    return n0 * w0 + n1 * (1.0 - w0);
}

// Star-forming regions: glowing H II clouds around young clusters, on rings of cells that each
// orbit at their own omega (the rotation curve, or the irregular's rising one). The gas only
// lights up where something compresses it (`gate`: the arm's density wave, the ring, a clump),
// so a region flares as it drifts into an arm and fades as it leaves. Each also has its own slow
// clock, as clouds collapse, glow, and blow themselves apart. Returns (cloud, cluster core).
fn starFormingRegions(r: f32, phi: f32, time: f32, gate: f32, dm: bool, irregular: bool) -> vec2<f32> {
    let N = 30.0;
    let ri = floor(r * N);
    let rc = (ri + 0.5) / N;
    var om: f32;
    if (irregular) {
        om = G.motion.y * min(rc / 0.45, 1.0) * 0.8 / max(rc, 0.05);
    } else {
        om = G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
    }
    let n = max(floor(6.2831853 * rc * N + 0.5), 3.0);      // whole cells per ring: no seam
    let ca = fract((phi - om * time) / 6.2831853) * n;
    let ci = floor(ca);
    let h = hash13(vec3<f32>(ri, ci, 23.0));
    if (h < 0.6) { return vec2<f32>(0.0); }
    let c = (vec2<f32>(hash13(vec3<f32>(ri, ci, 24.0)), hash13(vec3<f32>(ri, ci, 25.0))) - 0.5) * 0.4;
    var d = vec2<f32>(fract(ca) - 0.5, r * N - ri - 0.5) - c;
    d = vec2<f32>(d.x * 6.2831853 * rc * N / n, d.y);        // cells are square in the disk plane
    let big = hash13(vec3<f32>(ri, ci, 26.0));
    let size = 0.06 + 0.2 * big * big;                       // mostly small, a few giant complexes
    let life = 0.5 + 0.5 * sin(time * 0.015 * (0.5 + h) + h * 40.0);
    let g = gate * (0.2 + 0.8 * life) * (0.5 + 0.5 * (h - 0.6) / 0.4) * (0.6 + 1.2 * big);
    let q = dot(d, d) / (size * size);
    return vec2<f32>(exp(-q) + 0.25 * exp(-q * 0.15), exp(-q * 6.0)) * g;
}

// A small satellite galaxy on an inclined orbit (radius in units of the galaxy radius R),
// seen as a soft spheroid. `compact`: a dense dwarf elliptical (bright cuspy core), else a
// diffuse dwarf spheroidal. Returns its light, and how far along the ray it sits.
fn satellite(ro: vec3<f32>, rd: vec3<f32>, R: f32, orbit: f32, incl: f32, node: f32, ang: f32,
             size: f32, compact: bool, tSat: ptr<function, f32>) -> f32 {
    var o = orbit * R * vec3<f32>(cos(ang), sin(ang) * sin(incl), sin(ang) * cos(incl));
    o = vec3<f32>(o.x * cos(node) - o.z * sin(node), o.y, o.x * sin(node) + o.z * cos(node));
    *tSat = dot(o - ro, rd);
    var w = ro + rd * *tSat - o;
    w = vec3<f32>(w.x, w.y / 0.7, w.z);
    let s = length(w) / (size * R);
    if (compact) {
        return exp(-5.0 * sqrt(s)) * 6.0 + exp(-s * s) * 0.05;
    }
    return exp(-s * s * 0.7) * 0.07 + exp(-s * 2.5) * 0.12;
}

@fragment
fn galaxyFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rd = octDecode(readTex(dirTex, p).xy);
    let ro = F.camPos.xyz;
    var col = SKY(p, rd, false);

    let typeV = i32(G.shape.x);
    let R = G.misc.x;
    let dm = G.motion.z > 0.5;

    // Bulge (or the whole body of an elliptical): an ellipsoid glow integrated along the ray.
    let flat_ = select(0.5, 0.72, typeV == 2);
    let re = select(0.09, 0.2, typeV == 2) * R;
    let o2 = ro / vec3<f32>(1.0, flat_, 1.0);
    let d2 = normalize(rd / vec3<f32>(1.0, flat_, 1.0));
    let s = length(o2 + d2 * max(-dot(o2, d2), 0.0)) / re;
    let bulgeAmt = select(select(1.0, 1.6, typeV == 2), 0.15, typeV == 3);
    var bulge = G.core.rgb * (exp(-3.2 * pow(s, 0.65)) * 1.8 + exp(-s * 0.35) * 0.04) * bulgeAmt;
    // the old stars of the inner bulge are a touch warmer than its outskirts
    bulge *= mix(vec3<f32>(1.0), vec3<f32>(1.08, 0.97, 0.85), exp(-s * 1.5));
    if (typeV == 2) {
        // faint shells left over from swallowed companions: arcs with sharp outer edges,
        // alternating sides, as stars from a radial merger pile up at their turning points
        var shells = 0.0;
        let sa = atan2(d2.y, d2.x);
        for (var k = 0; k < 3; k++) {
            let rs = 2.4 + 1.25 * f32(k);
            let edge = smoothstep(rs - 0.7, rs, s) * (1.0 - smoothstep(rs, rs + 0.06, s));
            let side = pow(0.5 + 0.5 * cos(sa + f32(k) * 3.14159 + 0.4), 3.0);
            shells += edge * side / (1.0 + f32(k));
        }
        bulge += G.core.rgb * shells * 0.018;
    }
    // the bright nucleus and the glow scattered around it (optics, so dust doesn't touch it)
    var bloom = G.core.rgb * (exp(-s * s * 60.0) * 2.5 + exp(-s * 1.2) * 0.10) * select(1.0, 0.0, typeV == 3);
    bloom = mix(bloom, vec3<f32>(dot(bloom, vec3<f32>(0.33))), 0.3);

    // stellar halo and globular clusters, scattered in 3D around the galaxy
    let tClose = -dot(ro, rd);
    let dPerp = length(ro + rd * tClose) / R;
    col += G.core.rgb * exp(-dPerp / 0.45) * 0.025;
    {
        let cell = floor(rd / F.pixelAngle * 0.7);
        let h = hash13(cell + 41.0);
        let halo = exp(-dPerp / 0.5) * select(1.0, 2.5, typeV == 2);    // ellipticals are rich in clusters
        if (h > 1.0 - 0.006 * halo) { col += mix(G.core.rgb, vec3<f32>(1.0), 0.4) * (0.5 + 2.0 * fract(h * 97.0)); }
    }

    // satellites: a compact dwarf elliptical close in and a diffuse dwarf further out, each on its
    // own orbit at the speed the rotation curve gives there (see GalaxyModel)
    var satFront = vec3<f32>(0.0);
    var satBack = vec3<f32>(0.0);
    var tSat0 = 0.0;
    var tSat1 = 0.0;
    if (typeV != 3) {
        let satCol = mix(G.core.rgb, vec3<f32>(1.0), 0.15);
        let l0 = satellite(ro, rd, R, 1.15, 1.05, 0.5, G.misc.z, 0.035, true, &tSat0);
        let l1 = satellite(ro, rd, R, 1.6, -0.75, -0.9, G.misc.w, 0.13, false, &tSat1);
        satFront = satCol * l0;
        satBack = satCol * l1;                         // sorted against the disk below
    }

    var emission = vec3<f32>(0.0);
    var dustOpacity = 0.0;
    var frontFrac = 1.0;          // share of the bulge's light that sits in front of the disk here
    let t = -ro.y / rd.y;
    if (typeV != 2 && t > 0.0) {
        let P = ro + rd * t;
        let r = length(P.xz) / R;
        let phi = atan2(P.z, P.x);
        frontFrac = smoothstep(-1.0, 1.0, clamp((t - tClose) / (1.2 * re), -1.0, 1.0));   // (tanh overflows to NaN under fast math)
        // light and dust pile up along longer paths through a tilted disk
        let path = clamp(0.3 / abs(rd.y), 1.0, 4.0);
        let dustPath = clamp(0.3 / abs(rd.y), 1.0, 7.0);
        let fp = F.pixelAngle * t / (R * max(abs(rd.y), 0.08));
        // every disk term is exactly zero beyond r = 1.2 (1.3 for the irregular's envelope)
        if (r < select(1.2, 1.3, typeV == 3)) {
            let omega = G.motion.y * galaxyVelocity(r, dm) / max(r, 0.01);
            let a = phi - G.motion.x;                 // angle in the pattern's rotating frame
            let tanp = G.shape.z;
            let m = G.shape.y;
            let clumps = flowingDisk(r, phi, omega, F.time, G.motion.w, 9.0, fp * 9.0);
            let fine = flowingDisk(r, phi, omega, F.time, G.motion.w, 26.0, fp * 26.0);
            var smoothDisk = exp(-r / 0.24) * (1.0 - smoothstep(0.7, 1.1, r));

            var arm = 0.0;
            var ring = 0.0;
            var bar = 0.0;
            var knotsBand = 0.0;
            var irrGate = 0.0;
            if (typeV == 0 || typeV == 1) {
                let r0 = select(0.12, G.shape.w, typeV == 1);
                let psi = m * (a - log(max(r, 0.02) / r0) / tanp);
                let env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
                // feathery spurs along the arms
                let spurs = 0.55 + 0.75 * fine;
                let wave = 0.5 + 0.5 * cos(psi);
                arm = (pow(wave, 3.0) * 0.8 + pow(wave, 12.0) * 0.5) * env * spurs;   // bright crest on a broad arm
                // density-wave order across an arm: dust lane on the inside, then star-forming knots, then young stars
                // (in a plain spiral the lanes wind on into the bulge, silhouetted against it)
                let laneIn = select(smoothstep(r0, r0 * 1.8, r), smoothstep(r0 * 0.3, r0 * 1.1, r), typeV == 0);
                let lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * laneIn * (1.0 - smoothstep(0.7, 1.05, r));
                knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
                let filaments = 0.35 + 0.9 * fine;
                // dust feathers: thin spurs that leave the lane and shear out across the inter-arm gap
                let feather = smoothstep(0.62, 0.85, fine) * pow(0.5 + 0.5 * cos(psi + 1.3), 3.0) * env;
                dustOpacity = lane * (0.3 + 0.7 * clumps) * filaments * 1.45
                            + feather * 0.35
                            + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12;      // flocculent inter-arm dust
                if (typeV == 1) {
                    let bx = r * cos(a);
                    let by = r * sin(a);
                    // A soft, cigar-shaped bar: brightest in the middle, fading along its length and
                    // tapering toward the ends, with faint knots (ansae) where the orbits pile up.
                    let u = bx / G.shape.w;
                    let w = 0.08 * (1.0 - 0.45 * min(u * u, 1.6));
                    let v = by / w;
                    let lumpy = 0.85 + 0.3 * fine;
                    bar = (exp(-u * u * 1.4) + 0.3 * exp(-sq((abs(u) - 0.9) / 0.16))) * exp(-v * v) * lumpy;
                    // curved dust lanes on the bar's leading edges, offset to opposite sides
                    let side = by * sign(bx) - w * (0.75 + 0.25 * u * u);
                    dustOpacity += exp(-u * u * 0.9) * exp(-sq(side / (w * 0.35))) * 0.45 * (0.6 + 0.6 * clumps);
                    // star formation where the bar's gas flows pile up at its ends
                    knotsBand += exp(-sq((abs(u) - 0.95) / 0.12)) * exp(-v * v * 0.8) * 0.7;
                }
            } else if (typeV == 4) {
                ring = exp(-sq((r - 0.62) / 0.07)) * (0.6 + 0.6 * fine);
                knotsBand = ring;
                dustOpacity = exp(-sq((r - 0.55) / 0.03)) * 0.5 * (0.4 + 0.8 * fine);
                smoothDisk *= 0.25;
            } else if (typeV == 3) {
                // Dwarf irregular. The lopsided envelope turns slowly, but the gas inside flows:
                // a rising rotation curve (inner parts turn faster than solid-body at the edge),
                // a turbulent warp that keeps changing, and clumps that form and dissolve.
                let env_a = phi - G.misc.y * 0.25;
                let e = vec2<f32>(cos(env_a), sin(env_a)) * r;
                let envelope = exp(-length(e / vec2<f32>(0.75, 0.45)) * 2.2)
                             * (0.7 + 0.6 * fbmLOD(vec3<f32>(e * 1.8, 2.0 + F.time * 0.003), fp * 2.0))
                             * (1.0 - smoothstep(0.85, 1.3, r));
                let omIrr = G.motion.y * min(r / 0.45, 1.0) * 0.8 / max(r, 0.05);
                let T = G.motion.w;
                let ph = fract(F.time / T);
                let w0 = 1.0 - abs(2.0 * ph - 1.0);
                var lumps = 0.0;
                for (var k = 0; k < 2; k++) {
                    let tk = select(fract(ph + 0.5), ph, k == 0) * T;
                    let ak = phi - omIrr * tk;
                    let qk = vec3<f32>(cos(ak) * r, sin(ak) * r, 0.0) * 3.2 + vec3<f32>(0.0, 0.0, F.time * 0.006 + f32(k) * 7.0);
                    let warp = vec3<f32>(fbm(qk * 0.7 + 3.0), fbm(qk * 0.7 - 5.0), 0.0) - 0.5;
                    let v = fbmLOD(qk + warp * 1.6, fp * 3.2);
                    lumps += v * select(1.0 - w0, w0, k == 0);
                }
                smoothDisk = envelope * smoothstep(0.3, 0.7, lumps) * 1.2;
                arm = smoothstep(0.55, 0.8, lumps) * envelope * 3.0;
                // star-forming bursts: knots brighten and fade on their own clocks
                let burst = 0.5 + 0.5 * sin(F.time * 0.15 + hash13(floor(vec3<f32>(e * 14.0, 1.0))) * 6.283);
                knotsBand = arm * (0.3 + 1.2 * burst * burst);
                irrGate = smoothstep(0.42, 0.7, lumps) * saturate(envelope * 4.0) * (0.5 + burst);
                dustOpacity = smoothDisk * smoothstep(0.62, 0.8, fine) * 0.35;
            }
            // a thin, smooth dust layer through the whole disk: barely there face-on, but it
            // darkens and reddens the far half of the bulge as the disk turns edge-on
            if (typeV != 3) { dustOpacity += exp(-r / 0.35) * (1.0 - smoothstep(0.6, 1.0, r)) * (0.05 + 0.08 * clumps); }

            let young = (arm + ring) * select(1.0, 1.5, typeV == 3);    // dwarf irregulars are young and blue
            let knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            // young arms: whiter where they're crowded near the middle, bluer out in the disk
            let armCol = mix(G.arms.rgb, mix(G.arms.rgb, vec3<f32>(1.0), 0.45), exp(-r / 0.25));
            let oldCol = select(G.core.rgb, mix(G.core.rgb, G.arms.rgb, 0.35), typeV == 3);
            let diskLight = oldCol * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                          + G.core.rgb * bar * 1.3
                          + armCol * young * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 1.15
                          + G.nebula.rgb * knots * 1.1;
            emission = diskLight * mix(1.0, path, 0.35);

            // discrete star-forming regions in the arms (or the ring, or the irregular's clumps)
            let gate = select(smoothstep(0.2, 0.75, knotsBand), irrGate, typeV == 3);
            if (gate > 0.01 && r > 0.1) {
                let sf = starFormingRegions(r, phi, F.time, gate, dm, typeV == 3);
                emission += (G.nebula.rgb * sf.x * (0.55 + 0.6 * fine) * 1.1
                           + mix(G.arms.rgb, vec3<f32>(1.0), 0.6) * sf.y * 2.0) * mix(1.0, path, 0.35);
            }

            // resolved bright stars, each ring of cells orbiting at its own omega
            let ri = floor(r * 160.0);
            let rc = (ri + 0.5) / 160.0;
            let om = G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
            let cellAng = (phi - om * F.time) * rc * 160.0;
            let h = hash13(vec3<f32>(ri, floor(cellAng), 5.0));
            if (h > 0.985 - 0.05 * young) { emission += mix(G.core.rgb, G.arms.rgb, saturate(young * 2.0)) * (0.5 + young) * smoothDisk * 3.0; }

            dustOpacity = saturate(dustOpacity * dustPath);
        }
    }
    // Edge-on, a real disk has thickness: a soft glow of old stars hugging the midplane.
    if (typeV != 2) {
        let edgeOn = 1.0 - smoothstep(0.08, 0.45, abs(rd.y));
        if (edgeOn > 0.0) {
            let P0 = ro + rd * tClose;
            let rr = length(P0.xz) / R;
            let z = abs(P0.y) / R;
            col += G.core.rgb * exp(-rr / 0.3) * exp(-z / 0.03) * 0.25 * edgeOn * (1.0 - 0.8 * dustOpacity);
        }
    }
    // The back half of the bulge (and the sky, and anything behind the disk) is seen through the
    // disk's dust; the front half isn't.
    let dusty = mix(vec3<f32>(1.0), G.dust.rgb, dustOpacity);
    var behind = col + bulge * (1.0 - frontFrac);
    var inFront = bulge * frontFrac + bloom;
    let diskHit = typeV != 2 && t > 0.0;
    if (diskHit && tSat0 > t) { behind += satFront; } else { inFront += satFront; }
    if (diskHit && tSat1 > t) { behind += satBack; } else { inFront += satBack; }
    col = behind * dusty + emission * (1.0 - 0.8 * dustOpacity) + inFront;
    return finalize(col, p);
}
