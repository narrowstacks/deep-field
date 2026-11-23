// ---------- per-frame: live Earth ---------- (ShaderLiveEarth.swift)
// The whole Earth as it is right now, seen from far above a chosen place that stays in the
// middle of the disk: real sunlight and seasons, city lights on the night side, the Moon where it
// really is (in its real phase, with earthshine and eclipses), and optionally the latest cloud
// map and NOAA's aurora forecast. Everything is in Earth-fixed coordinates, Earth radius 1:
// x toward 0 N 0 E, y toward 0 N 90 E, z the north pole. The sun and Moon positions come from
// the CPU (scenes/live_earth.rs), worked out for the scene's date.
//
// S.a = camera position (xyz), unused
// S.b, S.c, S.d = the camera's right, up and forward axes (xyz)
// S.e = direction to the sun (xyz), sun drawn (0/1)
// S.f = the Moon's center (xyz, Earth radii), the Moon's drawn radius
// S.g = clouds, aurora, city lights, moonlight
// S.h = cloud map bound (0/1), aurora map bound (0/1), real maps bound (0/1), season (0 Jan, 1 Jul)
// S.i = the chosen place (unit xyz), marker (0/1)
// S.j = atmosphere, the Moon's true radius, star maps bound (0/1), a solar eclipse is on (0/1)
// S.k, S.l, S.m = rows of the turn from Earth-fixed directions to the star catalog's (J2000)
// S.n = star brightness, Milky Way brightness, aurora speed
// S.p = real past clouds bound (0/1), how far the moment is between their two frames (0..1)
// S.o = planets bound (count, skyP), their size (times true); their labels are a later pass
//
// Textures (frame bindings 20 to 32, the Metal slots 10 to 22): earthLights, earthGround,
// dayJan and dayJul (the January and July surface), waterTex (open water), moonTex, cloudTex,
// auroraTex (the forecast), starTex (the star catalog splatted into a map), milkyTex, and for a
// past moment pastA, pastB and pastFlow (see earth_maps.rs, live_earth_feeds.rs,
// historical_clouds.rs). The Metal samplers without a mip filter read level 0, so they are
// mipRepeat with an explicit level 0 here.

const LE_ATMO: f32 = 0.06;          // the air and the aurora above it, up to ~380 km
const LE_SCALE_H: f32 = 0.0075;     // its scale height (~48 km, real is 8)
const LE_SUN_R: f32 = 0.00465;      // the sun's angular radius
const LE_RAYLEIGH: vec3<f32> = vec3<f32>(0.17, 0.42, 1.0);   // ~ 1 / wavelength^4 for 680, 550, 440 nm

fn leUV(n: vec3<f32>) -> vec2<f32> {
    let lat = asin(clamp(n.z, -1.0, 1.0));
    let lon = atan2(n.y, n.x);
    return vec2<f32>(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI);
}

// Sunlight reaching height-point p after its slant path through the air: reddens and fades as the
// sun sets, so the terminator glows orange. mu is the sun's elevation sine at p.
fn leSunColor(mu: f32) -> vec3<f32> {
    let airmass = 1.0 / max(mu + 0.12, 0.04);
    return exp(-LE_RAYLEIGH * 0.09 * airmass) * smoothstep(-0.12, 0.02, mu);
}

// A sphere at center c, radius r: (enter, exit), empty when enter >= exit.
fn leSphere(ro: vec3<f32>, rd: vec3<f32>, c: vec3<f32>, r: f32) -> vec2<f32> {
    let oc = ro - c;
    let b = dot(oc, rd);
    let cc = dot(oc, oc) - r * r;
    var h = b * b - cc;
    if (h < 0.0) { return vec2<f32>(1.0, 0.0); }
    h = sqrt(h);
    return vec2<f32>(-b - h, -b + h);
}

// How much of the sun the Moon hides, seen from point p: 0 none, 1 total (a solar eclipse's
// shadow on Earth). Disks of angular radius LE_SUN_R and am, centers sep apart.
fn leEclipse(p: vec3<f32>, s: vec3<f32>, moon: vec3<f32>, rm: f32) -> f32 {
    let v = moon - p;
    let dv = length(v);
    let am = rm / dv;
    // the angle from the cross product: acos of a dot product this close to 1 loses the
    // fraction of a degree that matters here
    let u = v / dv;
    if (dot(u, s) <= 0.0) { return 0.0; }
    let sep = asin(min(length(cross(u, s)), 1.0));
    let covered = 1.0 - smoothstep(abs(LE_SUN_R - am), LE_SUN_R + am, sep);
    return covered * min(sq(am / LE_SUN_R), 1.0);
}

// The aurora forecast (chance of aurora overhead, 0..1) at unit point n. NOAA's grid has
// column i at longitude i degrees east and row j at latitude 90 - j.
fn leAuroraMap(n: vec3<f32>) -> f32 {
    let lat = asin(clamp(n.z, -1.0, 1.0)) * (180.0 / PI);
    let lon = atan2(n.y, n.x) * (180.0 / PI);
    let uv = vec2<f32>((lon + 0.5) / 360.0, (90.0 - lat + 0.5) / 181.0);
    return textureSampleLevel(auroraTex, mipRepeat, uv, 0.0).r;
}

// Aurora light emitted per unit length at p (height a above the ground), in arcs that run
// east-west along the oval. By height: a pink-purple nitrogen fringe along the lower edge
// (~95 km), oxygen green above it (~120 km), oxygen red higher up (~240 km, stronger in storms),
// and, near the day-night line, blue-violet tops where the highest curtains catch sunlight
// (nitrogen ions scattering it).
fn leAuroraEmit(p: vec3<f32>, a: f32, T: f32, s: vec3<f32>) -> vec3<f32> {
    let n = p / (1.0 + a);
    let chance = leAuroraMap(n);
    if (chance < 0.01) { return vec3<f32>(0.0); }
    // only where it's dark below: the sky has to be past twilight for the glow to show
    let mu = dot(n, s);
    let dark = smoothstep(0.05, -0.2, mu);
    if (dark <= 0.0) { return vec3<f32>(0.0); }
    let lat = asin(clamp(n.z, -1.0, 1.0));
    let lon = atan2(n.y, n.x);
    // Arcs stretched along the lines of latitude. They drift along the oval and fold into
    // swirls over a minute or so, fine rays shimmer across them in seconds, and surges of
    // brightness run along them, the way active aurora pulses.
    // Earth's field lines lean equatorward as they rise, so a curtain's upper parts sit a little
    // equatorward of its base (exaggerated a few times here). Seen from above, that keeps the red
    // tops beside the green instead of on top of it, where the two would add up to olive.
    let lean = (a - 0.019) * 0.4 * sign(lat);
    let latA = lat - lean;
    let fold = noise3(vec3<f32>(lon * 6.0 - T * 0.02, latA * 12.0, T * 0.12));
    let arcRaw = noise3(vec3<f32>(lon * 3.0 + T * 0.035, latA * 70.0 + 5.0 * fold, T * 0.1));
    // a wide falloff and a broad glow underneath, so each arc fades out over its edges
    let glow = noise3(vec3<f32>(lon * 2.0 + T * 0.03, latA * 22.0 + 2.0 * fold, T * 0.06));
    let arcs = mix(smoothstep(0.3, 0.92, arcRaw), smoothstep(0.35, 0.85, glow), 0.2);
    let rays = 0.45 + 0.55 * noise3(vec3<f32>(lon * 260.0 - T * 0.25, latA * 20.0, T * 0.7));
    let surge = 0.55 + 0.9 * smoothstep(0.2, 1.0, sin(lon * 14.0 - T * 0.45 + 3.0 * fold));
    let strength = smoothstep(0.0, 0.25, chance) * (0.4 + chance) * dark;
    // the green and the nitrogen fringe follow the sharp arcs and their rays; the red, slow to
    // emit, spreads into a softer glow round them
    let sharp = (0.15 + 1.8 * arcs * rays * surge) * strength;
    let soft = (0.08 + 1.2 * mix(smoothstep(0.15, 0.9, arcRaw), glow, 0.25) * surge) * strength;
    let green = exp(-sq((a - 0.019) / 0.006)) + 0.3 * exp(-max(a - 0.019, 0.0) / 0.008) * step(0.017, a);
    let red = exp(-sq((a - 0.038) / 0.013)) * (0.35 + 0.8 * chance);
    let fringe = exp(-sq((a - 0.0155) / 0.0025)) * 0.42 * smoothstep(0.1, 0.5, chance);
    // sunlit tops: the curtains' upper parts are still in sunlight just past the terminator
    let sunlitTop = exp(-sq((a - 0.05) / 0.012)) * smoothstep(-0.4, -0.12, mu) * 0.35;
    return sharp * (vec3<f32>(0.12, 1.0, 0.38) * green * 1.9 + vec3<f32>(0.85, 0.2, 1.0) * fringe)
         + soft * (vec3<f32>(1.0, 0.1, 0.32) * red + vec3<f32>(0.5, 0.3, 1.0) * sunlitTop);
}

// The real sky in direction rd (Earth-fixed): the catalog's stars where they are tonight, in
// their own colors, over the Milky Way's glow. Each star sits in one texel of the map and is
// spread over the pixels round it by its angular distance, so it glides smoothly as the sky
// turns instead of hopping from pixel to pixel.
fn leSky(rd: vec3<f32>, pixAng: f32) -> vec3<f32> {
    let c = vec3<f32>(dot(S.k.xyz, rd), dot(S.l.xyz, rd), dot(S.m.xyz, rd));
    let dec = asin(clamp(c.z, -1.0, 1.0));
    var ra = atan2(c.y, c.x);
    if (ra < 0.0) { ra += 2.0 * PI; }
    let dims = textureDimensions(starTex);
    let W = i32(dims.x);
    let H = i32(dims.y);
    let uv = vec2<f32>(ra / (2.0 * PI), 0.5 - dec / PI);
    // Half the map sits below about 12% gray (faint stars and sky glow, in linear light about
    // 0.012). Fading that out with a soft knee leaves the Milky Way's band, with soft edges,
    // instead of a haze over the whole sky.
    var mw = textureSampleLevel(milkyTex, mipRepeat, uv, 0.0).rgb;
    mw *= smoothstep(0.006, 0.04, dot(mw, vec3<f32>(0.3, 0.5, 0.2)));
    // its dust lanes print brown; most of the glow reads as a neutral starlit haze
    let col = mix(vec3<f32>(dot(mw, vec3<f32>(0.3, 0.5, 0.2))), mw, 0.6) * S.n.y * 0.06;
    let texel = 2.0 * PI / f32(W);
    let sigma = max(pixAng * 0.75, texel * 0.6);
    let reach = 2.2 * sigma;
    let ny = min(i32(ceil(reach / texel)), 3);
    let nx = min(i32(ceil(reach / (texel * max(cos(dec), 0.05)))), 8);
    let at = vec2<i32>(floor(uv * vec2<f32>(f32(W), f32(H))));
    var acc = vec3<f32>(0.0);
    for (var dy = -ny; dy <= ny; dy++) {
        let y = at.y + dy;
        if (y < 0 || y >= H) { continue; }
        for (var dx = -nx; dx <= nx; dx++) {
            let x = (at.x + dx + W) % W;
            let t = textureLoad(starTex, vec2<i32>(x, y), 0);
            if (t.a <= 0.0) { continue; }
            let sra = (f32(x) + 0.5) / f32(W) * 2.0 * PI;
            let sdec = (0.5 - (f32(y) + 0.5) / f32(H)) * PI;
            let sd = vec3<f32>(cos(sdec) * cos(sra), cos(sdec) * sin(sra), sin(sdec));
            let d2 = 2.0 * max(1.0 - dot(sd, c), 0.0);     // the angle squared
            // brightness from the magnitude, a little compressed (flux to the 0.75) so the
            // faintest naked-eye stars still show next to Sirius
            let v = 7.0 - 9.0 * t.a;
            acc += t.rgb * exp2(-0.9966 * v) * exp(-d2 / sq(sigma));
        }
    }
    return col + acc * S.n.x * 4.0;
}

// The Moon's surface at q. The Metal sampler here has no mip filter, so it always reads the
// map's base level, and so does this.
fn leMoonColor(q: vec3<f32>, mc: vec3<f32>, rTrue: f32, s: vec3<f32>, mapped: bool) -> vec3<f32> {
    let n = normalize(q - mc);
    // the near side always faces Earth; its pole is close enough to Earth's
    let xm = normalize(-mc);
    let zm = normalize(vec3<f32>(0.0, 0.0, 1.0) - xm * xm.z);
    let ym = cross(zm, xm);
    let lat = asin(clamp(dot(n, zm), -1.0, 1.0));
    let lon = atan2(dot(n, ym), dot(n, xm));
    var alb = 0.0;
    if (mapped) {
        alb = sq(textureSampleLevel(moonTex, mipRepeat, vec2<f32>(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI), 0.0).r) * 0.9;
    } else {
        alb = 0.18 + 0.1 * noise3(n * 6.0);
    }
    // where Earth's shadow falls on the real Moon (a lunar eclipse): the umbra narrows to about
    // 0.73 Earth radii at the Moon's distance, the penumbra widens to about 1.27, and inside the
    // umbra only sunlight bent red through Earth's air gets in
    let qt = mc + n * rTrue;
    let along = dot(qt, -s);
    var lit = vec3<f32>(1.0);
    if (along > 0.0) {
        let off = length(qt + s * along);
        let um = 1.0 - along * 0.0045;
        let pen = 1.0 + along * 0.0045;
        let f = smoothstep(um, pen, off);
        lit = mix(vec3<f32>(0.06, 0.018, 0.008), vec3<f32>(1.0), f);
    }
    let ndl = max(dot(n, s), 0.0);
    // earthshine: the day side of Earth faintly lights the Moon's night side
    let earthshine = max(dot(n, xm), 0.0) * 0.004 * (0.5 - 0.5 * dot(s, -xm));
    return vec3<f32>(1.0, 0.97, 0.92) * alb * (ndl * 1.6 * lit + earthshine);
}

@fragment
fn liveEarthFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rdw = octDecode(readTex(dirTex, p).xy);
    let T = F.time;
    let right = F.camRight.xyz;
    let up = F.camUp.xyz;
    let fwd = cross(right, up);
    let l = vec3<f32>(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    let rd = normalize(l.x * S.b.xyz + l.y * S.c.xyz + l.z * S.d.xyz);
    let ro = S.a.xyz;
    let s = S.e.xyz;
    let moonC = S.f.xyz;
    let mapped = S.h.z > 0.5;

    let ground = leSphere(ro, rd, vec3<f32>(0.0), 1.0);
    let hit = ground.x < ground.y && ground.x > 0.0;
    let tEnd = select(1e9, ground.x, hit);
    var col = vec3<f32>(0.0);
    let moonlight = S.g.w * 0.5 * (1.0 - dot(s, normalize(moonC)));   // scaled by the Moon's lit fraction

    if (hit) {
        let P = ro + rd * ground.x;
        let n = P;
        let fp = F.pixelAngle * ground.x / max(dot(n, -rd), 0.05);
        let uv = leUV(n);
        let mu = dot(n, s);
        var sun = leSunColor(mu);
        if (S.j.w > 0.5) { sun *= 1.0 - leEclipse(P, s, moonC, S.j.y); }
        let m = normalize(moonC - P);
        let mlight = max(dot(n, m), 0.0) * moonlight;

        let lat = asin(clamp(n.z, -1.0, 1.0));
        let lod = log2(max(fp, 1e-6) / (7.67e-4 * sqrt(max(cos(lat), 0.05))));
        var alb: vec3<f32>;
        var water: f32;
        var lights: f32;
        var gr: f32;
        if (mapped) {
            let lodDay = log2(max(fp, 1e-6) / (2.1817e-3 * sqrt(max(cos(lat), 0.05))));
            alb = mix(textureSampleLevel(dayJan, mipRepeat, uv, max(lodDay, 0.0)).rgb, textureSampleLevel(dayJul, mipRepeat, uv, max(lodDay, 0.0)).rgb, S.h.w);
            water = textureSampleLevel(waterTex, mipRepeat, uv, max(lodDay - 1.0, 0.0)).r;
            lights = sq(textureSampleLevel(earthLights, mipRepeat, uv, max(lod, 0.0)).r);
            gr = sq(textureSampleLevel(earthGround, mipRepeat, uv, max(lod - 2.0, 0.0)).r);
        } else {
            let land = smoothstep(0.5, 0.54, fbm(n * 2.2 + 5.3));
            alb = mix(vec3<f32>(0.004, 0.008, 0.03), vec3<f32>(0.12, 0.13, 0.07), land);
            water = 1.0 - land;
            lights = land * smoothstep(0.6, 0.8, fbm(n * 30.0)) * 0.3;
            gr = land * 0.1;
        }
        var cloud = 0.0;
        if (S.p.x > 0.5 && S.g.x > 0.0) {
            // That day's clouds. The frames either side of the moment are each carried along the
            // motion between them (in opposite directions) to where their clouds would be now,
            // and the two meet in the middle: clouds drift between frames instead of fading.
            let f = S.p.y;
            let fl = textureSampleLevel(pastFlow, mipRepeat, uv, 0.0).rg;
            let lodC = max(lod - 1.0, 0.0);
            let ca = textureSampleLevel(pastA, mipRepeat, uv - f * fl, lodC).r;
            let cb = textureSampleLevel(pastB, mipRepeat, uv + (1.0 - f) * fl, lodC).r;
            // an eased mix, so each frame's own detail lasts longer either side of it
            let w = smoothstep(0.0, 1.0, f);
            cloud = mix(ca, cb, w) * min(S.g.x, 1.0);
            cloud = min(cloud * max(S.g.x, 1.0), 1.0);
        } else if (S.h.x > 0.5 && S.g.x > 0.0) {
            let c = textureSampleLevel(cloudTex, mipRepeat, uv, max(lod - 1.0, 0.0)).r;
            // The map is infrared: warm clear ground reads mid gray, cold high cloud near white, and
            // cold clear ground in winter in between, so only the brighter part counts as cloud.
            cloud = smoothstep(0.58, 0.97, c) * min(S.g.x, 1.0);
            cloud = min(cloud * max(S.g.x, 1.0), 1.0);
        }
        // the day side: the surface, then cloud over it, lit by sunlight that reddens toward dusk
        let ndl = max(mu, 0.0);
        let surf = alb * mix(1.0, 0.25, cloud) + vec3<f32>(0.82, 0.84, 0.88) * cloud;
        var day = surf * sun * (ndl * 1.25 + 0.03 * smoothstep(-0.08, 0.05, mu));
        // the sun's glint off open water, centered between us and the sun
        let hv = normalize(s - rd);
        let nh = max(dot(n, hv), 0.0);
        let glint = (pow(nh, 1500.0) * 1.4 + pow(nh, 120.0) * 0.07) * water * (1.0 - cloud) * smoothstep(0.0, 0.1, mu);
        day += sun * glint;
        // the night side: city lights (hidden under cloud), moonlit ground and clouds
        let night = smoothstep(0.08, -0.12, mu);
        let lc = mix(vec3<f32>(1.0, 0.62, 0.3), vec3<f32>(0.85, 0.9, 1.0), smoothstep(0.15, 0.9, lights) * 0.55);
        let flicker = 0.92 + 0.08 * noise3(n * 900.0 + vec3<f32>(0.0, 0.0, T * 0.6));
        let city = lc * lights * S.g.z * 4.0 * flicker * (1.0 - 0.85 * cloud) * night;
        let moonlit = (alb * 0.9 + vec3<f32>(0.01, 0.015, 0.03) * gr) * mlight * 0.03 * (1.0 - cloud)
                    + vec3<f32>(0.8, 0.84, 0.95) * cloud * mlight * 0.022;
        col = day + city + moonlit * night * vec3<f32>(0.85, 0.9, 1.1);
        // the chosen place: a small soft ring round it
        if (S.i.w > 0.5) {
            let d = acos(clamp(dot(n, S.i.xyz), -1.0, 1.0)) / max(fp, 1e-5);
            let ring = exp(-sq((d - 3.2) / 0.9)) + 0.6 * exp(-sq(d / 1.1));
            col = mix(col, vec3<f32>(1.0, 0.85, 0.55) * (0.08 + 0.4 * max(mu, 0.0)), ring * 0.8);
        }
    } else {
        // stars, and the Moon where it really is, unless Earth is in front of it
        if (S.j.z > 0.5) {
            col = leSky(rd, F.pixelAngle);
        } else {
            col = SKY(p, rdw, false);
        }
        col = skyPlanets(col, rd, F.pixelAngle, i32(S.o.x), S.o.y);
        let mh = leSphere(ro, rd, moonC, S.f.w);
        if (mh.x < mh.y && mh.x > 0.0) {
            let q = ro + rd * mh.x;
            let edge = smoothstep(0.0, 1.5, (S.f.w - length(cross(moonC - ro, rd))) / (F.pixelAngle * mh.x));
            col = mix(col, leMoonColor(q, moonC, S.j.y, s, mapped), edge);
        }
        // the sun itself, with its glare (hidden at night if asked; its light still falls on everything)
        if (S.e.w > 0.5) {
            let ang = acos(clamp(dot(rd, s), -1.0, 1.0));
            let disk = smoothstep(LE_SUN_R + F.pixelAngle, LE_SUN_R - F.pixelAngle * 0.5, ang);
            col += vec3<f32>(1.0, 0.96, 0.9) * (disk * 40.0 + 0.5 * exp(-ang / 0.012) + 0.08 * exp(-ang / 0.08));
        }
    }

    // the air: march through the shell, scattering sunlight blue where it's lit and orange along
    // the terminator, piling up into a bright rim at the limb, and glowing faintly by moonlight
    let shell = leSphere(ro, rd, vec3<f32>(0.0), 1.0 + LE_ATMO);
    if (shell.x < shell.y && S.j.x > 0.0) {
        let t0 = max(shell.x, 0.0);
        let t1 = min(shell.y, tEnd);
        let N = 16;
        let dt = (t1 - t0) / f32(N);
        let jit = hash13(vec3<f32>(vec2<f32>(p), 3.0));
        var scat = vec3<f32>(0.0);
        var aur = vec3<f32>(0.0);
        var depth = 0.0;
        let cosTheta = dot(rd, s);
        // Rayleigh's phase, plus a forward lobe for the haze, which lights the rim from behind
        let phase = 0.75 * (1.0 + sq(cosTheta)) + 1.2 * exp((cosTheta - 1.0) * 12.0);
        let auroraOn = S.h.y > 0.5 && S.g.y > 0.0;
        let auroraT = T * S.n.z;
        for (var i = 0; i < N; i++) {
            let x = ro + rd * (t0 + (f32(i) + jit) * dt);
            let r = length(x);
            let a = r - 1.0;
            let dens = exp(-max(a, 0.0) / LE_SCALE_H);
            let mu = dot(x / r, s);
            var sunHere = leSunColor(mu);
            // the Moon's shadow darkens the air too, which is most of the light over the sea
            if (S.j.w > 0.5) { sunHere *= 1.0 - leEclipse(x, s, moonC, S.j.y); }
            let light = sunHere * phase + vec3<f32>(0.2, 0.25, 0.4) * moonlight * 0.004;
            scat += dens * light * exp(-depth * LE_RAYLEIGH * 1.6) * dt;
            depth += dens * dt;
            if (auroraOn && a > 0.012) { aur += leAuroraEmit(x, a, auroraT, s) * dt; }
        }
        col *= exp(-depth * LE_RAYLEIGH * 0.9);
        col += scat * LE_RAYLEIGH * 9.0 * S.j.x;
        col += aur * S.g.y * 18.0;
    }
    return finalize(col, p);
}
