// ---------- per-frame: gas giant storms ---------- (ShaderGasGiant.swift)
// A giant planet close up: its clouds flow. Each point of the cloud deck is traced back along the
// wind (alternating jets, and storms spinning in place) to find which bit of cloud texture has
// arrived there. Traced back too far the texture smears into streaks, so two copies run half a
// cycle apart, each restarting while it's faded out, and the picture is their blend.
// The scene has its own frame: the camera at the origin looking down +z, x right, y up.
//
// S.a = planet center, radius
// S.b = spin axis, wind
// S.c = direction to the sun, turbulence
// S.d = zone (light band) color, storm size
// S.e = belt (dark band) color, flow cycle (s)
// S.f = storm color, lightning rate
// S.g = moon center, radius (0 = none)
// S.h = impact site (unit vector from the planet's center), progress (0 = none)
// S.i = x seed

const GG_STORMS: i32 = 5;

// Wind speed (radians of longitude per second) at latitude sine sl: alternating jets.
fn ggWind(sl: f32, wind: f32) -> f32 {
    return wind * 0.0025 * (0.75 * sin(sl * 21.0) + 0.35 * cos(sl * 8.0) + 0.25);
}

// Storm k: latitude sine, longitude at time zero, size (radians), spin (radians per second,
// negative = anticyclone), and how it tints the clouds (0 the storm color, 1 white).
fn ggStorm(k: i32, tint: ptr<function, f32>) -> vec4<f32> {
    switch (k) {
        case 0: { *tint = 0.0; return vec4<f32>(0.36, -0.05, 0.12, -0.05); }       // the great spot
        case 1: { *tint = 1.0; return vec4<f32>(0.55, 1.0, 0.05, -0.08); }        // white ovals
        case 2: { *tint = 1.0; return vec4<f32>(0.55, -0.4, 0.045, -0.08); }
        case 3: { *tint = 0.7; return vec4<f32>(0.2, 0.9, 0.035, 0.09); }         // a small barge
        default: { *tint = 1.0; return vec4<f32>(0.68, 0.2, 0.04, -0.07); }
    }
}

fn ggPoint(sl: f32, lon: f32, axis: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>) -> vec3<f32> {
    let cl = sqrt(max(1.0 - sl * sl, 0.0));
    return axis * sl + (e1 * cos(lon) + e2 * sin(lon)) * cl;
}

// The cloud texture at unit point q (planet frame through axis/e1/e2), with footprint fp.
fn ggTexture(q: vec3<f32>, axis: vec3<f32>, fp: f32, turb: f32, zone: vec3<f32>, belt: vec3<f32>, seed: f32) -> vec3<f32> {
    let sl = dot(q, axis);
    let warp = fbm(q * 3.0 + seed) - 0.5;
    let lt = sl + warp * 0.05 * turb;
    let bands = 0.5 + 0.5 * sin(lt * 34.0 + 2.6 * sin(lt * 9.0 + seed));
    // curls where the jets shear the band edges: detail displaced along the bands
    let cw = vec2<f32>(fbmLOD(q * 22.0 + seed, fp * 22.0), fbmLOD(q * 22.0 + seed + 7.0, fp * 22.0)) - 0.5;
    let fine = fbmLOD(q * 26.0 + vec3<f32>(cw * 1.6 * turb, lt * 70.0 + seed), fp * 26.0);
    let eddies = fbmLOD(q * 60.0 + seed * 1.7, fp * 60.0);
    let edge = 1.0 - abs(2.0 * bands - 1.0);                      // strongest at the band edges
    let t = smoothstep(0.12, 0.88, bands + (fine - 0.5) * (0.6 + 1.2 * edge) * turb + (eddies - 0.5) * 0.4 * turb);
    // three tones: ivory zones, rust belts, and a deeper brown at the belts' hearts
    var c = mix(belt, zone, t);
    c = mix(c, belt * vec3<f32>(0.65, 0.5, 0.42), smoothstep(0.35, 0.0, bands) * 0.6);
    c *= 0.88 + 0.24 * fbmLOD(q * 12.0 + seed + 3.0, fp * 12.0);    // patchy tone within each band
    // the equatorial zone is brightest, and dark blue-gray festoons trail from its edge
    let eq = smoothstep(0.14, 0.0, abs(sl));
    c = mix(c, zone * 1.05, eq * 0.4);
    let fest = smoothstep(0.58, 0.85, fbmLOD(q * 9.0 + vec3<f32>(seed, 0.0, 3.0), fp * 9.0)) * smoothstep(0.05, 0.1, abs(sl)) * smoothstep(0.18, 0.12, abs(sl));
    c = mix(c, vec3<f32>(0.25, 0.3, 0.4) * dot(belt, vec3<f32>(0.5)), fest * 0.6);
    // cooler, darker toward the poles
    c = mix(c, belt * vec3<f32>(0.6, 0.7, 0.85), smoothstep(0.65, 0.95, abs(sl)) * 0.7);
    return c;
}

@fragment
fn gasGiantFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rdw = octDecode(readTex(dirTex, p).xy);
    let right = F.camRight.xyz;
    let up = F.camUp.xyz;
    let fwd = cross(right, up);
    let rd = vec3<f32>(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    let T = F.time;
    let C = S.a.xyz;
    let R = S.a.w;
    let axis = S.b.xyz;
    let L = S.c.xyz;
    let wind = S.b.w;
    let turb = S.c.w;
    let seed = S.i.x;
    let e1 = normalize(vec3<f32>(0.0, 0.0, -1.0) - axis * dot(vec3<f32>(0.0, 0.0, -1.0), axis));
    let e2 = cross(axis, e1);

    var col = SKY(p, rdw, false);
    let s = sphereSpan(-C, rd, R);
    let tP = s.x;
    let hit = s.x < s.y && s.x > 0.0;
    if (hit) {
        let P = rd * tP;
        let N = normalize(P - C);
        let sl = dot(N, axis);
        let mu = saturate(dot(N, -rd));
        let fp = F.pixelAngle * tP / R / max(mu, 0.1);

        // trace back along the flow, for two copies half a cycle apart
        let cycle = S.e.w;
        var alb = vec3<f32>(0.0);
        var stormMask = 0.0;
        var rimMask = 0.0;
        var paleMask = 0.0;
        var stormRed = 0.0;
        var stormTint = vec3<f32>(0.0);
        for (var k = 0; k < 2; k++) {
            let ph = T / cycle + 0.5 * f32(k);
            let f = fract(ph);
            let w = 1.0 - abs(2.0 * f - 1.0);
            let tau = f * cycle;
            var q = N;
            var zonal = ggWind(sl, wind);
            for (var j = 0; j < GG_STORMS; j++) {
                var tint: f32;
                let st = ggStorm(j, &tint);
                let size = st.z * S.d.w;
                let ws = ggWind(st.x, wind);
                let c = ggPoint(st.x, st.y + ws * 0.12 * T, axis, e1, e2);
                let dq = q - c;
                let east = dot(dq, normalize(cross(axis, c)));
                let north = dot(dq, axis);
                let r = length(vec2<f32>(east / 1.7, north));             // ovals, longer east-west
                if (r > size * 3.0) { continue; }
                let inside = exp(-sq(r / size));
                // inside, it spins (fastest just inside its edge) and rides along with its band
                let spin = st.w * wind * smoothstep(0.0, 0.6 * size, r) * exp(-sq(r / (1.3 * size)));
                q = rotateAbout(q, c, -spin * tau);
                zonal = mix(zonal, ws, inside);
                if (k == 0) {
                    let m = smoothstep(1.2 * size, 0.35 * size, r);
                    if (m > stormMask) {
                        stormMask = m;
                        stormTint = mix(S.f.rgb, vec3<f32>(1.0, 0.97, 0.92) * max(S.d.r, 0.8), tint);
                        stormRed = 1.0 - tint;
                    }
                    let collar = exp(-sq((r - 1.2 * size) / (0.32 * size)));
                    rimMask = max(rimMask, collar * tint);           // dark collars round the white ovals
                    paleMask = max(paleMask, collar * (1.0 - tint)); // a pale hollow round the great spot
                }
            }
            q = rotateAbout(q, axis, -zonal * tau);
            // the texture is laid out in the frame the bands drift through, so it never ages
            alb += ggTexture(q, axis, fp, turb, S.d.rgb, S.e.rgb, seed + f32(k) * 0.0) * w;
        }
        // the storms' own color, with their spiral texture showing through
        let lum = dot(alb, vec3<f32>(0.3, 0.5, 0.2));
        alb = mix(alb, stormTint * (0.45 + 0.9 * lum), stormMask * mix(0.6, 0.85, stormRed));
        alb = mix(alb, S.d.rgb * 1.05, paleMask * 0.5);
        alb *= 1.0 - 0.22 * rimMask;                                   // a darker collar round each storm

        // impact scars: a dark chain of spots, smeared along the band as it shears them
        if (S.h.w > 0.0) {
            let site = S.h.xyz;
            for (var i = 0; i < 4; i++) {
                let lonOff = f32(i) * 0.09 - 0.12;
                let c = rotateAbout(site, axis, lonOff + ggWind(dot(site, axis), wind) * S.h.w * 360.0);
                let d = N - c;
                let along = dot(d, cross(axis, c));
                let across = dot(d, axis);
                let size = (0.012 + 0.03 * sqrt(S.h.w)) * (1.0 - 0.15 * f32(i));
                let scar = exp(-sq(along / (size * (1.0 + 4.0 * S.h.w))) - sq(across / size));
                let fade = smoothstep(0.0, 0.03, S.h.w) * (1.0 - smoothstep(0.75, 1.0, S.h.w));
                alb = mix(alb, vec3<f32>(0.12, 0.08, 0.06), scar * fade * 0.85);
            }
        }

        // light: soft terminator, darkening toward the limb, a faint haze on the rim
        let nl = dot(N, L);
        var shade = 1.0;
        if (S.g.w > 0.0) {
            // the moon's shadow
            let sm = dot(S.g.xyz - P, L);
            if (sm > 0.0) { shade *= smoothstep(S.g.w * 0.7, S.g.w * 1.2, length(S.g.xyz - (P + L * sm))); }
        }
        let day = saturate((nl + 0.05) / 1.05);
        let limb = 0.35 + 0.65 * pow(mu, 0.6);
        col = alb * day * shade * limb * 0.85;
        col += mix(S.d.rgb, vec3<f32>(0.6, 0.75, 1.0), 0.5) * pow(1.0 - mu, 2.5) * saturate(nl + 0.3) * 0.16;

        // lightning in the belts on the night side
        if (S.f.w > 0.0 && nl < 0.1) {
            let cell = 0.05;
            let base = floor(N / cell);
            for (var i = 0; i < 8; i++) {
                let cc = base + vec3<f32>(f32(i & 1), f32((i >> 1u) & 1), f32((i >> 2u) & 1));
                let h = hash13(cc + seed);
                if (h > 0.12) { continue; }
                let ctr = (cc + vec3<f32>(hash13(cc + 1.3), hash13(cc + 2.7), hash13(cc + 4.1))) * cell;
                let dist = length(N - ctr);
                if (dist > 0.03) { continue; }
                let slot = T * (0.5 + 0.8 * h) * S.f.w + h * 50.0;
                let roll = hash13(vec3<f32>(cc.xy, floor(slot)));
                let flash = select(0.0, exp(-fract(slot) * 8.0), roll > 0.9);
                col += vec3<f32>(0.7, 0.8, 1.0) * flash * exp(-sq(dist / 0.006)) * 2.5 * smoothstep(0.1, -0.15, nl);
            }
        }
        // the impact's flash
        if (S.h.w > 0.0 && S.h.w < 0.03) {
            let d = length(N - S.h.xyz);
            col += vec3<f32>(1.0, 0.9, 0.75) * exp(-sq(d / 0.03)) * (1.0 - S.h.w / 0.03) * 6.0;
        }
    } else {
        // the atmosphere's glow just off the limb
        let b = length(-C - rd * dot(-C, rd)) / R;
        col += mix(S.d.rgb, vec3<f32>(0.55, 0.7, 1.0), 0.5) * exp(-max(b - 1.0, 0.0) / 0.012) * 0.1;
    }

    // the moon, in front of or beside the planet
    if (S.g.w > 0.0) {
        let ms = sphereSpan(-S.g.xyz, rd, S.g.w);
        if (ms.x < ms.y && ms.x > 0.0 && (!hit || ms.x < tP)) {
            let N = normalize(rd * ms.x - S.g.xyz);
            let alb = 0.6 + 0.4 * fbm(N * 5.0 + 3.0);
            let mc = mix(vec3<f32>(0.95, 0.75, 0.35), vec3<f32>(1.0, 0.95, 0.7), fbm(N * 9.0 + 1.0)) * alb;
            col = mc * saturate(dot(N, L)) * 1.1;
        }
    }
    return finalize(col, p);
}
