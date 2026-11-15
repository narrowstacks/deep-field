extension ShaderSource {
    static let planets = """
// ---------- per-frame: planets (lensed scenes and star systems) ----------

// What a planet is made of, unpacked from Planet.misc.w = kind * 8 + ring outer radius (in
// planet radii, 0 = no rings); see PlanetSpec.gpu. Kinds: 0 gas giant, 1 ice giant,
// 2 rocky with oceans and clouds, 3 lava world. The spin axis leans by an angle taken from the
// seed, mostly toward or away from the camera so rings open up rather than lie edge-on.
struct PlanetLook {
    int kind;
    float ringOut;        // outer ring radius, scene units (0 = none)
    float ringIn;
    float3 axis;
    float3 e1, e2;        // equatorial basis
};

static PlanetLook planetLook(Planet pl) {
    PlanetLook k;
    float code = pl.misc.w;
    k.kind = int(floor(code / 8.0 + 0.01));
    float rs = code - float(k.kind) * 8.0;
    float rp = pl.colorA.w;
    // rings stay inside the bake shell's margin around the orbit (SceneGeometry.maxPlanetRadius)
    k.ringOut = rs > 0.5 ? min(rs * rp, 0.62) : 0.0;
    k.ringIn = rp * 1.2;
    if (k.ringOut < rp * 1.45) k.ringOut = 0.0;
    float seed = pl.colorB.w;
    float h1 = fract(seed * 0.7131), h2 = fract(seed * 0.3917);
    float tilt = (k.ringOut > 0.0 ? 0.38 + 0.25 * h1 : 0.45 * h1) * (h2 < 0.5 ? -1.0 : 1.0);
    float az = (h2 - 0.5) * 1.2;
    k.axis = normalize(float3(sin(tilt) * sin(az), cos(tilt), -sin(tilt) * cos(az)));
    k.e1 = normalize(cross(k.axis, float3(0.0, 0.0, 1.0)));
    k.e2 = cross(k.axis, k.e1);
    return k;
}

// How much of the ring there is at radius `d` (scene units) from the planet's center: a few
// ringlets with a dark division two thirds of the way out, thinning at both edges.
static float ringDensity(float d, PlanetLook k, float seed) {
    float x = (d - k.ringIn) / (k.ringOut - k.ringIn);
    if (x <= 0.0 || x >= 1.0) return 0.0;
    float lets = 0.55 + 0.25 * sin(x * 47.0 + seed) * sin(x * 19.0 + seed * 2.0) + 0.2 * sin(x * 113.0);
    float division = smoothstep(0.02, 0.05, abs(x - 0.64));
    float edges = smoothstep(0.0, 0.06, x) * (1.0 - smoothstep(0.88, 1.0, x));
    float inner = mix(0.45, 1.0, smoothstep(0.0, 0.3, x));        // a faint inner (crepe) ring
    return saturate(lets * division * edges * inner);
}

// Fraction of light from L that reaches P past the planet (centre C, radius rp).
static float planetShadow(float3 P, float3 L, float3 C, float rp) {
    float3 oc = P - C;
    float b = dot(oc, L);
    float c = dot(oc, oc) - rp * rp;
    return (b < 0.0 && b * b - c > 0.0) ? 0.0 : 1.0;
}

// Planet surface at normal N, seen along v, lit by every light. With `ringShadows` the rings
// (where the scene draws them) shade the surface.
static float3 shadePlanetSurfaceEx(Planet pl, float3 N, float3 v, float3 P,
                                   constant Light* lights, int lightCount, bool ringShadows) {
    PlanetLook k = planetLook(pl);
    float sa = pl.misc.x, cs = cos(sa), sn = sin(sa);
    float3 l = float3(dot(N, k.e1), dot(N, k.axis), dot(N, k.e2));        // planet frame, y = spin axis
    float3 q = float3(cs * l.x - sn * l.z, l.y, sn * l.x + cs * l.z);
    float seed = pl.colorB.w;
    float lat = q.y;
    float3 A = pl.colorA.rgb, B = pl.colorB.rgb;
    float3 surf;
    float3 glow = float3(0.0);          // light of its own (lava)
    float ocean = 0.0, cloud = 0.0;
    float3 atmoCol = mix(A, float3(0.6, 0.8, 1.0), 0.5);

    if (k.kind == 0) {
        // gas giant: zonal bands, wavy where neighbouring jets shear, fine streaks, and a storm
        float warp = fbm(float3(q.x * 2.0, q.y * 6.0, q.z * 2.0) + seed);
        float lt = lat + (warp - 0.5) * 0.12;
        float band = 0.5 + 0.5 * sin(lt * pl.misc.y * 2.2 + seed);
        float streaks = fbm(float3(q.x * 3.0, lt * pl.misc.y * 3.0, q.z * 3.0) + seed * 1.7);
        float t = smoothstep(0.2, 0.8, band + (streaks - 0.5) * 0.5);
        surf = mix(B, A, t);
        surf = mix(surf, mix(A, float3(1.0, 0.95, 0.85), 0.5), smoothstep(0.75, 0.95, band) * 0.35);   // pale zones
        float lon = atan2(q.z, q.x) - seed;
        lon -= 6.2831853 * floor(lon / 6.2831853 + 0.5);
        float2 sd = float2(lon * sqrt(max(1.0 - lat * lat, 0.0)) / 0.3, (lat + 0.32) / 0.11);
        float spot = exp(-dot(sd, sd));
        surf = mix(surf, mix(A, float3(1.0, 0.55, 0.35), 0.5) * 1.15, spot * 0.8);
        atmoCol = mix(A, float3(1.0), 0.4);
    } else if (k.kind == 1) {
        // ice giant: smooth haze, faint bands, a bright polar hood
        float band = 0.5 + 0.5 * sin(lat * pl.misc.y * 2.5 + seed);
        float haze = fbm(float3(q.x * 2.0, q.y * 5.0, q.z * 2.0) + seed);
        surf = mix(A, B, 0.25 + 0.15 * band + 0.15 * (haze - 0.5));
        surf = mix(surf, mix(A, float3(1.0), 0.5), smoothstep(0.65, 0.9, abs(lat)) * 0.5);
        atmoCol = mix(A, float3(0.7, 0.9, 1.0), 0.4);
    } else if (k.kind == 2) {
        // rocky: continents and seas, polar ice, and weather systems in the clouds
        float land = smoothstep(0.5, 0.56, fbm(q * 2.3 + seed) + 0.04 * noise3(q * 12.0 + seed));
        float relief = fbm(q * 7.0 + seed * 3.0);
        float3 landCol = mix(A, A * 0.55 + float3(0.12, 0.09, 0.05), relief);
        float3 seaCol = mix(B, B * 1.6 + float3(0.0, 0.05, 0.08), smoothstep(0.42, 0.5, fbm(q * 2.3 + seed)));
        surf = mix(seaCol, landCol, land);
        ocean = 1.0 - land;
        float ice = smoothstep(0.78, 0.86, abs(lat) + 0.06 * (relief - 0.5));
        surf = mix(surf, float3(0.9, 0.95, 1.0), ice);
        float3 cq = float3(q.x * 2.6, q.y * 5.0, q.z * 2.6) + seed * 1.3;
        float swirl = fbm(cq + 1.5 * (fbm(cq * 0.5 + 7.0) - 0.5));
        cloud = smoothstep(0.52, 0.72, swirl) * pl.misc.z;
        surf = mix(surf, float3(0.95), cloud * 0.85);
        atmoCol = float3(0.35, 0.6, 1.0);
    } else {
        // lava world: dark crust split by glowing cracks, hottest where the crust is thinnest
        float n = fbm(q * 3.5 + seed);
        float crack = 1.0 - smoothstep(0.0, 0.05, abs(n - 0.5));
        float pool = smoothstep(0.68, 0.8, fbm(q * 1.8 + seed * 2.0));
        surf = mix(B, B * 1.8, fbm(q * 9.0 + seed));
        glow = A * (crack * 0.9 + pool * 0.6) * (0.85 + 0.3 * noise3(q * 20.0 + seed));
        atmoCol = mix(A, float3(1.0, 0.6, 0.3), 0.5);
    }

    float mu = saturate(dot(N, -v));
    float3 lit = float3(0.0);
    float3 spec = float3(0.0);
    float3 dusk = float3(0.0);
    float day = 0.0;
    for (int i = 0; i < lightCount; i++) {
        float3 L = normalize(lights[i].pos.xyz - P);
        float nl = dot(N, L);
        float shade = 1.0;
        if (ringShadows && k.ringOut > 0.0) {
            float la = dot(L, k.axis);
            if (abs(la) > 1e-3) {
                float tl = dot(pl.center.xyz - P, k.axis) / la;
                if (tl > 0.0) shade = 1.0 - 0.8 * ringDensity(length(P + L * tl - pl.center.xyz), k, seed);
            }
        }
        float3 Lc = lights[i].color.rgb * lights[i].pos.w * shade;
        // a little wrap-around: the terminator is soft where there's air to scatter light
        float wrap = k.kind == 3 ? 0.0 : 0.12 * pl.misc.z;
        lit += Lc * saturate((nl + wrap) / (1.0 + wrap));
        day = max(day, saturate(nl * 0.5 + 0.5));
        dusk += Lc * exp(-pow(nl / 0.18, 2.0));
        if (ocean > 0.0) {
            float3 hlf = normalize(L - v);
            spec += Lc * pow(saturate(dot(N, hlf)), 60.0) * ocean * (1.0 - cloud) * 0.8;
        }
    }
    // gas and ice giants darken toward the limb; rocky worlds less so
    float limb = k.kind <= 1 ? 0.55 + 0.45 * sqrt(mu) : 0.8 + 0.2 * mu;
    float3 col = surf * (lit * 1.25 * limb + 0.02) + spec + glow;
    col += surf * float3(0.08, 0.14, 0.35) * pow(1.0 - day, 2.0) * 0.25;
    // atmosphere: a rim lit on the day side, reddened along the terminator
    float rim = pow(1.0 - mu, 3.0);
    float3 sunlit = lit + 0.15 * dusk;
    col += atmoCol * rim * pl.misc.z * (0.15 + sunlit * 0.9);
    col += float3(1.0, 0.45, 0.2) * dusk * pl.misc.z * 0.08 * (1.0 - mu * 0.5);
    return col;
}

// Planet surface without ring shadows (the star systems call this).
static float3 shadePlanetSurface(Planet pl, float3 N, float3 v, float3 P,
                                 constant Light* lights, int lightCount) {
    return shadePlanetSurfaceEx(pl, N, v, P, lights, lightCount, false);
}

// The lit side of a ring at point Q (on the ring plane), seen from either face.
static float3 shadeRing(Planet pl, PlanetLook k, float3 Q, float density, constant Light* lights, int lightCount) {
    float3 C = pl.center.xyz;
    float rp = pl.colorA.w;
    float3 base = mix(pl.colorA.rgb, float3(0.92, 0.86, 0.74), 0.55) * (0.75 + 0.35 * density);
    float3 lit = float3(0.0);
    for (int i = 0; i < lightCount; i++) {
        float3 L = normalize(lights[i].pos.xyz - Q);
        lit += lights[i].color.rgb * lights[i].pos.w * (0.25 + 0.75 * abs(dot(L, k.axis))) * planetShadow(Q, L, C, rp);
    }
    return base * (lit * 1.1 + 0.015) * (0.35 + 0.65 * density);
}

// Whether any planet on this shell could be hit by a ray crossing it at X, whatever its
// direction: the planet (and its rings) lies inside the shell (radius R), and a straight ray
// stays within depth d of the shell for at most sqrt(2 R d) either side of X, so a hit needs
// |X - C| < re + sqrt(2 R d) with d = R - (|C| - re), re = the planet's or its rings' radius.
// Lets most crossings skip the direction read and the intersection tests.
static bool planetsNearShellPoint(float3 X, float R, int shell, constant Planet* planets, int count) {
    for (int i = 0; i < count; i++) {
        Planet pl = planets[i];
        if (int(pl.center.w) != shell) continue;
        float3 C = pl.center.xyz;
        float re = max(pl.colorA.w, planetLook(pl).ringOut);
        float d = max(R - length(C) + re, 0.0);
        float reach = re + sqrt(2.0 * R * d) + 0.05;
        if (length_squared(X - C) < reach * reach) return true;
    }
    return false;
}

// A ray crossing a planet's orbit shell at X heading v; treat it as straight near the planet
// and intersect each planet's sphere and ring plane. Only the half-chord on this side of the
// shell counts. Rings are opaque where they are dense enough and shaded dimmer where thin.
static float4 shadePlanetsOnShell(float3 X, float3 v, int shell, constant Planet* planets, int count,
                                  constant Light* lights, int lightCount) {
    float best = 1e9;
    float4 out = float4(0.0);
    float halfChord = abs(dot(X, v));
    bool inbound = dot(X, v) < 0.0;
    for (int i = 0; i < count; i++) {
        Planet pl = planets[i];
        if (int(pl.center.w) != shell) continue;
        float3 C = pl.center.xyz;
        float rp = pl.colorA.w;
        float3 oc = X - C;
        PlanetLook k = planetLook(pl);
        if (k.ringOut > 0.0) {
            float va = dot(v, k.axis);
            if (abs(va) > 1e-4) {
                float t = dot(C - X, k.axis) / va;
                bool valid = inbound ? (t >= -k.ringOut && t <= halfChord + k.ringOut)
                                     : (t <= k.ringOut && t >= -halfChord - k.ringOut);
                float key = inbound ? t : -t;
                if (valid && key < best) {
                    float3 Q = X + v * t;
                    float dens = ringDensity(length(Q - C), k, pl.colorB.w);
                    if (dens > 0.3) {
                        best = key;
                        out = float4(shadeRing(pl, k, Q, dens, lights, lightCount), 1.0);
                    }
                }
            }
        }
        float b = dot(oc, v);
        float c = dot(oc, oc) - rp * rp;
        float disc = b * b - c;
        if (disc <= 0.0) continue;
        float t = -b - sqrt(disc);
        if (inbound ? (t < -rp || t > halfChord + rp) : (t > rp || t < -halfChord - rp)) continue;
        float key = inbound ? t : -t;
        if (key >= best) continue;
        best = key;
        float3 P = X + v * t;
        out = float4(shadePlanetSurfaceEx(pl, normalize(P - C), v, P, lights, lightCount, true), 1.0);
    }
    return out;
}
"""
}
