// ---------- bake: sky scalars (all scenes) ---------- (ShaderSky.swift)

// Sky as scalars: (star brightness, star tint, nebula A, nebula B) and a star id.
// `fp` is the angular footprint of this pixel on the sky; where lensing squeezes a lot of sky
// into one pixel, detail is filtered instead of aliasing into moire.
// A different star field for each sky seed: the whole field turns to a hashed orientation, so
// stars, nebulae and galaxies keep their look and only where they sit changes. Seed 0 is the
// original sky.
fn seededSky(d: vec3<f32>, s: f32) -> vec3<f32> {
    if (s == 0.0) { return d; }
    let q = vec3<f32>(s * 0.0137, s * 0.0291 + 3.1, 7.7);
    let h = vec3<f32>(hash13(q), hash13(q + 19.1), hash13(q + 37.3));
    let axis = normalize(h - 0.5 + vec3<f32>(1e-3, 0.0, 0.0));
    let a = 0.6 + 5.0 * fract(h.x * 7.13 + h.y * 3.71);
    let c = cos(a);
    let sn = sin(a);
    return d * c + cross(axis, d) * sn + axis * dot(axis, d) * (1.0 - c);
}

fn skyScalars(d0: vec3<f32>, fp: f32, seed: f32, id: ptr<function, f32>) -> vec4<f32> {
    let d = seededSky(d0, P.skySeed);
    let pixelAngle = 2.0 * P.tanHalfFov / P.height;
    let k = max(fp / pixelAngle, 1.0);           // > 1 where the sky is compressed
    let cells = 0.9 / pixelAngle;
    let p = d * cells;
    let c = floor(p) + seed * 131.0;
    let h = hash13(c);
    // galactic band: a tilted great circle of dense stars, glow and dark dust lanes
    var band = 0.0;
    var dust = 0.0;
    if (P.milkyWay > 0.5 && seed == 0.0) {
        let lat = dot(d0, normalize(vec3<f32>(0.42, 0.9, 0.08)));
        let wobble = 0.05 * (fbmLOD(d * 3.0 + 11.0, fp * 3.0) - 0.5);
        band = exp(-sq((lat + wobble) / 0.09));
        dust = smoothstep(0.42, 0.72, fbmLOD(d * 7.0 + 4.0, fp * 7.0)) * exp(-sq((lat + wobble * 1.5) / 0.035));
    }
    let density = P.starDensity * select(1.0, 3.0, seed > 0.0);    // the other universe is richer
    let thresh = 1.0 - 0.01 * density * (1.0 + 4.0 * band * (1.0 - dust));
    var bright = 0.0;
    var tint = 0.0;
    *id = 0.0;
    if (h > thresh) {
        // a small sphere inside the cell keeps stars round where the unit sphere slices the grid
        let center = floor(p) + 0.5 + (vec3<f32>(hash13(c + 3.1), hash13(c + 7.7), hash13(c + 11.3)) - 0.5) * 0.5;
        if (distance(p, center) < 0.42) {
            let b = (h - thresh) / (1.0 - thresh);
            bright = (0.12 + 1.3 * b * b * b) / (k * k);    // a sub-pixel star spreads over k^2 pixels
            tint = hash13(c + 17.0);
            *id = 0.001 + 0.999 * hash13(c + 29.0);
        }
    }
    // the average light of all the unresolved stars
    bright += 0.0015 * P.starDensity * smoothstep(1.5, 4.0, k);

    // rare distant galaxies: tiny tilted smudges on a coarser grid
    if (P.galaxies > 0.5 && *id == 0.0 && k < 2.0) {
        let gcells = cells / 30.0;
        let g = floor(d * gcells);
        let gh = hash13(g + 71.0 + seed);
        if (gh > 0.992) {
            let gc = normalize(g + 0.5 + (vec3<f32>(hash13(g + 1.0), hash13(g + 2.0), hash13(g + 3.0)) - 0.5) * 0.6);
            let t1 = normalize(cross(gc, vec3<f32>(0.3, 1.0, 0.1)));
            let t2 = cross(gc, t1);
            var q = vec2<f32>(dot(d, t1), dot(d, t2)) / (pixelAngle * (2.0 + 3.0 * hash13(g + 5.0)));
            let ang = hash13(g + 6.0) * 6.283;
            q = vec2<f32>(cos(ang) * q.x - sin(ang) * q.y, sin(ang) * q.x + cos(ang) * q.y);
            q.y /= 0.35 + 0.6 * hash13(g + 7.0);
            let r = length(q);
            let arms = 0.6 + 0.4 * cos(2.0 * (atan2(q.y, q.x) - log(r + 0.05) * 2.5));
            let gal = exp(-r * r * 2.0) * (0.35 + 0.65 * arms * smoothstep(0.1, 0.6, r)) + exp(-r * r * 30.0) * 0.6;
            if (gal > 0.02 && dot(d, gc) > 0.0) { bright = gal * (0.2 + 0.25 * gh); tint = 1.0 + hash13(g + 9.0); }
        }
    }
    var nA = smoothstep(0.50, 0.90, fbmLOD(d * 2.2 + 5.0 + seed * 7.0, fp * 2.2));
    var nB = smoothstep(0.65, 0.95, fbmLOD(d * 4.5 - 3.0 + seed * 7.0, fp * 4.5));
    let clouds = 0.55 + 0.45 * fbmLOD(d * 9.0 - 2.0, fp * 9.0);
    nA += band * clouds * (1.0 - dust) * 0.35;      // cool glow of unresolved stars
    nB += band * band * clouds * (1.0 - dust) * 0.6; // warmer core of the band
    bright *= 1.0 - 0.8 * dust;
    return vec4<f32>(bright, tint, nA, nB);
}

// The other universe seen through the wormhole: denser nebula and one big spiral galaxy.
fn farSkyScalars(d: vec3<f32>, fp: f32, galaxyDir: vec3<f32>, id: ptr<function, f32>) -> vec4<f32> {
    var s = skyScalars(d, fp, 3.0, id);
    let t1 = normalize(cross(galaxyDir, vec3<f32>(0.2, 1.0, 0.0)));
    let t2 = cross(galaxyDir, t1);
    var q = vec2<f32>(dot(d, t1), dot(d, t2)) / 0.55;
    q = vec2<f32>(0.8 * q.x - 0.6 * q.y, 0.6 * q.x + 0.8 * q.y);
    q.y /= 0.38;                                    // inclined disk
    let fq = fp / 0.55 / 0.38;                      // footprint in galaxy coordinates
    let r = length(q);
    let th = atan2(q.y, q.x);
    var arms = smoothstep(0.1, 1.0, cos(2.0 * (th - log(r + 0.02) * 1.3)));
    arms = mix(0.35, arms, 1.0 - smoothstep(0.3, 1.0, fq * 6.0 / (r + 0.05)));
    let clumps = fbmLOD(vec3<f32>(q * 4.0, 1.0), fq * 4.0);
    let gal = select(0.0, 1.0, dot(d, galaxyDir) > 0.0);
    let core = exp(-r * r * 14.0) * 3.0 * gal;
    let lane = 1.0 - 0.75 * smoothstep(0.55, 0.8, fbmLOD(vec3<f32>(q * 2.5, 7.0), fq * 2.5)) * exp(-sq(q.y * 3.0));
    let armDensity = exp(-r * 1.1) * arms * (0.3 + clumps) * gal * smoothstep(3.5, 2.0, r) * lane;
    s.z = saturate(s.z * 0.7 + 0.08 * fbmLOD(d * 1.3, fp * 1.3)) + armDensity * 0.5;
    s.w = saturate(s.w * 0.9) + armDensity * 0.7;
    // the galaxy's bright core and the brighter arm stars glow in the galaxy color
    let glowAmt = core * 0.6 + armDensity * 0.12;
    if (glowAmt > s.x) { s.x = glowAmt; s.y = 1.0; }
    return s;
}

// Whether a pixel shows sky at all: black holes have a shadow with none in it.
fn hasSky(info: f32) -> bool { return P.lensing < 0.5 || P.lensing > 1.5 || info >= 1.0; }
fn sameSide(a: f32, b: f32) -> bool { return (a < 0.0) == (b < 0.0); }

// Where a pixel looks on the sky: straight from the camera without lensing (exact, no need
// to read it back), else the ray bake's outgoing direction.
fn skyDir(g: vec2<u32>) -> vec3<f32> {
    if (P.lensing < 0.5) {
        var camPos: vec3<f32>;
        return cameraRay(g, &camPos);
    }
    return octDecode(textureLoad(skyDirIn, vec2<i32>(g), 0).xy);
}

fn skyInfo(g: vec2<u32>) -> f32 { return textureLoad(skyInfoIn, vec2<i32>(g), 0).x; }

// Runs after the ray bake. Works out each pixel's sky footprint from its neighbours' ray
// directions, then evaluates the sky with matching detail. The star id goes to its own
// texture, quantized to 1/4096 steps (0 = none).
@compute @workgroup_size(8, 8)
fn skyPass(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    let W = u32(P.width);
    let H = u32(P.height);
    if (gid.x >= W || gid.y >= H) { return; }
    let lensed = P.lensing > 0.5;
    let info = select(1000.0, skyInfo(gid), lensed);
    if (!hasSky(info)) {
        textureStore(skyOut, vec2<i32>(gid), vec4<f32>(0.0));
        textureStore(idOut, vec2<i32>(gid), vec4<u32>(0u));
        return;
    }
    let d = skyDir(gid);

    let pixelAngle = 2.0 * P.tanHalfFov / P.height;
    var fp = pixelAngle;
    let nb = array<vec2<u32>, 4>(
        vec2<u32>(min(gid.x + 1u, W - 1u), gid.y), vec2<u32>(select(0u, gid.x - 1u, gid.x > 0u), gid.y),
        vec2<u32>(gid.x, min(gid.y + 1u, H - 1u)), vec2<u32>(gid.x, select(0u, gid.y - 1u, gid.y > 0u)));
    for (var i = 0; i < 4; i++) {
        let infoN = select(1000.0, skyInfo(nb[i]), lensed);
        if (!hasSky(infoN) || !sameSide(info, infoN)) { continue; }
        fp = max(fp, length(skyDir(nb[i]) - d));
    }

    var id = 0.0;
    var sky: vec4<f32>;
    if (P.lensing > 1.5 && info < 0.0) {
        let ce = cos(P.camElev);
        let se = sin(P.camElev);
        let e1 = vec3<f32>(0.0, se, -ce);
        sky = farSkyScalars(d, fp, normalize(e1 + vec3<f32>(0.06, 0.08, 0.0)), &id);
    } else {
        sky = skyScalars(d, fp, 0.0, &id);
    }
    textureStore(skyOut, vec2<i32>(gid), sky);
    textureStore(idOut, vec2<i32>(gid), vec4<u32>(select(0u, 1u + u32(floor(id * 4094.0)), id > 0.0)));
}
