// ---------- per-frame: rogue planet ---------- (ShaderRogue.swift)
// A planet adrift between the stars with no sun. Its only light is starlight: the Milky Way
// behind it scatters forward through its thin air into a faint rim and paints a thin crescent on
// the ice where the galaxy's bright center is near the limb. Its own heat glows through rifts in
// the ice, and its internal dynamo drives aurorae round both magnetic poles. The scene has its
// own frame: the camera at the origin looking down +z, x right, y up.
//
// S.a = planet center, radius (1)
// S.b = spin axis, spin angle (rad)
// S.c = magnetic axis, aurora strength
// S.d = aurora low color, rift glow
// S.e = aurora high color, Milky Way brightness
// S.f = rift color, seed
// S.g = moon center, radius (0 = none)
// S.h = glint star position on the sky (planet radii from the planet's center, x right, y up),
//       brightness (0 = none), color
// S.i = Milky Way plane normal
// S.j = galactic center direction, tan of the planet's angular radius

const RP_AT: f32 = 0.08;         // top of the aurora shell, planet radii above the surface
const RP_OVAL: f32 = 0.38;       // the auroral ovals' radius round each magnetic pole, radians
const RP_STEPS: i32 = 14;

// The Milky Way along direction d: glow of unresolved stars with warm star clouds toward the
// galactic center, dark dust lanes, and pink knots of glowing hydrogen. `density` returns how
// crowded the resolved stars are there.
fn rpMilkyWay(d: vec3<f32>, pa: f32, density: ptr<function, f32>) -> vec3<f32> {
    *density = 0.0;
    let mw = S.e.w;
    if (mw <= 0.0) { return vec3<f32>(0.0); }
    let nb = S.i.xyz;
    let gc = S.j.xyz;
    let lat = dot(d, nb);
    let lon = atan2(dot(d, cross(nb, gc)), dot(d, gc));
    let bulge = exp(-sq(lon / 0.26));
    let wob = 0.03 * (fbmLOD(d * 2.5 + 11.0, pa * 2.5) - 0.5) + 0.012 * sin(lon * 5.0 + 1.0);
    let l = lat + wob;
    let width = 0.06 * (1.0 + 0.6 * bulge);
    let glow = exp(-sq(l / width));
    let outer = exp(-sq(l / (width * 2.6)));
    if (outer < 0.003) { return vec3<f32>(0.0); }
    let clouds = smoothstep(0.3, 0.8, fbmLOD(d * 6.0 + 3.0, pa * 6.0));
    let knots = fbmLOD(d * 20.0 + 5.0, pa * 20.0);
    var lum = glow * (0.12 + 1.4 * clouds * clouds) * (0.5 + knots) + 0.025 * outer;
    lum += 1.2 * bulge * exp(-sq(l / (0.55 * width))) * (0.4 + 0.8 * clouds);
    // dust: a lane down the middle that wanders and breaks up, and finer filaments across it
    let lane = smoothstep(0.35, 0.75, fbmLOD(d * 5.0 + 9.0, pa * 5.0)) * exp(-sq((l - 0.006 + 0.03 * (knots - 0.5)) / 0.02));
    let fil = smoothstep(0.5, 0.85, fbmLOD(d * 18.0 + 2.0, pa * 18.0)) * exp(-sq(l / (width * 1.3)));
    let dust = saturate(lane * 0.85 + fil * 0.45);
    *density = glow * (1.0 - dust) * (0.5 + 0.8 * clouds);
    // hue drifts along the band: blue-white arms, a warm gold center, a rose tinge here and there
    let h = noise3(d * 3.5 + 1.0);
    let cool = mix(vec3<f32>(0.42, 0.58, 1.0), vec3<f32>(0.5, 0.85, 1.0), h);
    let warm = mix(vec3<f32>(1.0, 0.72, 0.38), vec3<f32>(1.0, 0.5, 0.42), h);
    let c = mix(cool, warm, saturate(bulge * 1.1 + 0.25 * glow * clouds));
    let hii = smoothstep(0.7, 0.88, fbmLOD(d * 26.0 + 17.0, pa * 26.0)) * glow * clouds;
    var col = c * lum * (1.0 - dust) * 0.035;
    col += vec3<f32>(1.0, 0.18, 0.45) * hii * (1.0 - dust) * 0.08;
    col += vec3<f32>(0.4, 0.18, 0.08) * dust * glow * 0.006;      // lane edges, reddened
    return col * mw;
}

// The crowd of resolved stars in the band, one per pixel-sized cell where the dice say so.
fn rpStars(d: vec3<f32>, pa: f32, density: f32) -> vec3<f32> {
    if (density <= 0.0) { return vec3<f32>(0.0); }
    let p = d / pa * 0.9;
    let c = floor(p);
    let h = hash13(c + 41.0);
    let thresh = 1.0 - 0.06 * density;
    if (h <= thresh) { return vec3<f32>(0.0); }
    let ctr = c + 0.5 + (vec3<f32>(hash13(c + 3.1), hash13(c + 7.7), hash13(c + 11.3)) - 0.5) * 0.5;
    if (distance(p, ctr) > 0.45) { return vec3<f32>(0.0); }
    let b = (h - thresh) / (1.0 - thresh);
    let t = hash13(c + 5.0);
    let tint = select(mix(vec3<f32>(1.0, 0.9, 0.78), vec3<f32>(0.62, 0.75, 1.0), t * 2.0 - 1.0),
                      mix(vec3<f32>(1.0, 0.62, 0.38), vec3<f32>(1.0, 0.9, 0.78), t * 2.0), t < 0.5);
    return tint * (0.06 + 0.7 * b * b * b);
}

// How far point u (unit vector) sits from the nearer auroral oval, in radians (+ = poleward),
// and its angle round that pole.
fn rpOval(u: vec3<f32>, m: vec3<f32>, m1: vec3<f32>, m2: vec3<f32>, T: f32, psi: ptr<function, f32>, hemi: ptr<function, f32>) -> f32 {
    let cm = dot(u, m);
    *hemi = select(-1.0, 1.0, cm >= 0.0);
    let gam = acos(min(abs(cm), 1.0));
    *psi = atan2(dot(u, m2), dot(u, m1)) * *hemi;
    // the oval bulges and meanders slowly
    let edge = RP_OVAL + 0.035 * sin(*psi + 0.4 + *hemi) + 0.02 * (noise3(vec3<f32>(*psi * 3.0, T * 0.01, *hemi * 5.0)) - 0.5);
    return edge - gam;
}

// Aurora light emitted per unit length at point x (planet radii from its center).
fn rpAurora(x: vec3<f32>, m: vec3<f32>, m1: vec3<f32>, m2: vec3<f32>, T: f32) -> vec3<f32> {
    let r = length(x);
    let a = r - 1.0;
    if (a < 0.0 || a > RP_AT) { return vec3<f32>(0.0); }
    let u = x / r;
    if (abs(dot(u, m)) < cos(RP_OVAL + 0.3)) { return vec3<f32>(0.0); }   // nowhere near either oval
    var psi: f32;
    var hemi: f32;
    let d = rpOval(u, m, m1, m2, T, &psi, &hemi);
    if (d < -0.12 || d > 0.3) { return vec3<f32>(0.0); }
    // folds running along the curtain bend the sheet back and forth
    let fold = 0.012 * sin(psi * 9.0 - T * 0.12 + hemi) + 0.006 * sin(psi * 23.0 + T * 0.2);
    let dk = d - fold;
    let sheet = exp(-sq(dk / 0.03)) + 0.4 * exp(-sq((dk - 0.06) / 0.045)) + 0.25 * exp(-abs(dk) / 0.08);
    // a faint diffuse glow over the polar cap, inside the oval
    let cap = 0.07 * smoothstep(0.0, 0.08, dk) * exp(-max(dk, 0.0) / 0.2);
    // rays: striations that drift along the oval
    let rays = 0.35 + 0.9 * smoothstep(0.35, 0.85, noise3(vec3<f32>(psi * 40.0 + T * 0.08, T * 0.12, hemi)));
    // breathing: the whole oval swells and fades slowly, and bright patches travel round it
    let breathe = 0.6 + 0.4 * sin(T * 0.14 + hemi * 1.7);
    let travel = 0.55 + 0.75 * smoothstep(0.2, 0.9, 0.5 + 0.5 * sin(psi * 2.0 - T * 0.03 + hemi * 2.0 + 2.0 * noise3(vec3<f32>(psi, T * 0.006, hemi))));
    let bright = S.c.w * breathe * travel * (sheet * rays + cap);
    // low down the lower color, higher up the upper color; the tops are ragged and fade into space
    let low = smoothstep(0.0, 0.01, a) * exp(-max(a - 0.01, 0.0) / 0.01);
    let reach = 0.035 + 0.03 * noise3(vec3<f32>(psi * 14.0, T * 0.02, hemi + 3.0));
    let high = smoothstep(0.006, 0.025, a) * exp(-max(a - reach, 0.0) / 0.014) * 0.5;
    let hue = noise3(vec3<f32>(psi * 2.5, T * 0.01, hemi + 7.0));
    let lc = S.d.rgb * mix(vec3<f32>(0.7, 1.0, 1.2), vec3<f32>(1.15, 1.0, 0.7), hue);
    return bright * (lc * low + S.e.rgb * high);
}

@fragment
fn rogueFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rdw = octDecode(readTex(dirTex, p).xy);
    let right = F.camRight.xyz;
    let up = F.camUp.xyz;
    let fwd = cross(right, up);
    let rd = vec3<f32>(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    let T = F.time;
    let pa = F.pixelAngle;
    let C = S.a.xyz;
    let axis = S.b.xyz;
    let m = S.c.xyz;
    let gc = S.j.xyz;
    let seed = S.f.w;

    // the planet's patch of sky, in planet radii from its center (x right, y up)
    let Cn = normalize(C);
    let ex = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), Cn));
    let ey = cross(Cn, ex);
    let q2 = vec2<f32>(dot(rd, ex), dot(rd, ey)) / dot(rd, Cn) / S.j.w;
    let r2 = length(q2);
    let pxR = S.j.w / pa;                                 // the planet's radius in pixels

    // the sky: the usual stars, then the Milky Way and its crowd of stars
    var density: f32;
    let band = rpMilkyWay(rd, pa, &density);
    var sky = SKY(p, rdw, false) + band + rpStars(rd, pa, density) * S.e.w;
    // the glint star, while it is in front of the planet's edge
    let starCol = mix(vec3<f32>(0.7, 0.82, 1.0), vec3<f32>(1.0, 0.88, 0.7), S.h.w);
    let rho = length(S.h.xy);
    if (S.h.z > 0.0) {
        let dpx = length(q2 - S.h.xy) * pxR;
        sky += starCol * S.h.z * (2.5 * exp(-sq(dpx / 0.9)) + 0.25 * exp(-dpx / 2.5) + 0.03 * exp(-dpx / 12.0));
    }
    // the air dims and reddens whatever is about to set behind the limb
    let bAir = (r2 - 1.0) * pxR;                          // pixels above the surface
    let trans = mix(vec3<f32>(0.08, 0.04, 0.03), vec3<f32>(1.0), smoothstep(-0.5, 6.0, bAir));
    var col = sky * trans;

    let s = sphereSpan(-C, rd, 1.0);
    let hit = s.x < s.y && s.x > 0.0;
    let tP = select(1e9, s.x, hit);
    let mwLight = S.e.w;
    if (hit) {
        let P = rd * tP;
        let N = normalize(P - C);
        let mu = saturate(dot(N, -rd));
        let qb = rotateAbout(N, axis, -S.b.w);           // the surface frame, turning with the planet
        let fp = pa * tP / max(mu, 0.08);

        // ice: patchy plains, dirtier where old, and a web of fine cracks of fresh ice
        let plains = fbmLOD(qb * 2.2 + seed, fp * 2.2);
        let alb = 0.35 + 0.45 * smoothstep(0.3, 0.75, plains);
        let w = vec3<f32>(fbmLOD(qb * 3.0 + 1.0, fp * 3.0), fbmLOD(qb * 3.0 + 5.0, fp * 3.0), 0.0) - 0.5;
        // two noises at skewed scales, so the crack lines wander instead of following the lattice
        let qs = vec3<f32>(qb.y + qb.z, qb.z - qb.x, qb.x + qb.y) * 0.7071;
        let n1 = mix(noise3(qb * 6.0 + w * 1.5 + seed), noise3(qs * 9.7 + w + seed + 4.0), 0.4);
        let n2 = mix(noise3(qb * 13.0 + w * 2.0 + seed + 9.0), noise3(qs * 21.0 + seed + 2.0), 0.4);
        let px = 1.0 / max(pxR * mu, 1.0);               // a pixel, in planet radii, foreshortened
        // a crack finer than a pixel spreads over it, dimmer, rather than widening into a band
        let w1 = max(0.02, 12.0 * px);
        let w2 = max(0.025, 26.0 * px);
        let c1 = exp(-sq(abs(2.0 * n1 - 1.0) / w1)) * (0.02 / w1);
        let c2 = exp(-sq(abs(2.0 * n2 - 1.0) / w2)) * 0.6 * (0.025 / w2);
        let cracks = saturate(c1 + c2) * smoothstep(0.35, 0.6, fbmLOD(qb * 4.0 + 3.0, fp * 4.0));
        var ice = mix(vec3<f32>(0.55, 0.6, 0.7), vec3<f32>(0.75, 0.85, 1.0), smoothstep(0.4, 0.7, plains)) * alb;
        ice += vec3<f32>(0.8, 0.95, 1.1) * cracks * 0.8;

        // light: a thin crescent from the bright galactic center, and the whole sky's faint glow
        let lit = saturate(dot(N, gc));
        // the band wraps the whole sky, so faces turned along its plane catch a little more of it
        let sky0 = 0.0008 + 0.0035 * (1.0 - sq(dot(N, S.i.xyz))) * mwLight;
        var light = vec3<f32>(1.0, 0.82, 0.6) * pow(lit, 1.5) * 0.18 * mwLight + vec3<f32>(0.6, 0.7, 1.0) * sky0;
        // fresh ice in the cracks catches the starlight more toward the limb
        light *= 1.0 + cracks * 1.5 * (1.0 - mu);
        col = ice * light;
        // and glint faintly even where the rest of the ice is in the dark
        col += vec3<f32>(0.55, 0.7, 1.0) * cracks * 0.0028 * (0.3 + 0.7 * mwLight) * (0.5 + 0.5 * mu);

        // aurora light falling on the ice under the ovals
        let m1 = normalize(cross(m, vec3<f32>(0.31, 0.12, 0.94)));
        let m2 = cross(m, m1);
        var psi: f32;
        var hemi: f32;
        let dov = rpOval(N, m, m1, m2, T, &psi, &hemi);
        col += S.d.rgb * ice * exp(-sq(dov / 0.06)) * 0.02 * S.c.w * (0.6 + 0.4 * sin(T * 0.14 + hemi * 1.7));

        // geothermal rifts: long cracks where heat from inside glows through
        if (S.d.w > 0.0) {
            // a rift runs along the noise's mid level; its distance on the surface is the
            // offset over the slope, so flat stretches of noise stay dark instead of glowing
            let rq = qb * 2.4 + w * 0.8 + seed + 20.0;
            let nr = noise3(rq);
            let t1 = normalize(cross(qb, vec3<f32>(0.0, 1.0, 0.0)) + 1e-4);
            let t2 = cross(qb, t1);
            const eps = 0.01;
            let slope = length(vec2<f32>(noise3(rq + t1 * eps * 2.4) - nr, noise3(rq + t2 * eps * 2.4) - nr)) / eps;
            let dr = abs(nr - 0.5) / max(slope, 0.05);
            let wr = max(0.006, px);
            let core = exp(-sq(dr / wr));
            let halo = exp(-dr / 0.03);
            let segs = smoothstep(0.55, 0.78, fbmLOD(qb * 1.6 + seed + 30.0, fp * 1.6));
            let pulse = 0.8 + 0.2 * sin(T * 0.11 + nr * 20.0);
            let heat = segs * pulse * (core * 0.25 + halo * 0.025);
            let rc = mix(S.f.rgb, S.f.rgb * vec3<f32>(1.0, 1.6, 2.2) + vec3<f32>(0.0, 0.15, 0.05), core * segs * 0.7);
            // seen at a slant, the walls of the rift hide its floor
            col += rc * heat * S.d.w * smoothstep(0.05, 0.6, mu);
        }

        // the thin air: starlight from behind scattered forward round the limb
        let rim = exp(-mu / 0.05) * 0.85 + exp(-mu / 0.2) * 0.15;
        let airCol = mix(vec3<f32>(0.3, 0.45, 1.0), vec3<f32>(0.55, 0.35, 1.0), noise3(vec3<f32>(atan2(q2.y, q2.x) * 2.0, 3.0, seed)));
        let behind = 0.1 + 3.0 * dot(band, vec3<f32>(0.33)) / max(S.e.w, 0.05) + 0.6 * exp(-acos(clamp(dot(rd, gc), -1.0, 1.0)) / 0.25);
        col += airCol * rim * behind * 0.035 * (0.3 + 0.7 * mwLight);
    } else {
        // the air's glow just off the limb, fading out over a wide band
        let b = max(r2 - 1.0, 0.0);
        let halo = exp(-b / 0.006) * 0.6 + exp(-b / 0.03) * 0.4;
        let airCol = mix(vec3<f32>(0.3, 0.45, 1.0), vec3<f32>(0.55, 0.35, 1.0), noise3(vec3<f32>(atan2(q2.y, q2.x) * 2.0, 3.0, seed)));
        let behind = 0.1 + 3.0 * dot(band, vec3<f32>(0.33)) / max(S.e.w, 0.05) + 0.6 * exp(-acos(clamp(dot(rd, gc), -1.0, 1.0)) / 0.25);
        col += airCol * halo * behind * 0.035 * (0.3 + 0.7 * mwLight);
    }

    // the aurorae, marched through the shell of air they light
    if (S.c.w > 0.0) {
        let sh = sphereSpan(-C, rd, 1.0 + RP_AT);
        if (sh.x < sh.y && sh.y > 0.0) {
            let t0 = max(sh.x, 0.0);
            let t1 = select(sh.y, tP, hit);
            let m1 = normalize(cross(m, vec3<f32>(0.31, 0.12, 0.94)));
            let m2 = cross(m, m1);
            let dt = (t1 - t0) / f32(RP_STEPS);
            let j = hash13(vec3<f32>(vec2<f32>(p), 3.0));
            var acc = vec3<f32>(0.0);
            for (var i = 0; i < RP_STEPS; i++) {
                let x = rd * (t0 + (f32(i) + j) * dt) - C;
                acc += rpAurora(x, m, m1, m2, T);
            }
            col += acc * dt * 9.0;
        }
    }

    // the moon: dark rock lit by the galaxy's glow, a silhouette against the band
    if (S.g.w > 0.0) {
        let ms = sphereSpan(-S.g.xyz, rd, S.g.w);
        if (ms.x < ms.y && ms.x > 0.0 && ms.x < tP) {
            let N = normalize(rd * ms.x - S.g.xyz);
            let alb = 0.5 + 0.5 * fbm(N * 4.0 + 3.0);
            let mc = mix(vec3<f32>(0.7, 0.62, 0.55), vec3<f32>(0.85, 0.8, 0.75), fbm(N * 9.0 + 1.0)) * alb;
            let lit = saturate(dot(N, gc));
            let fill = 0.0008 + 0.004 * (1.0 - sq(dot(N, S.i.xyz))) * mwLight;
            col = mc * (vec3<f32>(1.0, 0.82, 0.6) * pow(lit, 1.5) * 0.2 * mwLight + vec3<f32>(0.6, 0.7, 1.0) * fill);
        }
    }

    // the glint: starlight bent round the limb by the air. Near the edge it is a short bright
    // arc; as the star lines up behind the planet the arc spreads into a full ring, reddened by
    // the deeper air, with a fainter twin on the far side.
    if (S.h.z > 0.0 && rho < 1.25) {
        let ringR = 1.0 + 1.2 / pxR;
        let dr = (r2 - ringR) * pxR;                      // pixels from the ring
        let radial = exp(-sq(dr / 1.1)) + 0.25 * exp(-abs(dr) / 4.0) + 0.05 * exp(-abs(dr) / 16.0);
        let phi = atan2(q2.y, q2.x);
        let phiS = atan2(S.h.y, S.h.x);
        let fa = phi - phiS + 9.42478;
        let dphi = abs(fa - 6.28318 * trunc(fa / 6.28318) - 3.14159);
        let depth = saturate(1.0 - rho);
        let sigma = 0.07 + 2.6 * sq(depth);
        let arc = exp(-sq(dphi / sigma)) + 0.8 * depth * exp(-sq((3.14159 - dphi) / sigma));
        var amp = 1.6 * exp(-sq((rho - 1.0) / 0.08)) + 0.4 + 0.5 * depth + 1.2 * exp(-sq(rho / 0.1));
        amp *= smoothstep(1.25, 1.0, rho);
        var gcol = mix(starCol, vec3<f32>(1.0, 0.42, 0.22), smoothstep(0.98, 0.6, rho));
        gcol = mix(gcol, vec3<f32>(1.0, 0.3, 0.6), smoothstep(0.5, 1.5, dphi) * depth * 0.6);
        col += gcol * S.h.z * amp * arc * radial * 1.2;
    }
    return finalize(col, p);
}
