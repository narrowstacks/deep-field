// ---------- per-frame: eclipse ---------- (ShaderEclipse.swift)
// A total solar eclipse seen from the surface of a small moon. Without air the sky stays black and
// the corona shows whenever the sun's glare allows; with air the sky scatters the remaining
// sunlight, and at totality light from outside the shadow rings the horizon like a sunset. The
// eye (and the exposure) adapts as the sun is covered. The scene has its own camera: screen
// coordinates in half screen heights, a ray through each at `th` per unit, pitched up by `pitch`.
// The world frame has y up, the camera at the origin, and the moon's center straight below.
// Sky features are laid out on the plane of the sky around the sun, in sun radii.
//
// S.a = sun direction, tan of the sun's angular radius
// S.b = occluder center relative to the sun (sun radii, along sx, sy), occluder radius, sunlight still reaching us (0..1)
// S.c = corona color, corona size
// S.d = prominence color, prominence amount
// S.e = ground color, landscape on (1) or off (0)
// S.f = sky body direction, tan of its angular radius (0 = none)
// S.g = sky body color, corona brightness
// S.h = eruption: angle round the sun, progress, brightness, seed
// S.i = tan of half the vertical field of view, camera pitch, shadow parallax (sun radii per moon radius), sky body's lit fraction
// S.j = middle of the uncovered sunlight (sun radii), eye adaptation gain, log10 of the uncovered sunlight
// S.k = air's scattering color (brightest channel 1), density (0 = airless)
// S.l = haze, clouds, sky body type (0 teal giant, 1 banded, 2 ringed, 3 ice giant, 4 cratered moon), ground type (0 rock, 1 ice, 2 desert, 3 basalt)
// S.m = eruption style (0 a lifting prominence and its bubble, 1 a bare, fast ejection), eruption scale,
//       sunlight our occluder alone lets through (0..1), the share of that the sky body leaves
// S.n = pixel size (screen pixels per shaded pixel), unused x3

const EC_HEIGHT: f32 = 0.0098;   // the camera above the ground, moon radii (the horizon dips 8 degrees)
const EC_MOUNT: f32 = 0.012;     // the occluder's limb relief, sun radii
const EC_AXIS: f32 = 0.35;       // the sun's spin axis, radians from the sky's up

// The occluder's limb: mountains (+) and valleys (-), whole numbers of waves round the limb so
// there's no seam. Valleys let the last beads of sunlight through. Mirrors SceneParams.eclipseLimb.
fn ecLimb(a: f32) -> f32 {
    let hills = 0.35 * sin(7.0 * a + 1.3) + 0.2 * sin(13.0 * a + 0.4) + 0.1 * sin(29.0 * a + 2.1);
    let notches = pow(max(sin(11.0 * a + 0.7), 0.0), 12.0) + 0.8 * pow(max(sin(17.0 * a + 2.9), 0.0), 12.0)
                + 0.7 * pow(max(sin(23.0 * a + 4.4), 0.0), 16.0);
    return hills - 1.3 * notches;
}

// The share of the sun's disk (radius 1) left uncovered by a smooth disk of radius R, d away.
fn ecUncovered(d: f32, R: f32) -> f32 {
    if (d >= 1.0 + R) { return 1.0; }
    if (d <= R - 1.0) { return 0.0; }
    let a1 = acos(clamp((d * d + 1.0 - R * R) / (2.0 * d), -1.0, 1.0));
    let a2 = acos(clamp((d * d + R * R - 1.0) / (2.0 * d * R), -1.0, 1.0));
    let k = max((-d + 1.0 + R) * (d + 1.0 - R) * (d - 1.0 + R) * (d + 1.0 + R), 0.0);
    return 1.0 - (a1 + R * R * a2 - 0.5 * sqrt(k)) / PI;
}

// The corona: a smooth K corona falling steeply from the limb, helmet streamers (broad over
// the active belts, narrowing into long rays) and polar plumes, with fine radial striations and
// density drifting outward in the solar wind. The streamers sway, swell and fade over minutes,
// sped up from the days the real ones take. Returns light.
fn ecCorona(d: vec2<f32>, r: f32, T: f32, size: f32, tint: vec3<f32>) -> vec3<f32> {
    let a = atan2(d.y, d.x);
    let rs = 1.0 + (r - 1.0) / size;
    let u = log(rs);
    let cs = vec2<f32>(cos(a), sin(a));
    let base = 0.42 * pow(rs, -14.0) + 0.16 * pow(rs, -3.0);
    // streamers: rooted along the equator (90 degrees from the axis), leaning with the field
    var str = 0.0;
    for (var k = 0; k < 12; k++) {
        let fk = f32(k);
        let hk = hash33(vec3<f32>(fk * 3.1, 7.7, 1.9));
        let h4 = fract(hk.x * 7.3 + hk.y * 3.1);
        let side = select(PI, 0.0, hk.x < 0.5);
        let sway = 0.12 * sin(T * (0.006 + 0.004 * hk.z) + fk * 1.7) + 0.05 * sin(T * 0.017 + fk * 4.1);
        let a0 = EC_AXIS + 1.5708 + side + (hk.y - 0.5) * select(2.6, 1.2, k < 6) + sway;
        let bend = ((hk.z - 0.5) * 0.9 + 0.25 * sin(T * 0.009 + fk * 2.3)) * (1.0 - 1.0 / rs);
        // a broad helmet near the limb pinching into a long thin stalk, swelling and thinning
        let breathe = 0.85 + 0.25 * sin(T * (0.011 + 0.006 * h4) + fk * 5.3);
        let w = (0.16 + 0.24 * hk.z) * (0.45 + 1.0 * exp(-(rs - 1.0) * 1.6)) * breathe;
        let da = wrapPi(a - a0 - bend);
        let reach = 1.0 + 1.3 * h4;              // how far it carries: lower falls off faster
        let amp = (0.25 + 0.5 * h4) * (0.75 + 0.35 * sin(T * (0.008 + 0.005 * hk.y) + fk * 3.7));
        str += exp(-sq(da / w)) * amp * pow(rs, -reach);
    }
    let stream = str;
    // polar plumes: thin straight rays fanning out of the poles, flickering slowly
    let pa = abs(cos(wrapPi(a - EC_AXIS)));
    let plumes = smoothstep(0.75, 0.97, pa) * pow(rs, -4.5) * (0.4 + 0.9 * smoothstep(0.45, 0.8, noise3(vec3<f32>(cs * 30.0, 3.0 + T * 0.01))));
    let rays = 0.7 + 0.6 * noise3(vec3<f32>(cs * 16.0, u * 0.8 + 4.0 + T * 0.004));
    let flow = 0.7 + 0.6 * noise3(vec3<f32>(cs * 7.0, u * 5.0 - T * 0.05));
    let flow2 = 0.8 + 0.4 * noise3(vec3<f32>(cs * 12.0, u * 7.0 - T * 0.09 + 9.0));
    var I = base * (0.85 + 0.3 * rays) + stream * mix(1.0, rays * flow * flow2, 0.7) * 0.6 + plumes * rays * 0.4 + 0.06 * pow(rs, -1.8);
    I *= exp(-sq((rs - 1.0) / 8.0));   // the outer corona thins into the sky, no edge
    // pearly near the limb, toward the corona color farther out, the hue drifting round it
    let drift = noise3(vec3<f32>(cs * 2.0, 11.0 + T * 0.003));
    let pearl = vec3<f32>(1.0, 0.96, 0.9);
    var c = mix(pearl, tint, smoothstep(1.1, 2.6, rs) * (0.65 + 0.5 * drift));
    c = mix(c, c * vec3<f32>(1.05, 0.92, 1.1), smoothstep(0.4, 0.8, drift) * smoothstep(1.4, 3.0, rs));
    return c * I;
}

// One layer of craters `cell` apart: bowls with raised rims and ejecta aprons, `depth` deep
// (1 = fresh). Adds height, slope (in the uv plane), and the shadows the rims cast onto the
// floors for two lights, each given as a horizontal direction (xy) and the tangent of its
// elevation (z), w = penumbra. Each crater keeps its rim inside its own cell, so craters of one
// size never overlap; `occ` carries where bigger craters' walls and rims are, and smaller craters
// fade out there instead of straddling them. Big craters have flatter floors and steeper walls,
// fresh walls are brighter than the dusty floors, and `ej` collects their ejecta (for boulders).
// Which craters show is judged by their size in screen pixels (`fps`), so a bigger pixel size
// draws the same craters, coarser, and drops only those under about a shaded pixel (`fp`).
fn ecCraters(uv: vec2<f32>, cell: f32, seed: f32, fp: f32, fps: f32, depth: f32, L1: vec4<f32>, L2: vec4<f32>,
             h: ptr<function, f32>, g: ptr<function, vec2<f32>>, sh1: ptr<function, f32>, sh2: ptr<function, f32>,
             alb: ptr<function, f32>, occ: ptr<function, f32>, ej: ptr<function, f32>) {
    if (cell * 0.12 < fps || cell * 2.1 < fp) { return; }   // the whole layer is too small to see: just the albedo
    let cid = floor(uv / cell);
    let occIn = *occ;
    for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
        let c = cid + vec2<f32>(f32(i), f32(j));
        let hh = hash33(vec3<f32>(c, seed));
        if (hh.z > 0.75) { continue; }
        let size = sq(hh.z / 0.75);
        let rr = 0.12 + 0.3 * size;                  // radius over cell
        let rad = cell * rr;
        // big craters are shallower for their width (their walls slump), so the low sun shadows
        // only the near part of their floors
        let D = (0.28 - 0.19 * size) * depth;
        let RIM = (0.06 - 0.02 * size) * depth;
        // the rim (with its wobble) stays inside the cell
        let ctr = (c + 0.5 + (0.5 - rr * 1.12) * (2.0 * hh.xy - 1.0)) * cell;
        let l = (uv - ctr) / rad;
        let r0 = length(l);
        if (r0 > 2.3) { continue; }
        // worn, slightly polygonal rims rather than perfect circles
        let wob = noise3(vec3<f32>(l / max(r0, 1e-4) * 1.8, seed * 3.0 + c.x * 0.37 + c.y));
        let rho = r0 * (1.0 + 0.14 * (wob - 0.5));
        if (rho > 2.1) { continue; }
        // craters a few screen pixels across fade out, and so do those under a shaded pixel
        let k = smoothstep(0.8, 2.5, rad / fps) * smoothstep(0.2, 0.5, rad / fp) * (1.0 - 0.9 * occIn);
        // inner profile rho^p: a bowl when small, a flat floor and steep walls when big
        let pw = 2.0 + 2.0 * size;
        let rp = pow(max(rho, 1e-4), pw - 1.0);
        let fin = D * (rp * rho - 1.0) + RIM;
        let din = pw * D * rp;
        let eo = exp(-(rho - 1.0) * 2.8);
        let fout = RIM * eo * smoothstep(2.1, 1.5, rho);
        let dout = -2.8 * RIM * eo * smoothstep(2.1, 1.5, rho);
        let m = smoothstep(0.92, 1.08, rho);
        let f = mix(fin, fout, m);
        let df = mix(din, dout, m);
        *h += k * f * rad;
        *g += k * df * l / max(r0, 1e-4);
        let band = smoothstep(0.45, 0.85, rho) * smoothstep(1.6, 1.05, rho);
        *occ = max(*occ, k * band);
        *ej = max(*ej, k * smoothstep(0.9, 1.15, rho) * smoothstep(2.0, 1.2, rho) * depth);
        // the dust has slid off the walls and pooled on the floor
        *alb += k * depth * (0.12 * smoothstep(0.55, 0.9, rho) * smoothstep(1.15, 0.95, rho) - 0.07 * smoothstep(0.7, 0.3, rho));
        if (rho < 1.05) {
            // the rim on the light's side shades the floor below it
            let b1 = dot(l, L1.xy);
            let b2 = dot(l, L2.xy);
            let t1 = -b1 + sqrt(max(b1 * b1 - rho * rho + 1.0, 0.0));
            let t2 = -b2 + sqrt(max(b2 * b2 - rho * rho + 1.0, 0.0));
            let drop = RIM + 0.02 * depth - f;
            let p1 = 0.04 + L1.w * t1;
            let p2 = 0.04 + L2.w * t2;
            *sh1 *= mix(1.0, smoothstep(-p1, p1, t1 * L1.z - drop), k);
            *sh2 *= mix(1.0, smoothstep(-p2, p2, t2 * L2.z - drop), k);
        }
        // fresh craters: a bright apron streaked with rays
        if (hh.x > 0.86) {
            let ang = atan2(l.y, l.x);
            let streak = 0.5 + 0.8 * smoothstep(0.45, 0.8, noise3(vec3<f32>(cos(ang) * 6.0, sin(ang) * 6.0, seed + c.x)));
            *alb += 0.45 * k * depth * exp(-max(rho - 1.0, 0.0) * 1.1) * smoothstep(0.6, 1.0, rho) * streak;
        }
    }
    }
}

// Boulders `cell` apart: rounded blocks, more of them where `ej` says crater ejecta lies, each
// lit on its sunward side and casting a short soft shadow away from the sun (L as for ecCraters).
fn ecBoulders(uv: vec2<f32>, cell: f32, seed: f32, fp: f32, fps: f32, chance: f32, ej: f32, L: vec4<f32>,
              g: ptr<function, vec2<f32>>, sh: ptr<function, f32>, alb: ptr<function, f32>) {
    if (cell * 0.15 < fps || cell * 1.1 < fp) { return; }
    let cid = floor(uv / cell);
    let perpL = vec2<f32>(-L.y, L.x);
    let len = 0.7 / max(L.z, 0.15);                // shadow length, in boulder radii
    for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
        let c = cid + vec2<f32>(f32(i), f32(j));
        let hh = hash33(vec3<f32>(c, seed));
        if (hh.z > chance * (0.35 + 1.6 * ej)) { continue; }
        let rad = cell * (0.06 + 0.16 * fract(hh.z * 13.7));
        let ctr = (c + 0.2 + 0.6 * hh.xy) * cell;
        let l = (uv - ctr) / rad;
        let k = smoothstep(0.7, 2.0, rad / fps) * smoothstep(0.2, 0.5, rad / fp);
        // a little irregular, flattened along a random direction
        let ax = vec2<f32>(cos(hh.x * 6.28), sin(hh.x * 6.28));
        let le = l + ax * dot(l, ax) * 0.35;
        let r2 = dot(le, le);
        if (r2 < 1.0) {
            let hz = sqrt(1.0 - r2);
            *g -= k * le / max(hz, 0.25) * 0.7;
            *alb += k * 0.06 * (hh.y - 0.5);
        }
        let along = dot(l, -L.xy);
        let across = abs(dot(l, perpL));
        if (along > 0.0 && r2 > 0.8) {
            let s = smoothstep(1.0, 0.6, across) * smoothstep(len + 0.4, len - 0.3, along);
            *sh *= 1.0 - 0.85 * k * s;
        }
    }
    }
}

// Distance to the nearest border of a jittered grid of cells one unit apart (roughly): the
// cracks in ice plates and in a cooling lava crust.
fn ecCellEdge(x: vec2<f32>, seed: f32) -> f32 {
    let i = floor(x);
    let f = fract(x);
    var f1 = 8.0;
    var f2 = 8.0;
    for (var yy = -1; yy <= 1; yy++) {
    for (var xx = -1; xx <= 1; xx++) {
        let g = vec2<f32>(f32(xx), f32(yy));
        let o = g + hash33(vec3<f32>(i + g, seed)).xy - f;
        let dd = dot(o, o);
        if (dd < f1) { f2 = f1; f1 = dd; } else if (dd < f2) { f2 = dd; }
    }
    }
    return 0.5 * (sqrt(f2) - sqrt(f1));
}

// The far rims standing along the horizon, radians above the smooth horizon, by azimuth.
fn ecSkyline(az: f32, relief: f32) -> f32 {
    let c = vec2<f32>(cos(az), sin(az));
    let mesa = smoothstep(0.35, 0.75, fbm(vec3<f32>(c * 2.6, 1.7)));
    return (0.003 + 0.016 * mesa + 0.006 * fbm(vec3<f32>(c * 11.0, 5.0))) * relief + 0.002 * noise3(vec3<f32>(c * 40.0, 2.0));
}

// Rings' opacity at r planet radii: dense middle ring, a dark gap, a fainter outer ring.
fn ecRing(rr: f32, fpR: f32) -> f32 {
    if (rr < 1.28 || rr > 2.4) { return 0.0; }
    let fine = 1.0 - smoothstep(0.004, 0.012, fpR);
    var a = 0.55 + 0.25 * sin(rr * 41.0) + 0.15 * sin(rr * 113.0 + 1.0) * fine;
    a *= smoothstep(1.28, 1.42, rr) * smoothstep(2.4, 2.22, rr);
    a *= mix(0.35, 1.0, smoothstep(1.42, 1.68, rr));                 // the thin inner ring
    a *= 1.0 - 0.85 * exp(-sq((rr - 1.97) / 0.03));                   // the gap
    a *= mix(1.0, 0.6, smoothstep(2.0, 2.06, rr));                    // the outer ring is fainter
    return saturate(a) * 0.9;
}

// Air mass along a ray at elevation sine y: 1 overhead, growing toward the horizon.
fn ecAirmass(y: f32) -> f32 {
    let yy = max(y, 0.0);
    return 1.0 / (yy + 0.065 * exp(-yy * 10.0) + 0.012);
}

@fragment
fn eclipseFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let W = F.camRight.w;
    let H = F.camUp.w;
    let T = F.time;
    let q = vec2<f32>((f32(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(f32(p.y) + 0.5 - H * 0.5) / (H * 0.5)) * F.screenScale;
    let th = S.i.x;
    let pitch = S.i.y;
    let rc = normalize(vec3<f32>(q * th, 1.0));
    let cp = cos(pitch);
    let sp = sin(pitch);
    let rd = vec3<f32>(rc.x, rc.y * cp + rc.z * sp, -rc.y * sp + rc.z * cp);
    let pixA = 2.0 * th * F.screenScale / H;       // radians per pixel, near the middle

    let sunD = S.a.xyz;
    let ts = S.a.w;
    let sx = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), sunD));
    let sy = cross(sunD, sx);
    let o = S.b.xy;
    let Ro = S.b.z;
    let eCam = S.b.w;
    let gain = S.j.z;
    let logE = S.j.w;
    let adapt = gain / 2.5;                          // how far the eye has opened since full sun
    let coronaVis = smoothstep(-2.4, -4.3, logE);
    var starVis = smoothstep(-2.6, -4.5, logE);
    let glareAmp = smoothstep(-5.6, -4.0, logE) * (0.6 + 2.4 * smoothstep(-3.5, 0.0, logE));
    let sunCol = vec3<f32>(1.0, 0.94, 0.85);
    let body = i32(S.l.z + 0.5);
    let world = i32(S.l.w + 0.5);

    // ---- air: what it scatters toward us along this ray, and what it lets through ----
    let dens = S.k.w;
    let air = dens > 0.0;
    let airC = S.k.rgb;
    let haze = S.l.x;
    let clouds = S.l.y;
    // extinction per unit air mass: the gas scatters its sky color out of the beam; haze is
    // mostly gray, but absorbs the sky color's complement (Titan's smog swallows blue, which is
    // why it glows orange)
    let beta = airC * (1.0 - 0.5 * saturate(haze)) + 0.6 * haze * mix(vec3<f32>(1.0), max(1.15 - airC, vec3<f32>(0.0)), 0.7);
    var Tview = vec3<f32>(1.0);
    var skyIn = vec3<f32>(0.0);
    var sunT = vec3<f32>(1.0);
    var sunset = vec3<f32>(1.0);
    var shadeDeep = 0.0;
    let sunLight = gain * eCam;                                  // the adapted sunlight still arriving
    if (air) {
        let mV = ecAirmass(rd.y);
        let mS = ecAirmass(sunD.y);
        Tview = exp(-dens * 0.3 * mV * beta);
        sunT = exp(-dens * 0.13 * mS * beta);
        let cosS = dot(rd, sunD);
        // the haze's own color, and the forward glow round the sun, tinted toward the
        // complement of the sky (fine dust throws its blue forward, as on Mars)
        let hazeCol = mix(airC, vec3<f32>(1.0, 0.95, 0.88), 0.35);
        let aureole = mix(vec3<f32>(1.0), normalize(max(1.15 - airC, vec3<f32>(0.05))) * 1.5, 0.55);
        let near = exp((cosS - 1.0) / 0.04);
        let phaseR = 0.75 * (1.0 + cosS * cosS);
        let phaseM = 0.3 + 3.0 * near + 0.6 * exp((cosS - 1.0) / 0.3);
        let scat = (airC * phaseR + haze * mix(hazeCol, aureole, near) * phaseM) / (beta + 1e-3);
        skyIn = sunLight * sunT * scat * (1.0 - Tview) * 0.5;
        // in the shadow, sunlight scattered in from beyond its edge: a sunset glow all round the
        // horizon (light that's crossed a long path of air, so reddened), deep blue-violet above
        shadeDeep = 1.0 - smoothstep(-2.6, -0.9, logE);
        // its color: a blue (molecular) sky's glow has lost its blue on the long path, so it's
        // orange; a hazy, colored sky's glow is that color deepened
        let blueness = saturate(airC.b - airC.r);
        sunset = mix(pow(airC, vec3<f32>(1.6)), vec3<f32>(1.0, 0.42, 0.12), blueness);
        sunset /= max(max(sunset.r, sunset.g), max(sunset.b, 1e-3));
        let yy = max(rd.y, 0.0);
        let band = 0.75 * exp(-yy / 0.035) + 0.25 * exp(-yy / 0.12);
        let low = mix(sunset, sunset * vec3<f32>(1.0, 0.6, 0.5), exp(-yy / 0.015) * 0.6);   // reddest right at the horizon
        let above = airC * vec3<f32>(0.6, 0.45, 1.2);
        skyIn += gain * 0.0045 * min(dens, 2.0) * shadeDeep * (low * band * 1.2 + above * 0.22 * (1.0 - band));
        // and the air drowns the fainter stars
        let lum = dot(skyIn, vec3<f32>(0.2126, 0.7152, 0.0722));
        starVis *= exp(-dens * 0.2 * mV) / (1.0 + lum * 60.0);
    }

    // ---- sky ----
    let sd = dot(rd, sunD);
    var d = vec2<f32>(dot(rd, sx), dot(rd, sy)) / max(sd, 1e-3) / ts;
    if (sd <= 0.0) { d = vec2<f32>(1e4); }
    let r = length(d);
    let px = pixA / ts;                              // one pixel in sun radii
    var col = SKY(p, octDecode(readTex(dirTex, p).xy), false) * starVis;

    // the body in the sky, lit by the sun from beside it, so a crescent
    let tp = S.f.w;
    var pHit = 0.0;
    let planetCol = S.g.rgb;
    if (tp > 0.0) {
        let Pc = S.f.xyz;
        let Rp = tp / sqrt(1.0 + tp * tp);
        let ps = sphereSpan(-Pc, rd, Rp);
        let bp = length(cross(rd, Pc));               // ray's closest approach to its center
        let hitP = ps.x < ps.y && ps.x > 0.0;
        let rn = normalize(vec3<f32>(0.6, 1.0, -0.1));  // the ring plane, the planet's equator
        if (hitP) {
            let Pp = rd * ps.x;
            let N = normalize(Pp - Pc);
            let ax = select(normalize(vec3<f32>(-0.25, 1.0, -0.1)), rn, body == 2);
            let lat = dot(N, ax);
            let fpP = pixA / Rp;
            let warp = fbm(N * 3.0 + 2.0) - 0.5;
            let mu = saturate(dot(N, -rd));
            let nl = dot(N, sunD);
            var alb = vec3<f32>(0.0);
            var rim = 0.6;
            if (body == 4) {
                // a cratered moon: patchy maria and highlands, crater rims, no air
                let big = fbm(N * 2.2 + 4.0);
                let cr = ecCellEdge(vec2<f32>(atan2(N.x, N.z), lat) * 7.0, 3.0);
                let rimL = exp(-sq(cr / max(0.06, fpP * 10.0)));
                alb = planetCol * (0.55 + 0.6 * smoothstep(0.35, 0.65, big) + 0.25 * (fbmLOD(N * 16.0, fpP * 16.0) - 0.5) + 0.2 * rimL);
                rim = 0.0;
            } else {
                let lt = lat + warp * select(0.06, 0.1, body == 1);
                let bands = 0.5 + 0.5 * sin(lt * 26.0 + 2.0 * sin(lt * 7.0 + 1.0));
                let fine = fbmLOD(vec3<f32>(N.xz * 18.0, lt * 60.0), fpP * 18.0);
                if (body == 1) {
                    // ivory zones and rust belts, curling where they meet, darker toward the poles
                    let tz = smoothstep(0.3, 0.7, bands + (fine - 0.5) * 0.7);
                    alb = mix(planetCol * vec3<f32>(0.72, 0.48, 0.32), planetCol, tz);
                    alb *= 1.0 - 0.35 * smoothstep(0.6, 0.95, abs(lat));
                } else if (body == 2) {
                    alb = planetCol * (0.85 + 0.2 * bands + 0.12 * (fine - 0.5));
                } else if (body == 3) {
                    alb = planetCol * (0.93 + 0.06 * bands + 0.04 * (fine - 0.5));
                    rim = 1.0;
                } else {
                    alb = planetCol * (0.62 + 0.5 * bands + 0.25 * (fine - 0.5));
                    alb = mix(alb, alb * vec3<f32>(1.15, 0.95, 0.8), smoothstep(0.6, 0.85, bands) * 0.25);   // warmer light zones
                }
            }
            var day = select(smoothstep(-0.06, 0.25, nl) * (0.35 + 0.65 * saturate(nl)),
                             smoothstep(-0.02, 0.1, nl) * saturate(nl + 0.05), body == 4);
            if (body == 2) {
                // the rings' shadow across the planet
                let den = dot(sunD, rn);
                if (abs(den) > 1e-3) {
                    let tS = dot(Pc - Pp, rn) / den;
                    if (tS > 0.0) { day *= 1.0 - 0.85 * ecRing(length(Pp + sunD * tS - Pc) / Rp, fpP); }
                }
            }
            var pc = alb * day * 1.1 * (0.5 + 0.5 * pow(mu, 0.4)) * pow(adapt, 0.2);
            // a thin haze lights up along the sunward limb
            pc += mix(planetCol, vec3<f32>(0.7, 0.85, 1.0), 0.5) * pow(1.0 - mu, 3.0) * smoothstep(-0.2, 0.4, nl) * rim;
            // the night side, faintly lit by our moon
            pc += alb * 0.0003 * adapt * (1.0 - day);
            pHit = smoothstep(Rp + pixA * 1.0, Rp - pixA * 1.0, bp);
            col = mix(col, pc, pHit);
        } else if (body != 4) {
            // haze glowing just off the sunward limb
            let off = (bp - Rp) / Rp;
            let Nl = normalize(rd * dot(rd, Pc) - Pc);
            col += mix(planetCol, vec3<f32>(0.6, 0.8, 1.0), 0.5) * exp(-max(off, 0.0) / 0.012) * smoothstep(-0.2, 0.5, dot(Nl, sunD)) * 0.25;
        }
        if (body == 2) {
            // the rings: in front of the planet or beside it, hidden where it stands in front
            let den = dot(rd, rn);
            var tR = -1.0;
            if (abs(den) > 1e-4) { tR = dot(Pc, rn) / den; }
            if (tR > 0.0 && (!hitP || tR < ps.x)) {
                let R3 = rd * tR;
                let fpR = pixA * tR / Rp / max(abs(den), 0.05);
                let ra = ecRing(length(R3 - Pc) / Rp, fpR);
                if (ra > 0.0) {
                    // lit face when the sun and we are on the same side; the far side glows dimly
                    // where thin; dark inside the planet's shadow
                    let litFace = dot(rn, sunD) * dot(rn, -rd) > 0.0;
                    let sh = sphereSpan(R3 - Pc, sunD, Rp);
                    let inShadow = select(1.0, 0.03, sh.x < sh.y && sh.y > 0.0);
                    let lightR = select(0.6 * (1.0 - ra), 0.35 + 0.65 * abs(dot(rn, sunD)), litFace);
                    let grain = 0.85 + 0.3 * noise3(vec3<f32>(length(R3 - Pc) / Rp * 60.0, 1.0, 2.0));
                    let rcol = planetCol * vec3<f32>(1.0, 0.95, 0.86) * grain * lightR * inShadow * 1.1 * pow(adapt, 0.2);
                    col = mix(col, rcol, ra);
                    pHit = max(pHit, ra);
                }
            }
        }
    }

    var sky = vec3<f32>(0.0);
    if (r < 1.0 + 20.0 * S.c.w) {   // well past where the corona has faded out
        // corona, behind everything round the sun
        let cor = ecCorona(d, max(r, 1.0), T, S.c.w, S.c.rgb) * S.g.w;
        sky += cor * mix(0.05, 1.0, coronaVis) * smoothstep(1.0 - px, 1.0 + px, r);

        let h = r - 1.0;
        let ang = atan2(d.y, d.x);
        let promCol = S.d.rgb;
        // the chromosphere and prominences are drowned by the photosphere's glare until only a
        // thin crescent is left (they show at the very start and end of totality), so none at full sun
        let promVis = smoothstep(-1.8, -3.4, logE);
        let amt = S.d.w;
        // the chromosphere: a thin pink shell, a fringe of spicules over it
        if (h > -px && h < 0.08) {
            let cs = vec2<f32>(cos(ang), sin(ang));
            let jets = smoothstep(0.35, 0.8, noise3(vec3<f32>(cs * 140.0, h / 0.01 - T * 0.05)));
            let top = 0.012 + 0.012 * noise3(vec3<f32>(cs * 60.0, T * 0.02));
            let chrom = exp(-max(h, 0.0) / 0.006) * 0.8 + smoothstep(top, top * 0.3, h) * jets * 0.6;
            sky += promCol * chrom * smoothstep(-px, px, h) * 2.5 * promVis;
        }
        // prominences round the limb: each grows up out of the chromosphere, leans and twists
        // as it stands, drains and fades, and another forms elsewhere
        if (amt > 0.0 && h < 0.45 && h > -px) {
            var prom = 0.0;
            for (var i = 0; i < 7; i++) {
                let fi = f32(i);
                let life = 220.0 + 200.0 * hash13(vec3<f32>(fi, 11.0, 2.0));
                let cyc = T / life + hash13(vec3<f32>(fi, 12.0, 2.0));
                let gen = floor(cyc);
                let age = fract(cyc);
                if (hash13(vec3<f32>(fi, gen, 19.0)) > amt * 0.6) { continue; }
                let a0 = 6.2831853 * hash13(vec3<f32>(fi, gen, 13.0));
                let Lp = 0.09 + 0.13 * hash13(vec3<f32>(fi, gen, 14.0));
                let Hp = (0.1 + 0.16 * hash13(vec3<f32>(fi, gen, 15.0))) * (0.55 + 0.6 * smoothstep(0.0, 0.6, age));
                let lean = (hash13(vec3<f32>(fi, gen, 17.0)) - 0.5) * 0.8 + 0.35 * sin(T * 0.015 + fi * 2.1);
                let s = wrapPi(ang - a0) - lean * h;
                if (abs(s) > Lp * 1.4 || h > Hp * 1.7) { continue; }
                var vis = smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.8, 1.0, age));
                // draining: late in its life the upper part thins first
                vis *= 1.0 - smoothstep(0.7, 1.0, age) * smoothstep(0.0, Hp, h) * 0.7;
                prom += prominence(vec2<f32>(s, h), Lp, Hp, hash13(vec3<f32>(fi, gen, 16.0)), fi * 5.3 + gen * 1.7, T, px) * vis;
            }
            sky += promCol * prom * (4.0 + amt) * promVis;
        }
        // surges and limb flares: a jet of chromospheric plasma shot up along the field, stalling
        // and draining back, with a brief white-hot brightening at its foot as it starts
        if (amt > 0.0 && h < 0.6 && h > -px) {
            for (var k = 0; k < 2; k++) {
                let per = 75.0 + 30.0 * f32(k);
                let ph = T / per + 0.43 * f32(k);
                let n = floor(ph);
                let f = fract(ph) * per / 42.0;
                if (f >= 1.0 || hash13(vec3<f32>(n, f32(k), 41.0)) > 0.2 + 0.4 * min(amt, 1.5)) { continue; }
                let sa = 6.2831853 * hash13(vec3<f32>(n, f32(k), 42.0));
                let seed = hash13(vec3<f32>(n, f32(k), 43.0)) * 50.0;
                let L = vec2<f32>(wrapPi(ang - sa), h);
                let top = (0.16 + 0.24 * hash13(vec3<f32>(seed, 2.0, 1.0))) * pow(max(sin(3.14159265 * f), 0.0), 0.8);
                let lean = (hash13(vec3<f32>(seed, 3.0, 1.0)) - 0.5) * 0.6;
                let x = L.x - lean * L.y;
                let wid = 0.012 + 0.12 * L.y;
                if (abs(x) < wid * 3.0 + 3.0 * px && L.y < top * 1.3 + 0.05) {
                    let xa = x / wid;
                    let topk = top * (0.6 + 0.5 * noise3(vec3<f32>(xa * 1.5, seed, f * 3.0)));
                    let env = exp(-xa * xa * 0.7) * smoothstep(topk + 0.03, topk - 0.03, L.y);
                    let flowV = select(0.2, -0.3, f < 0.5);
                    var thr = threads(x, L.y / 0.03 + T * flowV, 0.006, px, seed);
                    thr *= 0.4 + 0.9 * smoothstep(0.3, 0.7, noise3(vec3<f32>(xa * 0.8, L.y / 0.05 + T * flowV * 0.5, seed + 4.0)));
                    let bright = smoothstep(0.0, 0.05, f) * (1.0 - smoothstep(0.85, 1.0, f));
                    sky += promCol * env * thr * 2.2 * bright * promVis;
                }
                let flash = exp(-dot(L, L) / 0.006) * (1.0 - smoothstep(0.0, 0.12, f)) * smoothstep(0.0, 0.01, f);
                sky += mix(promCol, vec3<f32>(1.0, 0.95, 0.9), 0.6) * flash * 2.5 * promVis;
            }
        }

        // eruption: a big prominence lifts off, swelling into a loop of twisted threads, ahead of a
        // faint expanding bubble of corona (a coronal mass ejection); or a bare, fast ejection
        if (S.h.z > 0.0) {
            let ea = S.h.x;
            let fp = S.h.y;
            let seed = S.h.w;
            let bare = S.m.x > 0.5;
            let sc = select(1.0, S.m.y, S.m.y > 0.0);
            let L = vec2<f32>(wrapPi(ang - ea), h);
            let rise = max(fp - 0.12, 0.0) / 0.88;
            let Hh = 0.14 + 0.05 * smoothstep(0.0, 0.12, fp) + 2.4 * sc * pow(rise, 1.6);
            let Wp = 0.16 + 0.06 * smoothstep(0.1, 0.5, fp) + 0.3 * sc * rise;
            if (!bare && abs(L.x) < Wp * 1.5 + Hh * 0.4 + 0.08 && L.y < Hh * 1.5 + 0.08 && L.y > -px) {
                let Lw = L + noise2(vec3<f32>(L * 2.0 / (0.15 + Hh), seed + T * 0.01)) * (0.01 + 0.18 * Hh) * smoothstep(0.0, 0.3, L.y / Hh);
                let en = Lw / vec2<f32>(Wp, Hh);
                let e = length(en);
                let uu = atan2(max(en.y, 0.0), en.x);
                let spacing = 0.006 * (1.0 + 5.0 * rise);
                let rope = smoothstep(0.45 - 0.2 * rise, 0.72 - 0.2 * rise, e) * smoothstep(1.15 + 0.1 * rise, 0.9 - 0.1 * rise, e);
                let thr = threads(e * Hh, uu * 6.0 - T * 0.03, spacing, px, seed);
                let twist = threads(e * Hh + 0.3 * Hh * sin(uu * 3.0), uu * 3.0, spacing * 1.5, px, seed + 9.0);
                let wisps = smoothstep(0.3 + 0.15 * rise, 0.62, fbm(vec3<f32>(Lw / (0.1 + Hh) * 2.0, seed)));
                let loose = smoothstep(0.0, 0.4, rise);
                var em = rope * mix(0.6 * thr + 0.4 * twist, 1.0, 0.5 * loose) * mix(1.0, wisps, smoothstep(0.2, 0.6, fp));
                em *= smoothstep(0.0, 0.015, L.y) * 1.6 / (1.0 + 2.5 * Hh);
                let hang = 1.0 - smoothstep(0.08, 0.3, fp);
                if (hang > 0.0) { em += prominence(L, Wp * 0.9, Hh * 0.95, 0.4, seed, T, px) * hang * 1.5; }
                if (fp > 0.35 && L.y < 0.2) {
                    let lx = abs(L.x) - Wp * 0.8;
                    em += exp(-lx * lx / 8e-4) * threads(L.x, L.y / 0.015 + T * 0.4, 0.006, px, seed + 2.0)
                          * smoothstep(0.2, 0.04, L.y) * smoothstep(0.35, 0.55, fp) * 0.6;
                }
                sky += mix(promCol, vec3<f32>(1.0, 0.8, 0.85), 0.15 * loose) * em * S.h.z * promVis * 4.0;
            }
            // the bubble of corona: a soft bright front over a darker cavity, with a knot of
            // erupted prominence material trailing it
            let nrm = vec2<f32>(cos(ea), sin(ea));
            let tg = vec2<f32>(-nrm.y, nrm.x);
            let Lc = vec2<f32>(dot(d, tg), dot(d, nrm));
            let rF = 1.1 + select(4.5, 6.0, bare) * sc * pow(max(fp - select(0.08, 0.02, bare), 0.0), select(1.15, 1.0, bare));
            let hw = select(0.42, 0.5, bare);
            let sw = sin(hw);
            let rB = rF / (1.0 + sw);
            let rb = rB * sw;
            if (Lc.y > 0.0 && abs(Lc.x) < rb * 1.6 + 0.2 && Lc.y < rF + rb * 0.6) {
                let Lw = Lc + noise2(vec3<f32>(Lc * 1.5 / rb, seed + T * 0.01)) * rb * 0.18;
                let rel = Lw - vec2<f32>(0.0, rB);
                let rr = length(rel);
                let phi = atan2(rel.x, rel.y);
                let dB = rr - rb * (1.0 + 0.15 * (noise3(vec3<f32>(rel / max(rr, 1e-4) * 1.3, seed)) - 0.5));
                let thk = 0.4 * rb;
                let shell = exp(-sq(max(dB, 0.0) / (thk * 0.8))) * exp(min(dB, 0.0) / thk);
                let lead = 0.25 + 0.75 * smoothstep(-0.6, 0.9, cos(phi));
                let fib = mix(1.0, threads(dB + 0.1 * rb * noise3(vec3<f32>(phi * 2.0, seed, 3.0)), phi * 4.0, 0.07 * rb, px, seed), 0.25);
                let clumps = 0.65 + 0.5 * smoothstep(0.25, 0.75, noise3(vec3<f32>(Lw * 2.5 / rb, seed + 1.0)));
                let cav = smoothstep(0.0, -0.4 * rb, dB) * smoothstep(0.0, 0.1, fp);
                let fade = smoothstep(0.03, 0.2, fp) / (0.4 + 0.6 * rF);
                sky *= 1.0 - 0.3 * cav * S.h.z;
                sky += mix(vec3<f32>(1.0, 0.97, 0.94), S.c.rgb, 0.4) * shell * lead * fib * clumps * fade * S.h.z * select(0.6, 0.9, bare) * S.g.w * mix(0.1, 1.0, coronaVis);
                if (bare) {
                    var cw = (rel + vec2<f32>(0.0, rb * 0.4)) / rb;
                    cw += noise2(vec3<f32>(cw * 3.0, seed + 7.0)) * 0.25;
                    let core = exp(-dot(cw, cw * vec2<f32>(1.0, 1.6)) / 0.05) * smoothstep(0.35, 0.7, fbm(vec3<f32>(cw * vec2<f32>(5.0, 2.5), seed + 4.0)));
                    sky += promCol * core * fade * S.h.z * 3.0 * promVis;
                }
            }
        }

        // the photosphere, where the occluder leaves it uncovered
        let limbD = 1.0 - 0.55 * (1.0 - sqrt(max(1.0 - r * r, 0.0)));
        sky += sunCol * gain * 14.0 * limbD * smoothstep(1.0 + px, 1.0 - px, r);

        // the occluder: its night side faces us, dimly lit by the planet
        let dv = d - o;
        let ro = length(dv);
        let phiO = atan2(dv.y, dv.x);
        let Rl = Ro + EC_MOUNT * ecLimb(phiO);
        let cover = smoothstep(Rl + px, Rl - px, ro);
        if (cover > 0.0) {
            let z = sqrt(max(1.0 - sq(ro / Ro), 0.0));
            let N = vec3<f32>(dv / Ro, z);
            let shine = saturate(dot(N, normalize(vec3<f32>(-0.9, -0.1, 0.4)))) * (0.6 + 0.5 * fbm(vec3<f32>(dv * 3.0, 4.0)));
            let night = planetCol * shine * 0.0035 * adapt * S.i.w * step(0.0, tp);
            sky = mix(sky, night, cover);
            col *= 1.0 - cover;
        }

        // Baily's beads: the last sunlight shining through the limb's valleys, each with a glow
        if (length(o) < 1.0 && abs(ro - Ro) < 0.5 && r < 1.5) {
            var glow = 0.0;
            for (var k = -6; k <= 6; k++) {
                let a = phiO + f32(k) * 0.022;
                let u2 = vec2<f32>(cos(a), sin(a));
                let b = dot(o, u2);
                let ts2 = -b + sqrt(max(b * b - dot(o, o) + 1.0, 0.0));
                let Rk = Ro + EC_MOUNT * ecLimb(a);
                let gap = ts2 - Rk;
                if (gap <= 0.0) { continue; }
                let pt = o + u2 * (Rk + gap * 0.5);
                let dist2 = dot(d - pt, d - pt);
                // only thin gaps make beads: where the crescent is thicker it's plain photosphere,
                // and summing glow over it piles up a lumpy, hard-edged blob beside the crescent
                glow += saturate(gap / 0.012) * smoothstep(0.07, 0.025, gap) * (exp(-dist2 / 0.0012) * 3.0 + pow(1.0 + dist2 / 0.0075, -1.5) * 0.6);
            }
            // beads show only in the last moments before and after totality
            sky += sunCol * glow * smoothstep(-5.6, -4.0, logE) * smoothstep(-2.0, -3.0, logE);
        }
    }
    col += sky * (1.0 - pHit);

    // everything beyond the air is dimmed (and reddened low down) by it, and its glow added
    if (air) {
        col = col * Tview + skyIn;
        // a thin cloud deck drifting overhead, lit by the sun (silver toward it) or, at totality,
        // from below by the horizon's glow
        if (clouds > 0.0 && rd.y > 0.0) {
            let yy = max(rd.y, 0.035);
            let cpl = rd.xz / yy * 0.6 + vec2<f32>(T * 0.012, T * 0.005);
            let fpc = pixA * 0.6 / (yy * yy);
            let cdn = fbmLOD(vec3<f32>(cpl * 3.0, 2.0), fpc * 3.0);
            let cdn2 = fbmLOD(vec3<f32>(cpl * 9.0 + 4.0, 5.0 + T * 0.01), fpc * 9.0);
            var cov = smoothstep(0.62 - 0.32 * clouds, 0.9 - 0.2 * clouds, cdn + 0.25 * (cdn2 - 0.5));
            cov *= smoothstep(0.0, 0.1, rd.y) * clouds * 0.85;
            let cosS = dot(rd, sunD);
            let lit = sunLight * sunT * (0.3 + 1.6 * exp((cosS - 1.0) / 0.06)) * mix(vec3<f32>(1.0), airC, 0.15)
                    + skyIn * 0.6 + gain * 0.008 * min(dens, 2.0) * shadeDeep * sunset * (0.3 + 0.7 * exp(-rd.y / 0.15));
            col = mix(col, lit * 0.8, cov);
        }
    }

    // ---- the ground we stand on ----
    if (S.e.w > 0.5) {
        let Cm = vec3<f32>(0.0, -(1.0 + EC_HEIGHT), 0.0);
        let gs = sphereSpan(-Cm, rd, 1.0);
        let dip = acos(1.0 / (1.0 + EC_HEIGHT));
        let el = asin(clamp(rd.y, -1.0, 1.0));
        let az = atan2(rd.x, rd.z);
        let relief = select(select(1.0, 0.6, world == 2), 0.5, world == 1);
        let sky_top = -dip + ecSkyline(az, relief);
        let hitG = gs.x < gs.y && gs.x > 0.0;
        let edgeAA = pixA * 0.8;
        let ridge = select(smoothstep(sky_top + edgeAA, sky_top - edgeAA, el), 0.0, hitG);
        let gcol = S.e.rgb;
        // light: the sun as uncovered from each spot (the occluder's shadow has a sharp-cored
        // umbra drifting over the ground), the planet's crescent, the corona's faint glow, and
        // with air the sky's own light
        let Lpl = normalize(S.f.xyz + 0.6 * tp * normalize(sunD - S.f.xyz * dot(sunD, S.f.xyz)));
        let plI = select(0.0, S.i.w * 0.6 * adapt, tp > 0.0);
        let coI = 0.006 * S.g.w * adapt * select(1.0, 0.5, air);
        // (the limb's valleys let through a little more than a smooth disk would; the sky body,
        // far beyond our occluder, dims every spot alike)
        let resid = max(S.m.z - ecUncovered(length(o), Ro), 0.0);
        let bodyShare = S.m.w;
        let plCol = mix(planetCol, vec3<f32>(0.8, 0.9, 1.0), 0.25);
        let coCol = mix(vec3<f32>(1.0, 0.97, 0.94), S.c.rgb, 0.4);
        let skyAmb = select(vec3<f32>(0.0), sunLight * sunT * airC * 0.12 * min(dens, 2.0) + gain * 0.004 * min(dens, 2.0) * shadeDeep * sunset, air);
        let sunTint = sunCol * sunT;
        // the ground beyond a short way blends into the air's glow (aerial perspective)
        if (hitG) {
            let t = gs.x;
            let G = rd * t;
            let Ns = normalize(G - Cm);
            let mu = saturate(dot(Ns, -rd));
            let fp = pixA * t / max(mu, 0.04);
            let fps = fp / max(S.n.x, 1.0);   // the same, per screen pixel
            let uv = G.xz;
            // the lights' horizontal directions and elevations, with their penumbrae
            let sh2 = normalize(sunD.xz + 1e-5);
            let ph2 = normalize(Lpl.xz + 1e-5);
            let L1 = vec4<f32>(sh2, sunD.y / length(sunD.xz), ts * 0.7);
            let L2 = vec4<f32>(ph2, max(Lpl.y, 0.02) / length(Lpl.xz), tp * 0.5);
            var hgt = 0.0;
            var sS = 1.0;
            var sP = 1.0;
            var bright = 0.0;
            var occ = 0.0;
            var ej = 0.0;
            var grad = vec2<f32>(0.0);
            // each world wears its own relief: fresh craters on rock and basalt, shallow ones on
            // ice, a few worn ones between dunes on the desert
            let depth = select(select(1.0, 0.35, world == 2), 0.45, world == 1);
            ecCraters(uv, 0.05, 1.0, fp, fps, depth, L1, L2, &hgt, &grad, &sS, &sP, &bright, &occ, &ej);
            if (world != 2) { ecCraters(uv, 0.016, 2.0, fp, fps, depth, L1, L2, &hgt, &grad, &sS, &sP, &bright, &occ, &ej); }
            if (world == 0 || world == 3) {
                ecCraters(uv, 0.0055, 3.0, fp, fps, depth, L1, L2, &hgt, &grad, &sS, &sP, &bright, &occ, &ej);
                ecCraters(uv, 0.0018, 4.0, fp, fps, depth, L1, L2, &hgt, &grad, &sS, &sP, &bright, &occ, &ej);
            }
            // boulders: blocks thrown out round the craters, a few weathered out of the plains;
            // ice has fewer (blocks of crust), sand buries all but a scattered few
            let chance = select(select(select(0.05, 0.1, world == 1), 0.28, world == 3), 0.2, world == 0);
            ecBoulders(uv, 0.006, 5.0, fp, fps, chance, ej, L1, &grad, &sS, &bright);
            if (world != 2) { ecBoulders(uv, 0.0024, 6.0, fp, fps, chance, ej, L1, &grad, &sS, &bright); }
            // broad swells, and darker and lighter provinces (old lava plains, fresh ejecta), so
            // the plain isn't one even gray
            grad += noise2(vec3<f32>(uv * 7.0, 11.0)) * select(0.18, 0.1, world == 1) + noise2(vec3<f32>(uv * 26.0, 12.0)) * select(0.1, 0.05, world == 1);
            let prov = fbmLOD(vec3<f32>(uv * 3.0, 13.0), fp * 3.0);
            // gentle undulation and grit (smoother on ice)
            let e2 = 0.0004;
            let n0 = fbmLOD(vec3<f32>(uv * 90.0, 1.0), fp * 90.0);
            let nx = fbmLOD(vec3<f32>((uv + vec2<f32>(e2, 0.0)) * 90.0, 1.0), fp * 90.0);
            let nz = fbmLOD(vec3<f32>((uv + vec2<f32>(0.0, e2)) * 90.0, 1.0), fp * 90.0);
            grad += vec2<f32>(nx - n0, nz - n0) / e2 * select(0.0012, 0.0005, world == 1);
            var alb = (0.72 + 0.5 * (n0 - 0.5) + 0.35 * (fbmLOD(vec3<f32>(uv * 14.0, 7.0), fp * 14.0) - 0.5)) * (1.0 + bright);
            alb *= 0.84 + 0.32 * smoothstep(0.3, 0.7, prov);
            var tintG = vec3<f32>(1.0);
            var glowG = vec3<f32>(0.0);
            var spec = 0.0;
            var sparkle = 0.0;
            if (world == 2) {
                // dunes: long asymmetric ridges (gentle windward, steep lee side), rippled, in
                // patchy fields whose crests wander, with paler crests and darker, coarser troughs
                let wd = normalize(vec2<f32>(0.8, 0.6));
                let kd = 6.2831853 / 0.009;
                let ph = dot(uv, wd) * kd + 5.0 * fbm(vec3<f32>(uv * 12.0, 3.0));
                let kf = smoothstep(0.7, 2.0, 0.009 / max(fp, 1e-6) / 2.0) * (0.5 + 0.5 * smoothstep(0.3, 0.6, prov));
                grad += wd * 0.00022 * kd * (cos(ph) + 0.45 * cos(2.0 * ph)) * kf;
                let kr = 6.2831853 / 0.0011;
                let phr = dot(uv, vec2<f32>(-0.5, 0.86)) * kr + 2.0 * noise3(vec3<f32>(uv * 300.0, 1.0));
                grad += vec2<f32>(-0.5, 0.86) * 0.00002 * kr * cos(phr) * smoothstep(0.7, 2.0, 0.0011 / max(fp, 1e-6) / 2.0);
                alb *= 0.93 + 0.12 * sin(ph + 0.8) * kf;
                tintG = mix(vec3<f32>(1.0), vec3<f32>(1.08, 0.92, 0.85), smoothstep(0.4, 0.7, n0));
                tintG *= mix(vec3<f32>(0.88, 0.8, 0.78), vec3<f32>(1.05, 1.0, 0.95), 0.5 + 0.5 * sin(ph + 0.8) * kf);
            } else if (world == 1) {
                // ice plates broken by reddish-brown cracks with pale ridges either side, frost
                // sparkling where the sun glances off it
                let ce = ecCellEdge(uv * 70.0, 6.0);
                let ce2 = ecCellEdge(uv * 22.0, 9.0);
                let w1 = max(0.05, fp * 70.0 * 1.2);
                let w2 = max(0.03, fp * 22.0 * 1.2);
                let line = exp(-sq(ce / w1)) * (0.05 / w1) + exp(-sq(ce2 / w2)) * (0.03 / w2) * 1.3;
                let flank = exp(-sq((ce2 - 2.2 * w2) / (1.2 * w2))) * (0.03 / w2);
                tintG = mix(vec3<f32>(1.0), vec3<f32>(0.62, 0.36, 0.3), saturate(line) * 0.8);
                // older plates are stained and dusty, younger ones bluer and cleaner
                tintG *= mix(vec3<f32>(1.02, 0.97, 0.9), vec3<f32>(0.92, 0.98, 1.06), smoothstep(0.35, 0.65, prov));
                alb = (0.8 + 0.25 * (n0 - 0.5) + 0.12 * saturate(flank)) * (1.0 + bright);
                spec = 1.0;
                sparkle = smoothstep(0.9, 0.97, noise3(vec3<f32>(uv * 2500.0, 2.0))) * (1.0 - smoothstep(0.3, 0.8, fp * 2500.0));
            } else if (world == 3) {
                // lava glowing through cracks in the cooled crust: faint in sunlight, plain at totality
                // the cracks wander, and only some stretches of them are still hot
                let wv = uv * 40.0 + 0.6 * vec2<f32>(fbm(vec3<f32>(uv * 20.0, 1.0)), fbm(vec3<f32>(uv * 20.0, 4.0)));
                let ce = ecCellEdge(wv, 12.0);
                let w = max(0.025, fp * 40.0 * 1.2);
                let crack = exp(-sq(ce / w)) * (0.025 / w) + 0.25 * exp(-sq(ce / (w * 2.5))) * (0.025 / w);
                let hot = smoothstep(0.45, 0.7, noise3(vec3<f32>(uv * 60.0, 8.0)));
                let flick = 0.7 + 0.3 * noise3(vec3<f32>(uv * 30.0, T * 0.3));
                glowG = vec3<f32>(1.0, 0.3, 0.05) * crack * hot * flick * 0.025 * adapt * (1.0 - smoothstep(0.0004, 0.0015, fp));
                alb *= 1.0 - 0.4 * saturate(crack);
                // ropy folds on the crust where it flowed and set, in lobes, with a glassy sheen
                let fd = normalize(vec2<f32>(0.3, 1.0) + 1.5 * noise2(vec3<f32>(uv * 15.0, 5.0)));
                let kw = 6.2831853 / 0.0008;
                let phw = dot(uv, fd) * kw + 3.0 * noise3(vec3<f32>(uv * 500.0, 6.0));
                let lobe = smoothstep(0.35, 0.65, noise3(vec3<f32>(uv * 30.0, 9.0)));
                grad += fd * 0.00003 * kw * sin(phw) * lobe * smoothstep(0.7, 2.0, 0.0008 / max(fp, 1e-6) / 2.0);
                spec = 0.3;
            }
            let ex = normalize(vec3<f32>(1.0, 0.0, 0.0) - Ns * Ns.x);
            let ez = normalize(vec3<f32>(0.0, 0.0, 1.0) - Ns * Ns.z);
            let N = normalize(Ns - grad.x * ex - grad.y * ez);
            let muV = saturate(dot(N, -rd));
            // regolith: between Lambert and the flat look of the Moon's own surface
            let nlS = dot(N, sunD);
            let nlP = dot(N, Lpl);
            let ls = saturate(nlS) * (0.55 + 0.9 / (saturate(nlS) + muV + 0.3));
            let lp = saturate(nlP) * (0.55 + 0.9 / (saturate(nlP) + muV + 0.3));
            let oG = o - vec2<f32>(dot(G, sx), dot(G, sy)) * S.i.z;
            let frac = max(ecUncovered(length(oG), Ro) + resid, 0.0) * bodyShare;
            // a soft sheen toward the sun, and on ice a few frost grains catching it
            let rs = saturate(dot(reflect(rd, N), sunD));
            let glint = spec * (0.3 * pow(rs, 12.0) + 2.5 * sparkle * pow(rs, 60.0));
            // light bounced off the sunlit plains around fills the shadows a little, less down in
            // the bowls; under ice it scatters blue
            let fill = 0.07 * (0.6 + 0.4 * Ns.y) * (1.0 - 0.35 * occ);
            let sub = select(vec3<f32>(0.0), vec3<f32>(0.45, 0.75, 1.1) * 0.06 * (1.0 - saturate(ls * sS)), world == 1);
            let light = sunTint * gain * frac * (ls * sS * 0.75 + fill + glint * sS + sub)
                      + plCol * plI * lp * sP
                      + coCol * coI * (0.4 + 0.6 * saturate(nlS + 0.3))
                      + skyAmb * (0.5 + 0.5 * N.y);
            var gc = gcol * tintG * alb * light + glowG;
            if (air) {
                let TG = exp(-dens * 0.3 * beta * t * 25.0);
                gc = gc * TG + skyIn * (1.0 - TG);
            }
            col = gc;
        } else if (ridge > 0.0) {
            // the far rims: their faces toward us in shadow, crests catching the light
            let G = vec3<f32>(sin(az), 0.0, cos(az)) * sqrt(2.0 * EC_HEIGHT) + vec3<f32>(0.0, -EC_HEIGHT, 0.0);
            let oG = o - vec2<f32>(dot(G, sx), dot(G, sy)) * S.i.z;
            let frac = max(ecUncovered(length(oG), Ro) + resid, 0.0) * bodyShare;
            let below = sky_top - el;
            let crest = exp(-below / (pixA * 3.0 + 0.001));
            let face = 0.12 + 0.2 * fbm(vec3<f32>(az * 40.0, below * 400.0, 3.0));
            let sideP = saturate(dot(normalize(vec3<f32>(rd.x, 0.0, rd.z)), -normalize(vec3<f32>(Lpl.x, 0.0, Lpl.z))) * -1.0 + 0.4);
            let light = sunTint * gain * frac * (face * 0.25 + crest * 0.9) * smoothstep(-0.1, 0.4, dot(normalize(vec3<f32>(rd.x, 0.0, rd.z)), normalize(vec3<f32>(sunD.x, 0.0, sunD.z))))
                      + plCol * plI * (0.15 + 0.35 * sideP) + coCol * coI * 0.5 + skyAmb * 0.5;
            var rc2 = gcol * 0.8 * light;
            if (air) {
                let TG = exp(-dens * 0.3 * beta * 3.5);
                rc2 = rc2 * TG + skyIn * (1.0 - TG);
            }
            col = mix(col, rc2, ridge);
        }
    }

    // glare: the uncovered sun, or at the end the diamond, scatters light in the eye and lens
    if (glareAmp > 0.0 && sd > 0.0) {
        let dg = d - S.j.xy;
        let g2 = dot(dg, dg);
        // with only a bead or two left the light is one point: a tight, hot core (the diamond)
        let size = 0.4 + 0.6 * smoothstep(-4.0, 0.0, logE);
        let diamond = 1.0 - smoothstep(-3.6, -2.4, logE);
        // power-law cores (same light as a Gaussian of twice the width parameter) fall off gradually; a
        // Gaussian's steep shoulder clips to a flat white blob with a hard rim at high brightness
        let gl = 0.8 * pow(1.0 + g2 / (0.025 * size), -1.5) + 0.1 / (1.0 + g2 / (0.3 * size)) + 0.004 / (1.0 + g2 / (5.0 * size));
        let dg2 = diamond * smoothstep(-5.6, -4.0, logE) * (4.0 * pow(1.0 + g2 / 0.015, -1.5) + 1.2 * pow(1.0 + g2 / 0.125, -1.5) + 0.25 / (1.0 + g2 / 1.2));
        col += sunCol * sunT * (gl * glareAmp + dg2);
    }
    return finalize(col, p);
}
