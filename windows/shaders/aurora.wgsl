// ---------- per-frame: aurora from orbit ---------- (ShaderAurora.swift)
// The night side of Earth from a few hundred kilometres up: the curved limb with its thin band of
// airglow, city lights and clouds sliding by below, storms flashing, and aurora curtains rising
// along the auroral oval. The scene has its own frame: Earth's center at the origin, radius 1,
// the camera straight above (0, 1, 0) looking toward +z (magnetic north), pitched down so the
// limb sits where the settings put it.
//
// S.a = camera pitch (rad, negative looks down), altitude (Earth radii), pole distance from
//       below the camera, oval radius (both radians of arc)
// S.b = green (oxygen, low) color, aurora brightness
// S.c = red (oxygen, high) color, activity (how fast it moves)
// S.d = fringe (nitrogen) color, substorm strength (0..1)
// S.e = city light color, city brightness
// S.f = clouds, moonlight, Earth's spin (rad/s), lightning (0..)
// S.g = sunrise glow, seed, real Earth maps bound (0/1), the view's longitude (rad)
// S.h = how far a substorm has pushed the folds ahead (seconds of their clock), unused x3
//
// The ground is the real Earth at night (NASA Black Marble, see Design/Earth), seen from above
// 43 N looking north: that latitude passes over the great cities of North America, Europe and
// East Asia. Earth turns eastward beneath the view while the auroral oval, held in place by the
// solar wind rather than by the ground, stays put.
//
// Textures: earthLights and earthGround are the Earth maps (city lights, ground); auLut is the
// per-frame table of the curtains' structure along the oval (8192x2, x = angle round the pole),
// filled by auroraLUT (aurora_lut.wgsl) earlier in the same command buffer.

const AU_BASE: f32 = 0.0155;   // the curtains' lower edge, ~100 km
const AU_TOP: f32 = 0.08;      // ~510 km: well above where the tallest rays fade out
const AU_AIRGLOW: f32 = 0.0148;
const AU_VIEW_LAT: f32 = 0.75049;   // 43 deg: the latitude below the camera
const AU_MAP_SOUTH: f32 = -1.5707963; // the maps reach the south pole (make_earth_maps.py)
const AU_TEXEL: f32 = 7.6699e-4;    // 2 pi / 8192: a city-light texel, radians of arc

// Aurora light emitted at point p (per unit length), as (rgb).
fn auEmission(p: vec3<f32>, pole: vec3<f32>, pe1: vec3<f32>, pe2: vec3<f32>, T: f32) -> vec3<f32> {
    // clamped, not wrapped: psi has a seam at +-pi where the noise does not repeat (linearClamp)
    let r = length(p);
    let a = r - 1.0;
    if (a < AU_BASE - 0.0015 || a > AU_TOP) { return vec3<f32>(0.0); }
    let u = p / r;
    let gam = acos(clamp(dot(u, pole), -1.0, 1.0));
    let act = S.c.w;
    let sub = S.d.w;
    // the oval spreads toward the equator in a substorm
    let rho = S.a.w + 0.012 + 0.012 * sub;
    // nowhere near the oval: no light (the march in auroraFragment skips this band with auCone)
    if (abs(gam - rho) > 0.12) { return vec3<f32>(0.0); }
    let psi = atan2(dot(u, pe2), dot(u, pe1));
    let lu = psi * (0.5 / PI) + 0.5;
    let la = textureSampleLevel(auLut, linearClamp, vec2<f32>(lu, 0.25), 0.0);   // row 0
    let edge = rho + la.x;
    let d = gam - edge;
    if (abs(d) > 0.08) { return vec3<f32>(0.0); }
    // a few thin sheets, one behind another, plus a faint diffuse glow poleward
    // Higher up the curtains spread and blur (the red oxygen light is slow to emit, so it drifts
    // and diffuses before it glows), so the sheets widen with height.
    let above = max(a - AU_BASE, 0.0);
    let spread = 1.0 + 70.0 * above;
    var sheets = 0.0;
    for (var k = 0; k < 3; k++) {
        let off = f32(k) * 0.011 + 0.004 * sin(psi * (3.0 + f32(k)) + f32(k) * 1.7 + T * 0.01 * act);
        let w = (0.0024 + 0.0012 * f32(k)) * spread;
        let dk = d - off;
        sheets += exp(-dk * dk / (w * w)) * (1.0 - 0.28 * f32(k)) / sqrt(spread);
    }
    // a faint diffuse green glow poleward of the curtains, fading out well before the cut-off
    let diffuse = 0.012 * smoothstep(0.0, 0.01, d) * exp(-max(d, 0.0) / 0.025) * smoothstep(0.075, 0.04, d);
    // rays: fine vertical striations that shimmer and drift along the curtain, read from the table
    let lb = textureSampleLevel(auLut, linearClamp, vec2<f32>(lu, 0.75), 0.0);   // row 1
    let r1 = la.y;
    let r2 = la.z;
    // the finest striations are sharpest at the bottom and wash out into the broad rays above
    let fineK = exp(-above / 0.012);
    let rays = 0.12 + 0.9 * lb.z * fineK + (0.9 * lb.w + 0.25 * (1.0 - fineK));
    // patches brighten and fade along the oval, and waves of brightness run along it (from the table)
    let patches = la.w;
    let boost = S.b.w * (1.0 + 1.3 * sub);
    let bright = boost * sheets * rays * patches;
    // the colors by height: a nitrogen fringe along the bottom edge, oxygen green above it,
    // and oxygen red up top, fading into space
    // the lower edge is crisp and brightest; the light thins out upward
    let green = smoothstep(AU_BASE - 0.0008, AU_BASE + 0.0008, a)
              * (0.3 + 0.9 * exp(-max(a - AU_BASE, 0.0) / 0.004)) * exp(-max(a - AU_BASE - 0.002, 0.0) / 0.014);
    // the red tops reach higher in some places than others (the height is in the table)
    let topH = lb.x;
    let red = smoothstep(topH - 0.012, topH, a) * exp(-max(a - topH, 0.0) / 0.012) * 0.24;
    let fringe = exp(-sq((a - AU_BASE + 0.0004) / 0.0011)) * (0.45 + 0.6 * sub);
    // Each ray reaches its own height and fades out softly above it, so the tops are ragged
    // and dissolve into space instead of ending on a line.
    // The broad rays set the heights, and the fade is long, so the tops dissolve as gradually
    // as the curtains' lower parts do.
    let reach = 0.036 + 0.008 * r1 + 0.03 * r2;
    let top = smoothstep(reach + 0.022, reach - 0.014, a);
    // some stretches lean teal, others yellow-green, drifting with the patches (the mix is in the table)
    let g = mix(S.b.rgb * vec3<f32>(0.35, 0.95, 1.25), S.b.rgb * vec3<f32>(1.25, 1.0, 0.55), lb.y);
    return (bright * (g * green + S.c.rgb * red) * top + bright * S.d.rgb * fringe) + boost * diffuse * patches * g * green;
}

// Where unit point P (scene frame) is on Earth: latitude, longitude, and the Earth-fixed unit
// vector the clouds and storms are pinned to.
fn auGeo(P: vec3<f32>, lat: ptr<function, f32>, lon: ptr<function, f32>) -> vec3<f32> {
    let phi = AU_VIEW_LAT;
    let north = vec3<f32>(0.0, sin(phi), cos(phi));      // Earth's spin axis
    let meridian = vec3<f32>(0.0, cos(phi), -sin(phi));  // the view's meridian at the equator
    *lat = asin(clamp(dot(P, north), -1.0, 1.0));
    *lon = S.g.w + atan2(P.x, dot(P, meridian));         // +x is east
    return vec3<f32>(cos(*lat) * cos(*lon), cos(*lat) * sin(*lon), sin(*lat));
}

// The real night side: Black Marble city lights (square-root encoded) over the dim ground they
// were laid on, which tells land from sea and shows snow, plus clouds and moonlight.
fn auEarth(lat: f32, lon: f32, g: vec3<f32>, fp: f32, T: f32, cloudOut: ptr<function, f32>) -> vec3<f32> {
    let uv = vec2<f32>(lon / (2.0 * PI) + 0.5, (0.5 * PI - lat) / (0.5 * PI - AU_MAP_SOUTH));
    // the footprint in texels, with the east-west squeeze toward the pole split between the axes
    let lod = log2(max(fp, 1e-6) / (AU_TEXEL * sqrt(max(cos(lat), 0.05))));
    var li = sq(textureSampleLevel(earthLights, mipRepeat, uv, max(lod, 0.0)).r);
    let gr = sq(textureSampleLevel(earthGround, mipRepeat, uv, max(lod - 2.0, 0.0)).r);
    // Where a pixel is finer than the map, a fine speckle breaks a town's soft texel up into
    // streets and blocks, keeping its average.
    let sharp = 1.0 - smoothstep(-1.5, 0.0, lod);
    let specks = smoothstep(0.42, 0.7, fbmLOD(g * 1400.0 + 13.0, fp * 1400.0));
    li *= mix(1.0, 0.35 + 2.2 * specks, sharp);
    let lights = li * S.e.w * 2.6;
    // dim suburbs glow sodium orange, bright centers burn whiter
    let lc = mix(S.e.rgb, vec3<f32>(0.85, 0.9, 1.0), smoothstep(0.15, 0.9, li) * 0.55);
    let cloud = smoothstep(0.46, 0.78, fbm(g * 4.0 + vec3<f32>(S.g.y + 7.0, 0.0, T * 0.0004))) * S.f.x;
    *cloudOut = cloud;
    let moon = S.f.y;
    var col = lc * lights * (1.0 - 0.85 * cloud);
    // moonlit ground: the sea near black, land a little brighter, snow and ice brightest
    col += (vec3<f32>(0.0015, 0.003, 0.008) + vec3<f32>(0.11, 0.1, 0.095) * max(gr - 0.027, 0.0)) * moon;
    col += vec3<f32>(0.02, 0.022, 0.03) * cloud * moon;
    return col;
}

// A made-up Earth for when the maps are missing, at Earth-fixed unit point g and pixel footprint
// fp (Earth radii): land and sea, city lights strung along coasts and rivers of population,
// clouds, and moonlight.
fn auGround(g: vec3<f32>, fp: f32, T: f32, cloudOut: ptr<function, f32>) -> vec3<f32> {
    let seed = S.g.y;
    let land = smoothstep(0.5, 0.54, fbm(g * 2.2 + seed) + 0.12 * (fbmLOD(g * 9.0 + 3.0, fp * 9.0) - 0.5));
    let pop = smoothstep(0.36, 0.7, fbm(g * 5.0 + seed + 11.0)) * land;
    let fine = fbmLOD(g * 160.0 + 7.0, fp * 160.0);
    // towns: clusters of bright specks (finer than the clusters themselves) with a dim glow between
    let specks = smoothstep(0.5, 0.66, fbmLOD(g * 700.0 + 13.0, fp * 700.0));
    let towns = smoothstep(0.5, 0.78, fine) * (0.5 + 5.0 * specks) + smoothstep(0.45, 0.6, fbmLOD(g * 35.0 + 2.0, fp * 35.0)) * 0.2;
    let lights = pop * towns * S.e.w * 0.6;
    let lc = mix(S.e.rgb, vec3<f32>(0.85, 0.9, 1.0), smoothstep(0.55, 0.8, noise3(g * 300.0 + 5.0)) * 0.6);
    let cloud = smoothstep(0.46, 0.78, fbm(g * 4.0 + vec3<f32>(seed + 7.0, 0.0, T * 0.0004))) * S.f.x;
    *cloudOut = cloud;
    let moon = S.f.y;
    var col = lc * lights * (1.0 - 0.85 * cloud);
    col += mix(vec3<f32>(0.002, 0.004, 0.01), vec3<f32>(0.007, 0.006, 0.005), land) * moon;
    col += vec3<f32>(0.02, 0.022, 0.03) * cloud * moon;
    return col;
}

// Lightning in storm clouds: storm cells sit on a grid in the drifting ground frame, and each
// flashes now and then, lighting a patch of cloud from inside.
fn auLightning(g: vec3<f32>, cloud: f32, T: f32, rate: f32, seed: f32) -> vec3<f32> {
    if (rate <= 0.0 || cloud < 0.2) { return vec3<f32>(0.0); }
    let cell = 0.06;
    let base = floor(g / cell);
    var col = vec3<f32>(0.0);
    for (var i = 0; i < 8; i++) {
        let c = base + vec3<f32>(f32(i & 1), f32((i >> 1u) & 1), f32((i >> 2u) & 1));
        let h = hash13(c + seed);
        if (h > 0.18) { continue; }
        let center = (c + vec3<f32>(hash13(c + 1.3), hash13(c + 2.7), hash13(c + 4.1))) * cell;
        let dist = length(g - center);
        if (dist > 0.03) { continue; }
        let slot = T * (2.2 + 2.0 * h) * rate + h * 40.0;
        let roll = hash13(vec3<f32>(c.xy, floor(slot)));
        let flash = select(0.0, exp(-fract(slot) * 7.0) * (0.6 + 0.8 * fract(roll * 13.0)), roll > 0.86);
        col += vec3<f32>(0.75, 0.82, 1.0) * flash * exp(-sq(dist / 0.012)) * (0.5 + cloud) * 2.2;
    }
    return col;
}

// Where a ray is inside the cone of half-angle acos(c) round `axis`, apex at Earth's center:
// (enter, exit), empty when enter >= exit. The oval's band lies between two such cones round
// the magnetic pole.
fn auCone(ro: vec3<f32>, rd: vec3<f32>, axis: vec3<f32>, c: f32) -> vec2<f32> {
    let ra = dot(ro, axis);
    let da = dot(rd, axis);
    let c2 = sq(c);
    let A = sq(da) - c2;
    let B = ra * da - c2 * dot(ro, rd);
    let C = sq(ra) - c2 * dot(ro, ro);
    let disc = sq(B) - A * C;
    if (disc <= 0.0) { return vec2<f32>(1.0, 0.0); }
    // the stable form of the quadratic's roots: one stays finite as the ray turns parallel to the cone
    let q = -(B + select(1.0, -1.0, B < 0.0) * sqrt(disc));
    let x1 = clamp(q / A, -1e9, 1e9);
    let x2 = C / q;
    let lo = min(x1, x2);
    let hi = max(x1, x2);
    // a ray heading outside the cone's directions is inside it between the roots (if they are on
    // the pole's side); one heading within them enters and never leaves
    if (A < 0.0) { return select(vec2<f32>(1.0, 0.0), vec2<f32>(lo, hi), ra + da * x2 > 0.0); }
    return select(vec2<f32>(-1e9, lo), vec2<f32>(hi, 1e9), da > 0.0);
}

@fragment
fn auroraFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let rdw = octDecode(readTex(dirTex, p).xy);
    let T = F.time;
    let right = F.camRight.xyz;
    let up = F.camUp.xyz;
    let fwd = cross(right, up);
    let l = vec3<f32>(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    let pitch = S.a.x;
    let rd = normalize(vec3<f32>(l.x, l.y * cos(pitch) + l.z * sin(pitch), -l.y * sin(pitch) + l.z * cos(pitch)));
    let h = S.a.y;
    let ro = vec3<f32>(0.0, 1.0 + h, 0.0);
    let pixAng = F.pixelAngle;

    let ground = sphereSpan(ro, rd, 1.0);
    let hitGround = ground.x < ground.y && ground.x > 0.0;
    let tEnd = select(1e9, ground.x, hitGround);
    let b = length(ro - rd * dot(ro, rd));           // how close the ray passes to Earth's center

    var col = vec3<f32>(0.0);
    if (hitGround) {
        let P = ro + rd * ground.x;
        let fp = pixAng * ground.x / max(dot(P, -rd), 0.06);
        var lat = 0.0;
        var lon = 0.0;
        var cloud = 0.0;
        let g = auGeo(P, &lat, &lon);
        if (S.g.z > 0.5) {
            col = auEarth(lat, lon, g, fp, T, &cloud);
        } else {
            col = auGround(g, fp, T, &cloud);
        }
        col += auLightning(g, cloud, T, S.f.w, S.g.y);
        // the aurora overhead lights the ground and clouds below it a little
        let pole = vec3<f32>(0.0, cos(S.a.z), sin(S.a.z));
        let gam = acos(clamp(dot(P, pole), -1.0, 1.0));
        col += S.b.rgb * S.b.w * (1.0 + 2.0 * S.d.w) * exp(-sq((gam - S.a.w) / 0.03)) * (0.006 + 0.03 * cloud);
        // seen through more air toward the limb, the ground fades into a blue haze
        let slant = 1.0 / max(dot(normalize(P), -rd), 0.05);
        col = col * exp(-0.035 * slant) + vec3<f32>(0.001, 0.003, 0.009) * (1.0 - exp(-0.03 * slant)) * (0.3 + S.f.y);
    } else {
        // stars, dimmed where they shine through the air at the limb
        col = SKY(p, rdw, false) * smoothstep(1.0, 1.03, b);
    }

    // airglow: a thin shell of faint green light about 95 km up; edge-on at the limb it piles
    // up into a bright line
    {
        let so = sphereSpan(ro, rd, 1.0 + AU_AIRGLOW + 0.0012);
        let si = sphereSpan(ro, rd, 1.0 + AU_AIRGLOW - 0.0012);
        var len = max(min(so.y, tEnd) - max(so.x, 0.0), 0.0);
        if (si.x < si.y) { len -= max(min(si.y, tEnd) - max(si.x, 0.0), 0.0); }
        // seen face-on over the disk it's only a faint tint; edge-on above the limb, a bright line
        col += vec3<f32>(0.35, 1.0, 0.45) * max(len, 0.0) * select(0.9, 0.12, hitGround) * (0.8 + 0.4 * noise3(rd * 40.0 + vec3<f32>(T * 0.01, 0.0, 0.0)));
    }
    // the atmosphere's own glow above the limb, and sunrise warming one end of it
    let rim = exp(-max(b - 1.0, 0.0) / 0.0025) * select(0.0, 1.0, b > 1.0 || !hitGround);
    let dawn = S.g.x * smoothstep(0.1, 0.85, rd.x / max(length(rd.xz), 1e-3));
    col += (vec3<f32>(0.03, 0.06, 0.16) * 0.35 + mix(vec3<f32>(0.25, 0.4, 0.9), vec3<f32>(1.0, 0.45, 0.15), exp(-max(b - 1.0, 0.0) / 0.004)) * dawn * 0.7) * rim;

    // The aurora: march the ray where it's inside the aurora's shell and in front of the ground.
    // The thin curtains live in the lower part, so that stretch gets dense steps; the soft tops
    // above it only need a few.
    let topS = sphereSpan(ro, rd, 1.0 + AU_TOP);
    let t0 = max(topS.x, 0.0);
    let t1 = min(topS.y, tEnd);
    if (t1 > t0 && S.b.w > 0.0) {
        let split = 0.05;
        let N = 44;
        let M = 14;
        let pole = vec3<f32>(0.0, cos(S.a.z), sin(S.a.z));
        let pe1 = vec3<f32>(1.0, 0.0, 0.0);
        let pe2 = cross(pole, pe1);
        let jit = hash13(vec3<f32>(vec2<f32>(p), 1.0));
        // Light only comes from within 0.12 rad of the oval (auEmission's own test), a band between
        // two cones round the pole, and from above the curtains' lower edge. Steps outside that
        // would add nothing, so only the steps inside it are run, at the places they always were.
        let rho = S.a.w + 0.012 + 0.012 * S.d.w;
        let oc = auCone(ro, rd, pole, cos(rho + 0.12));
        let ic = auCone(ro, rd, pole, cos(max(rho - 0.12, 0.0)));
        var band = array<vec2<f32>, 2>(oc, vec2<f32>(1.0, 0.0));
        if (ic.x < ic.y) {
            band[0] = vec2<f32>(band[0].x, min(oc.y, ic.x));
            band[1] = vec2<f32>(max(oc.x, ic.y), oc.y);
        }
        let low = sphereSpan(ro, rd, 1.0 + split);
        let l0 = max(low.x, 0.0);
        let l1 = min(low.y, tEnd);
        let hasLow = l1 > l0;
        let base = sphereSpan(ro, rd, 1.0 + AU_BASE - 0.0015);
        let hasBase = base.x < base.y;
        let dtL = (l1 - l0) / f32(N);
        let dtH = (t1 - t0) / f32(M);
        // stretches of the ray to sample: (from, to, 1 = dense steps below the split)
        var piece = array<vec3<f32>, 4>(
            vec3<f32>(t0, select(t1, l0, hasLow), 0.0), vec3<f32>(select(t1, l1, hasLow), t1, 0.0),
            vec3<f32>(l0, select(l1, min(base.x, l1), hasBase), 1.0), vec3<f32>(select(l1, max(base.y, l0), hasBase), l1, 1.0));
        var acc = vec3<f32>(0.0);
        for (var k = 0; k < 4; k++) {
            let dense = piece[k].z > 0.5;
            if (dense && !hasLow) { continue; }
            let org = select(t0, l0, dense);
            let dt = select(dtH, dtL, dense);
            let n = select(M, N, dense);
            for (var j = 0; j < 2; j++) {
                // a little slack, so rounding never drops a step; auEmission's own tests still decide
                let s = max(piece[k].x, band[j].x) - 1e-4;
                let e = min(piece[k].y, band[j].y) + 1e-4;
                if (e <= s) { continue; }
                let i0 = max(i32(ceil((s - org) / dt - jit)), 0);
                let i1 = min(i32(ceil((e - org) / dt - jit)), n);
                for (var i = i0; i < i1; i++) {
                    let x = ro + rd * (org + (f32(i) + jit) * dt);
                    if (!dense && length(x) < 1.0 + split) { continue; }      // covered by the dense steps
                    acc += auEmission(x, pole, pe1, pe2, T) * dt;
                }
            }
        }
        col += acc * 14.0;
    }
    // The scene's own look, on top of the global image settings: about a third more light and
    // a contrast curve (1.3 around mid gray), so the curtains stand out against the night side.
    {
        var x = max(col, vec3<f32>(0.0)) * 1.3 * F.exposure;
        x = 0.18 * pow(x / 0.18, vec3<f32>(1.3));
        col = x / max(F.exposure, 1e-3);
    }
    return finalize(col, p);
}
