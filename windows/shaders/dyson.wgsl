// ---------- per-frame: dyson swarm ---------- (ShaderDyson.swift)
// A star partly enclosed by light-collecting panels on many inclined rings. Each ring is a band
// of panels on its own sphere around the star (no two share a radius, or they'd collide where
// they cross), orbiting at Kepler speed, so inner rings overtake outer ones. Panels face the
// star: from the near side we see their dark backs against it, faintly warm with waste heat; on
// the far side their lit faces show, and they glint when a panel's slow wobble lines its mirror
// up with us. Thin dust around the star scatters the light that escapes between the bands into
// beams. The scene has its own frame: the camera at the origin looking down +z, x right, y up.
//
// S.a = star center, radius
// S.b = star color, surface brightness
// S.c = ring count, density (0..1), glint strength, orbit phase of the innermost ring (radians)
// S.d = panel color A, seed
// S.e = panel color B, innermost ring radius
// S.f = waste heat color, outermost ring radius
// S.g = event: ring index, age (s), sweep length (s), 1 = active

const DS_MAX_RINGS: i32 = 20;
const DS_PANEL: f32 = 0.085;        // panel pitch, in star radii
const DS_FILL: f32 = 0.82;          // panel width as a fraction of its pitch; the rest is gap

struct DSRing { n: vec3<f32>, a1: vec3<f32>, a2: vec3<f32>, r: f32, phase: f32, hue: f32, hw: f32, }

fn dsRing(k: i32, count: f32) -> DSRing {
    var g: DSRing;
    let seed = S.d.w;
    let fk = f32(k);
    // radii spread evenly with a little jitter between the innermost and outermost
    let x = (fk + 0.5 + 0.5 * (hash13(vec3<f32>(fk, seed, 1.7)) - 0.5)) / count;
    g.r = mix(S.e.w, S.f.w, x);
    // inclinations: a golden-ratio sequence over the sphere, so the rings cross at all angles
    let z = 2.0 * fract(fk * 0.618034 + seed * 0.37) - 1.0;
    let az = fk * 2.39996 + seed * 5.1;
    let s = sqrt(max(1.0 - z * z, 0.0));
    g.n = vec3<f32>(s * cos(az), s * sin(az), z);
    g.phase = S.c.w * (S.e.w / g.r) * sqrt(S.e.w / g.r);         // Kepler: angular speed ~ r^-1.5
    g.hw = mix(0.05, 0.24, S.c.y) * (0.75 + 0.5 * hash13(vec3<f32>(fk, seed, 7.9)));   // band half width (radians)
    return g;
}

// The rest of a ring's frame, worked out only where a ray actually meets its band.
fn dsFrame(g: ptr<function, DSRing>, k: i32) {
    let n = (*g).n;
    (*g).a1 = normalize(cross(n, select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), abs(n.y) < 0.9)));
    (*g).a2 = cross(n, (*g).a1);
    (*g).hue = hash13(vec3<f32>(f32(k), S.d.w, 4.2));
}

// Chance that a panel sits at (lon, lat) in the ring's turning frame. The band thins out toward
// its edges, and stretches are still unbuilt; both fill in as the swarm gets denser.
fn dsPresence(g: DSRing, k: i32, lon: f32, lat: f32, density: f32) -> f32 {
    let band = 1.0 - smoothstep(0.35 * g.hw, g.hw, abs(lat));
    if (band <= 0.0) { return 0.0; }
    // a few waves round the ring (whole numbers of them, so it closes on itself), cheaper than noise
    let fk = f32(k);
    let cl = 0.5 + 0.22 * sin(3.0 * lon + fk * 1.7 + 1.3 * sin(2.0 * lon + fk))
                 + 0.16 * sin(7.0 * lon - fk * 2.3 + lat * 14.0) + 0.12 * sin(lat * 23.0 + 5.0 * lon + fk * 4.1);
    let a = mix(0.56, 0.12, density);
    return band * smoothstep(a - 0.1, a + 0.1, cl);
}

// Fraction of starlight a ring blocks in unit direction u from the star (panels and gaps averaged).
fn dsBlock(g_in: DSRing, k: i32, u: vec3<f32>, density: f32) -> f32 {
    var g = g_in;
    let z = dot(u, g.n);
    if (abs(z) > g.hw) { return 0.0; }
    dsFrame(&g, k);
    let lon = atan2(dot(u, g.a2), dot(u, g.a1)) - g.phase;
    return dsPresence(g, k, lon, asin(z), density) * DS_FILL * DS_FILL;
}

// A ring's panels where the view ray crosses its sphere at t: color, and coverage in w.
fn dsPanels(g_in: DSRing, k: i32, rd: vec3<f32>, t: f32) -> vec4<f32> {
    var g = g_in;
    let C = S.a.xyz;
    let u = (rd * t - C) / g.r;
    let z = dot(u, g.n);
    if (abs(z) > g.hw) { return vec4<f32>(0.0); }
    dsFrame(&g, k);
    let lat = asin(z);
    let lon = atan2(dot(u, g.a2), dot(u, g.a1)) - g.phase;
    let count = max(floor(6.2832 * g.r / DS_PANEL), 8.0);
    let cx = lon / 6.2832 * count;
    let cy = lat * g.r / DS_PANEL;
    var ix = floor(cx);
    let iy = floor(cy);
    let f = vec2<f32>(cx - ix, cy - iy) - 0.5;
    ix -= count * floor(ix / count);                    // the same panel either side of the seam
    let cell = vec3<f32>(ix, iy, f32(k) * 17.0 + S.d.w);
    let pres = dsPresence(g, k, (ix + 0.5) / count * 6.2832, (iy + 0.5) * DS_PANEL / g.r, S.c.y);
    let hp = hash13(cell);
    let fp = F.pixelAngle * t / DS_PANEL / max(abs(dot(u, rd)), 0.25);
    let e = 0.5 * fp + 0.04;
    let hf = 0.5 * DS_FILL;
    let m = smoothstep(hf + e, hf - e, abs(f.x)) * smoothstep(hf + e, hf - e, abs(f.y));
    var cov = select(0.0, 1.0, hash13(cell + 3.1) < pres) * m;
    cov = mix(cov, pres * DS_FILL * DS_FILL, smoothstep(0.7, 1.8, fp));   // too small to resolve: average
    if (cov <= 0.0) { return vec4<f32>(0.0); }

    // each panel faces the star, wobbling slowly as its attitude control hunts
    let elon = normalize(cross(g.n, u));
    let elat = cross(u, elon);
    let T = F.time;
    let w1 = sin(T * (0.12 + 0.2 * hp) + hp * 40.0);
    let w2 = sin(T * (0.09 + 0.17 * fract(hp * 7.3)) + hp * 91.0);
    let L = -u;
    let V = -rd;
    var nrm = normalize(L + 0.2 * (w1 * elon + w2 * elat));

    // the event: a wave runs along the ring and each panel in turn swings to mirror the star at us
    var turn = 0.0;
    if (S.g.w > 0.0 && f32(k) > S.g.x - 0.5 && f32(k) < S.g.x + 2.5) {   // three neighboring rings
        let lon0 = lon + g.phase;                     // in the ring's fixed frame
        let far = atan2(g.a2.z, g.a1.z);              // the ring's point farthest from us
        var dl = lon0 - far;
        dl -= 6.2832 * floor(dl / 6.2832 + 0.5);
        let lag = f32(k) - S.g.x;
        let tt = S.g.y - (dl / 3.2 + 0.5) * S.g.z - lag * 2.5 - hp * 0.8;
        turn = smoothstep(0.0, 1.6, tt) * (1.0 - smoothstep(5.5, 9.0, tt));
        turn *= 1.0 - smoothstep(1.2, 1.55, abs(dl));    // a section of the ring, not all of it
        if (dot(L, V) > -0.92) { nrm = normalize(mix(nrm, normalize(L + V), turn)); }
    }

    let E = S.b.w / sq(g.r);                          // irradiance: falls as 1/r^2 from the surface
    let nl = dot(nrm, L);
    let nv = dot(nrm, V);
    let face = mix(S.d.rgb, S.e.rgb, saturate(g.hue * 1.4 - 0.2 + 0.25 * sin(lon * 2.0 + g.hue * 9.0)));
    var col: vec3<f32>;
    if (nv > 0.0 && nl > 0.0) {
        // lit face: a little diffuse light, and a mirror image of the star when lined up. The star
        // fills an angle asin(R/r) seen from the panel; the panels aren't perfectly flat, so the
        // image is softened over a slightly narrower window.
        let gl = dot(reflect(-L, nrm), V);
        let alpha = asin(min(S.a.w / g.r, 1.0));
        let mirror = smoothstep(cos(alpha * 0.22), cos(alpha * 0.05), gl);
        let sheen = pow(saturate(gl), 24.0);
        col = face * E * nl * 0.22 * (0.4 + 0.6 * nv);
        col += mix(S.b.rgb, face, 0.35) * S.c.z * (mirror * S.b.w * 0.55 + sheen * E * 0.12);
        col += mix(S.b.rgb, face, 0.25) * turn * mirror * S.b.w * 0.6;   // the event's flashes, full strength
    } else {
        // the back: dark, glowing faintly with the waste heat it radiates
        col = S.f.rgb * 0.05 * sq(S.e.w / g.r) * (0.6 + 0.8 * hp) + face * 0.002;
        if (nv > 0.0) { col += face * E * 0.05 * nv; }      // the lit face's edge, caught side on
    }
    return vec4<f32>(col, cov);
}

const DS_NS: i32 = 4;

@fragment
fn dysonFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rdw = octDecode(readTex(dirTex, p).xy);
    let right = F.camRight.xyz;
    let up = F.camUp.xyz;
    let fwd = cross(right, up);
    let rd = vec3<f32>(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    let C = S.a.xyz;
    let R = S.a.w;
    let star = pow(max(S.b.rgb, vec3<f32>(0.0)), vec3<f32>(1.4));         // a little deeper than the blackbody, for color
    let I = S.b.w;
    let density = S.c.y;
    let N = min(i32(S.c.x), DS_MAX_RINGS);

    var col = SKY(p, rdw, false);
    let ss = sphereSpan(-C, rd, R);
    let hitStar = ss.x < ss.y && ss.x > 0.0;
    let tc = dot(C, rd);
    let b = length(rd * tc - C);                     // closest approach to the star's center

    if (hitStar) {
        let N3 = normalize(rd * ss.x - C);
        let mu = saturate(dot(N3, -rd));
        let gran = fbm(N3 * 11.0 + vec3<f32>(0.0, 0.0, F.time * 0.05) + S.d.w);
        let limb = 0.3 + 0.7 * pow(mu, 0.55);
        // limb darkening is stronger in the blue, so the edge runs redder
        let tint = mix(star * vec3<f32>(1.0, 0.55, 0.35), star, smoothstep(0.0, 0.7, mu));
        col = tint * I * 0.38 * limb * (0.8 + 0.4 * gran);   // dimmer than the light it sheds, so the disk keeps its color
    }

    // Dust lit by the light escaping between the bands. Along the view ray, at angle th from the
    // point of closest approach, the dust (density ~ 1/d) lit by the star (~ 1/d^2) gives
    // cos(th) dth / b^2, dimmed by every ring the light crossed on its way out. The samples are
    // set up here and dimmed ring by ring in the loop below, so each ring is built only once.
    var su: array<vec3<f32>, 4>;
    var sd: array<f32, 4>;
    var tr: array<f32, 4>;
    let jit = bayer4(p);
    let tStar = select(1e9, ss.x, hitStar);
    for (var i = 0; i < DS_NS; i++) {
        let th = -1.35 + 2.7 * (f32(i) + jit) / f32(DS_NS);
        let tq = tc + b * tan(th);
        let q = rd * tq - C;
        sd[i] = length(q);
        su[i] = q / max(sd[i], 1e-4);
        // samples behind the star, behind us, or inside it give nothing
        tr[i] = select(cos(th), 0.0, tq > tStar || tq < 0.0 || sd[i] < R || tc <= 0.0);
    }

    // far half of each ring (behind the star's plane, lit faces toward us), outermost first
    for (var k = N - 1; k >= 0; k--) {
        let g = dsRing(k, f32(N));
        for (var i = 0; i < DS_NS; i++) {
            if (tr[i] > 0.0 && g.r < sd[i]) { tr[i] *= 1.0 - dsBlock(g, k, su[i], density); }
        }
        if (hitStar) { continue; }
        let s = sphereSpan(-C, rd, g.r);
        if (s.x >= s.y) { continue; }
        let pc = dsPanels(g, k, rd, s.y);
        col = mix(col, pc.rgb, pc.w);
    }

    // corona hugging the limb
    let x = max(b - R, 0.0);
    if (tc > 0.0) {
        let ang = atan2(dot(rd * tc - C, vec3<f32>(0.0, 1.0, 0.0)), dot(rd * tc - C, vec3<f32>(1.0, 0.0, 0.0)));
        let rays = 0.75 + 0.4 * noise3(vec3<f32>(cos(ang) * 4.0, sin(ang) * 4.0, F.time * 0.06 + S.d.w));
        col += star * I * (0.22 * exp(-x / (0.08 * R)) + 0.07 * exp(-x / (0.45 * R))) * rays;

        var glow = 0.0;
        for (var i = 0; i < DS_NS; i++) { glow += tr[i]; }
        glow *= 2.7 / f32(DS_NS);
        let bb = max(b, R);
        // the dust thins out slowly past the swarm, so the beams reach well beyond it
        let fall = exp(-max(bb - R, 0.0) / (1.0 * S.f.w)) / (pow(bb / R, 1.3) + 0.6);
        // the leaking light flickers a little as panels sweep across the gaps
        let flick = 0.9 + 0.1 * noise3(vec3<f32>(F.time * 0.6, b * 2.0, 3.0));
        // deeper in hue than the star, and redder farther out
        let deep = star * star;
        let dustCol = mix(deep, deep * vec3<f32>(1.0, 0.5, 0.35), smoothstep(R, 1.5 * S.f.w, bb));
        col += dustCol * I * 0.13 * glow * fall * flick;
    }

    // near half of each ring (between us and the star): dark backs, innermost first
    for (var k = 0; k < N; k++) {
        let g = dsRing(k, f32(N));
        let s = sphereSpan(-C, rd, g.r);
        if (s.x >= s.y || s.x <= 0.0) { continue; }
        let pc = dsPanels(g, k, rd, s.x);
        col = mix(col, pc.rgb, pc.w);
    }
    return finalize(col, p);
}
