// ---------- per-frame: planets (lensed scenes and star systems) ---------- (ShaderPlanets.swift)
// The Metal versions take `constant Light* lights` / `constant Planet* planets`; here they read the
// frame globals `lights` and `planets` and keep only the counts.

// What a planet is made of, unpacked from Planet.misc.w = kind * 8 + ring outer radius (in
// planet radii, 0 = no rings); see planets.rs. Kinds: 0 gas giant, 1 ice giant,
// 2 rocky with oceans and clouds, 3 lava world. The spin axis leans by an angle taken from the
// seed, mostly toward or away from the camera so rings open up rather than lie edge-on.
struct PlanetLook {
    kind: i32,
    ringOut: f32,        // outer ring radius, scene units (0 = none)
    ringIn: f32,
    axis: vec3<f32>,
    e1: vec3<f32>,       // equatorial basis
    e2: vec3<f32>,
}

fn planetLook(pl: Planet) -> PlanetLook {
    var k: PlanetLook;
    let code = pl.misc.w;
    k.kind = i32(floor(code / 8.0 + 0.01));
    let rs = code - f32(k.kind) * 8.0;
    let rp = pl.colorA.w;
    // rings stay inside the bake shell's margin around the orbit (SceneGeometry.maxPlanetRadius)
    k.ringOut = select(0.0, min(rs * rp, 0.62), rs > 0.5);
    k.ringIn = rp * 1.2;
    if (k.ringOut < rp * 1.45) { k.ringOut = 0.0; }
    let seed = pl.colorB.w;
    let h1 = fract(seed * 0.7131);
    let h2 = fract(seed * 0.3917);
    let tilt = select(0.45 * h1, 0.38 + 0.25 * h1, k.ringOut > 0.0) * select(1.0, -1.0, h2 < 0.5);
    let az = (h2 - 0.5) * 1.2;
    k.axis = normalize(vec3<f32>(sin(tilt) * sin(az), cos(tilt), -sin(tilt) * cos(az)));
    k.e1 = normalize(cross(k.axis, vec3<f32>(0.0, 0.0, 1.0)));
    k.e2 = cross(k.axis, k.e1);
    return k;
}

// How much of the ring there is at radius `d` (scene units) from the planet's center: a few
// ringlets with a dark division two thirds of the way out, thinning at both edges.
fn ringDensity(d: f32, k: PlanetLook, seed: f32) -> f32 {
    let x = (d - k.ringIn) / (k.ringOut - k.ringIn);
    if (x <= 0.0 || x >= 1.0) { return 0.0; }
    let lets = 0.55 + 0.25 * sin(x * 47.0 + seed) * sin(x * 19.0 + seed * 2.0) + 0.2 * sin(x * 113.0);
    let division = smoothstep(0.02, 0.05, abs(x - 0.64));
    let edges = smoothstep(0.0, 0.06, x) * (1.0 - smoothstep(0.88, 1.0, x));
    let inner = mix(0.45, 1.0, smoothstep(0.0, 0.3, x));        // a faint inner (crepe) ring
    return saturate(lets * division * edges * inner);
}

// Fraction of light from L that reaches P past the planet (centre C, radius rp).
fn planetShadow(P: vec3<f32>, L: vec3<f32>, C: vec3<f32>, rp: f32) -> f32 {
    let oc = P - C;
    let b = dot(oc, L);
    let c = dot(oc, oc) - rp * rp;
    return select(1.0, 0.0, b < 0.0 && b * b - c > 0.0);
}

// Planet surface at normal N, seen along v, lit by every light. With `ringShadows` the rings
// (where the scene draws them) shade the surface.
fn shadePlanetSurfaceEx(pl: Planet, N: vec3<f32>, v: vec3<f32>, P: vec3<f32>,
                        lightCount: i32, ringShadows: bool) -> vec3<f32> {
    let k = planetLook(pl);
    let sa = pl.misc.x;
    let cs = cos(sa);
    let sn = sin(sa);
    let l = vec3<f32>(dot(N, k.e1), dot(N, k.axis), dot(N, k.e2));        // planet frame, y = spin axis
    let q = vec3<f32>(cs * l.x - sn * l.z, l.y, sn * l.x + cs * l.z);
    let seed = pl.colorB.w;
    let lat = q.y;
    let A = pl.colorA.rgb;
    let B = pl.colorB.rgb;
    var surf: vec3<f32>;
    var glow = vec3<f32>(0.0);          // light of its own (lava)
    var ocean = 0.0;
    var cloud = 0.0;
    var atmoCol = mix(A, vec3<f32>(0.6, 0.8, 1.0), 0.5);

    if (k.kind == 0) {
        // gas giant: zonal bands, wavy where neighbouring jets shear, fine streaks, and a storm
        let warp = fbm(vec3<f32>(q.x * 2.0, q.y * 6.0, q.z * 2.0) + seed);
        let lt = lat + (warp - 0.5) * 0.12;
        let band = 0.5 + 0.5 * sin(lt * pl.misc.y * 2.2 + seed);
        let streaks = fbm(vec3<f32>(q.x * 3.0, lt * pl.misc.y * 3.0, q.z * 3.0) + seed * 1.7);
        let t = smoothstep(0.2, 0.8, band + (streaks - 0.5) * 0.5);
        surf = mix(B, A, t);
        surf = mix(surf, mix(A, vec3<f32>(1.0, 0.95, 0.85), 0.5), smoothstep(0.75, 0.95, band) * 0.35);   // pale zones
        var lon = atan2(q.z, q.x) - seed;
        lon -= 6.2831853 * floor(lon / 6.2831853 + 0.5);
        let sd = vec2<f32>(lon * sqrt(max(1.0 - lat * lat, 0.0)) / 0.3, (lat + 0.32) / 0.11);
        let spot = exp(-dot(sd, sd));
        surf = mix(surf, mix(A, vec3<f32>(1.0, 0.55, 0.35), 0.5) * 1.15, spot * 0.8);
        atmoCol = mix(A, vec3<f32>(1.0), 0.4);
    } else if (k.kind == 1) {
        // ice giant: smooth haze, faint bands, a bright polar hood
        let band = 0.5 + 0.5 * sin(lat * pl.misc.y * 2.5 + seed);
        let haze = fbm(vec3<f32>(q.x * 2.0, q.y * 5.0, q.z * 2.0) + seed);
        surf = mix(A, B, 0.25 + 0.15 * band + 0.15 * (haze - 0.5));
        surf = mix(surf, mix(A, vec3<f32>(1.0), 0.5), smoothstep(0.65, 0.9, abs(lat)) * 0.5);
        atmoCol = mix(A, vec3<f32>(0.7, 0.9, 1.0), 0.4);
    } else if (k.kind == 2) {
        // rocky: continents and seas, polar ice, and weather systems in the clouds
        let land = smoothstep(0.5, 0.56, fbm(q * 2.3 + seed) + 0.04 * noise3(q * 12.0 + seed));
        let relief = fbm(q * 7.0 + seed * 3.0);
        let landCol = mix(A, A * 0.55 + vec3<f32>(0.12, 0.09, 0.05), relief);
        let seaCol = mix(B, B * 1.6 + vec3<f32>(0.0, 0.05, 0.08), smoothstep(0.42, 0.5, fbm(q * 2.3 + seed)));
        surf = mix(seaCol, landCol, land);
        ocean = 1.0 - land;
        let ice = smoothstep(0.78, 0.86, abs(lat) + 0.06 * (relief - 0.5));
        surf = mix(surf, vec3<f32>(0.9, 0.95, 1.0), ice);
        let cq = vec3<f32>(q.x * 2.6, q.y * 5.0, q.z * 2.6) + seed * 1.3;
        let swirl = fbm(cq + 1.5 * (fbm(cq * 0.5 + 7.0) - 0.5));
        cloud = smoothstep(0.52, 0.72, swirl) * pl.misc.z;
        surf = mix(surf, vec3<f32>(0.95), cloud * 0.85);
        atmoCol = vec3<f32>(0.35, 0.6, 1.0);
    } else {
        // lava world: dark crust split by glowing cracks, hottest where the crust is thinnest
        let n = fbm(q * 3.5 + seed);
        let crack = 1.0 - smoothstep(0.0, 0.05, abs(n - 0.5));
        let pool = smoothstep(0.68, 0.8, fbm(q * 1.8 + seed * 2.0));
        surf = mix(B, B * 1.8, fbm(q * 9.0 + seed));
        glow = A * (crack * 0.9 + pool * 0.6) * (0.85 + 0.3 * noise3(q * 20.0 + seed));
        atmoCol = mix(A, vec3<f32>(1.0, 0.6, 0.3), 0.5);
    }

    let mu = saturate(dot(N, -v));
    var lit = vec3<f32>(0.0);
    var spec = vec3<f32>(0.0);
    var dusk = vec3<f32>(0.0);
    var day = 0.0;
    for (var i = 0; i < lightCount; i++) {
        let L = normalize(lights[i].pos.xyz - P);
        let nl = dot(N, L);
        var shade = 1.0;
        if (ringShadows && k.ringOut > 0.0) {
            let la = dot(L, k.axis);
            if (abs(la) > 1e-3) {
                let tl = dot(pl.center.xyz - P, k.axis) / la;
                if (tl > 0.0) { shade = 1.0 - 0.8 * ringDensity(length(P + L * tl - pl.center.xyz), k, seed); }
            }
        }
        let Lc = lights[i].color.rgb * lights[i].pos.w * shade;
        // a little wrap-around: the terminator is soft where there's air to scatter light
        let wrap = select(0.12 * pl.misc.z, 0.0, k.kind == 3);
        lit += Lc * saturate((nl + wrap) / (1.0 + wrap));
        day = max(day, saturate(nl * 0.5 + 0.5));
        dusk += Lc * exp(-sq(nl / 0.18));
        if (ocean > 0.0) {
            let hlf = normalize(L - v);
            spec += Lc * pow(saturate(dot(N, hlf)), 60.0) * ocean * (1.0 - cloud) * 0.8;
        }
    }
    // gas and ice giants darken toward the limb; rocky worlds less so
    let limb = select(0.8 + 0.2 * mu, 0.55 + 0.45 * sqrt(mu), k.kind <= 1);
    var col = surf * (lit * 1.25 * limb + 0.02) + spec + glow;
    col += surf * vec3<f32>(0.08, 0.14, 0.35) * sq(1.0 - day) * 0.25;
    // atmosphere: a rim lit on the day side, reddened along the terminator
    let rim = pow(1.0 - mu, 3.0);
    let sunlit = lit + 0.15 * dusk;
    col += atmoCol * rim * pl.misc.z * (0.15 + sunlit * 0.9);
    col += vec3<f32>(1.0, 0.45, 0.2) * dusk * pl.misc.z * 0.08 * (1.0 - mu * 0.5);
    return col;
}

// Planet surface without ring shadows (the star systems call this).
fn shadePlanetSurface(pl: Planet, N: vec3<f32>, v: vec3<f32>, P: vec3<f32>, lightCount: i32) -> vec3<f32> {
    return shadePlanetSurfaceEx(pl, N, v, P, lightCount, false);
}

// The lit side of a ring at point Q (on the ring plane), seen from either face.
fn shadeRing(pl: Planet, k: PlanetLook, Q: vec3<f32>, density: f32, lightCount: i32) -> vec3<f32> {
    let C = pl.center.xyz;
    let rp = pl.colorA.w;
    let base = mix(pl.colorA.rgb, vec3<f32>(0.92, 0.86, 0.74), 0.55) * (0.75 + 0.35 * density);
    var lit = vec3<f32>(0.0);
    for (var i = 0; i < lightCount; i++) {
        let L = normalize(lights[i].pos.xyz - Q);
        lit += lights[i].color.rgb * lights[i].pos.w * (0.25 + 0.75 * abs(dot(L, k.axis))) * planetShadow(Q, L, C, rp);
    }
    return base * (lit * 1.1 + 0.015) * (0.35 + 0.65 * density);
}

// Whether any planet on this shell could be hit by a ray crossing it at X, whatever its
// direction: the planet (and its rings) lies inside the shell (radius R), and a straight ray
// stays within depth d of the shell for at most sqrt(2 R d) either side of X, so a hit needs
// |X - C| < re + sqrt(2 R d) with d = R - (|C| - re), re = the planet's or its rings' radius.
// Lets most crossings skip the direction read and the intersection tests.
fn planetsNearShellPoint(X: vec3<f32>, R: f32, shell: i32, count: i32) -> bool {
    for (var i = 0; i < count; i++) {
        let pl = planets[i];
        if (i32(pl.center.w) != shell) { continue; }
        let C = pl.center.xyz;
        let re = max(pl.colorA.w, planetLook(pl).ringOut);
        let d = max(R - length(C) + re, 0.0);
        let reach = re + sqrt(2.0 * R * d) + 0.05;
        let dx = X - C;
        if (dot(dx, dx) < reach * reach) { return true; }
    }
    return false;
}

// A ray crossing a planet's orbit shell at X heading v; treat it as straight near the planet
// and intersect each planet's sphere and ring plane. Only the half-chord on this side of the
// shell counts. Rings are opaque where they are dense enough and shaded dimmer where thin.
fn shadePlanetsOnShell(X: vec3<f32>, v: vec3<f32>, shell: i32, count: i32, lightCount: i32) -> vec4<f32> {
    var best = 1e9;
    var res = vec4<f32>(0.0);
    let halfChord = abs(dot(X, v));
    let inbound = dot(X, v) < 0.0;
    for (var i = 0; i < count; i++) {
        let pl = planets[i];
        if (i32(pl.center.w) != shell) { continue; }
        let C = pl.center.xyz;
        let rp = pl.colorA.w;
        let oc = X - C;
        let k = planetLook(pl);
        if (k.ringOut > 0.0) {
            let va = dot(v, k.axis);
            if (abs(va) > 1e-4) {
                let t = dot(C - X, k.axis) / va;
                var valid: bool;
                if (inbound) { valid = t >= -k.ringOut && t <= halfChord + k.ringOut; }
                else { valid = t <= k.ringOut && t >= -halfChord - k.ringOut; }
                let key = select(-t, t, inbound);
                if (valid && key < best) {
                    let Q = X + v * t;
                    let dens = ringDensity(length(Q - C), k, pl.colorB.w);
                    if (dens > 0.3) {
                        best = key;
                        res = vec4<f32>(shadeRing(pl, k, Q, dens, lightCount), 1.0);
                    }
                }
            }
        }
        let b = dot(oc, v);
        let c = dot(oc, oc) - rp * rp;
        let disc = b * b - c;
        if (disc <= 0.0) { continue; }
        let t = -b - sqrt(disc);
        var skip: bool;
        if (inbound) { skip = t < -rp || t > halfChord + rp; } else { skip = t > rp || t < -halfChord - rp; }
        if (skip) { continue; }
        let key = select(-t, t, inbound);
        if (key >= best) { continue; }
        best = key;
        let P = X + v * t;
        res = vec4<f32>(shadePlanetSurfaceEx(pl, normalize(P - C), v, P, lightCount, true), 1.0);
    }
    return res;
}
