extension ShaderSource {
    static let aurora = """
// ---------- per-frame: aurora from orbit ----------
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
//
// The ground is the real Earth at night (NASA Black Marble, see Design/Earth), seen from above
// 43 N looking north: that latitude passes over the great cities of North America, Europe and
// East Asia. Earth turns eastward beneath the view while the auroral oval, held in place by the
// solar wind rather than by the ground, stays put.
//
// Textures: 10 and 11 are the Earth maps (city lights, ground); 12 is the per-frame table of the
// curtains' structure along the oval (8192x2, x = angle round the pole), filled by auroraLUT.

constant float AU_BASE = 0.0155;   // the curtains' lower edge, ~100 km
constant float AU_TOP = 0.08;      // ~510 km: well above where the tallest rays fade out
constant float AU_AIRGLOW = 0.0148;
constant float AU_VIEW_LAT = 0.75049;   // 43 deg: the latitude below the camera
constant float AU_MAP_SOUTH = -1.5707963; // the maps reach the south pole (make_earth_maps.py)
constant float AU_TEXEL = 7.6699e-4;    // 2 pi / 8192: a city-light texel, radians of arc

// How far the oval's edge is pushed out at angle psi round the pole: a slow meander, folds that
// travel along it, and the surge of a substorm.
static float auWiggle(float psi, float T, float act, float sub, float seed) {
    float slow = (noise3(float3(psi * 4.0, T * 0.02 * act, seed)) - 0.5) * 0.06
               + (noise3(float3(psi * 11.0, T * 0.05 * act, seed + 3.0)) - 0.5) * 0.025;
    // folds running along the curtain, and tighter curls riding on them
    float speed = act * (1.0 + 2.0 * sub);
    float folds = sin(psi * 26.0 - T * 0.3 * speed + 3.0 * noise3(float3(psi * 9.0, T * 0.03 * act, 2.0))) * 0.006
                + sin(psi * 70.0 + T * 0.55 * speed + 2.0 * noise3(float3(psi * 20.0, seed, T * 0.05 * act))) * 0.0018;
    return slow + folds * (1.8 + 1.2 * sub);
}

// The curtains' structure along the oval depends only on the angle round the pole and on time,
// so it is worked out once per frame for every angle instead of at every step of every ray.
// Row 0 holds (edge wiggle, fine rays, broad rays, patches); row 1 holds (red top height, hue
// mix, fine rays to the 2.5, broad rays cubed).
kernel void auroraLUT(texture2d<float, access::write> dst [[texture(0)]],
                      constant FrameParams& F [[buffer(0)]],
                      constant SceneParams& S [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y > 0) return;
    float psi = ((float(gid.x) + 0.5) / float(dst.get_width()) * 2.0 - 1.0) * M_PI_F;
    float T = F.time, act = S.c.w, sub = S.d.w, seed = S.g.y;
    float r1 = noise3(float3(psi * 220.0 + T * 0.6 * act, T * 0.7 * act, seed));
    float r2 = noise3(float3(psi * 70.0 - T * 0.25 * act, T * 0.35 * act, seed + 9.0));
    float patches = 0.6 + 0.9 * smoothstep(0.25, 0.75, noise3(float3(psi * 7.0, T * 0.06 * act, seed + 4.0)));
    patches *= 0.8 + 0.6 * smoothstep(0.0, 1.0, sin(psi * 12.0 - T * 0.45 * act + 2.0 * noise3(float3(psi * 3.0, T * 0.02, seed))));
    float topH = 0.03 + 0.012 * noise3(float3(psi * 16.0, T * 0.03 * act, seed + 6.0));
    float hue = smoothstep(0.25, 0.75, noise3(float3(psi * 5.0, T * 0.04 * act, seed + 12.0)));
    dst.write(float4(auWiggle(psi, T, act, sub, seed), r1, r2, patches), uint2(gid.x, 0));
    dst.write(float4(topH, hue, pow(r1, 2.5), pow(r2, 3.0)), uint2(gid.x, 1));
}

// Aurora light emitted at point p (per unit length), as (rgb).
static float3 auEmission(float3 p, float3 pole, float3 pe1, float3 pe2, float T, constant SceneParams& S,
                         texture2d<float> lut) {
    // clamped, not wrapped: psi has a seam at +-pi where the noise does not repeat
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float r = length(p);
    float a = r - 1.0;
    if (a < AU_BASE - 0.0015 || a > AU_TOP) return float3(0.0);
    float3 u = p / r;
    float gam = acos(clamp(dot(u, pole), -1.0, 1.0));
    float act = S.c.w, sub = S.d.w;
    // the oval spreads toward the equator in a substorm
    float rho = S.a.w + 0.012 + 0.012 * sub;
    // nowhere near the oval: no light (the march in auroraFragment skips this band with auCone)
    if (abs(gam - rho) > 0.12) return float3(0.0);
    float psi = atan2(dot(u, pe2), dot(u, pe1));
    float lu = psi * (0.5 / M_PI_F) + 0.5;
    float4 la = lut.sample(ls, float2(lu, 0.25), level(0.0));   // row 0
    float edge = rho + la.x;
    float d = gam - edge;
    if (abs(d) > 0.08) return float3(0.0);
    // a few thin sheets, one behind another, plus a faint diffuse glow poleward
    // Higher up the curtains spread and blur (the red oxygen light is slow to emit, so it drifts
    // and diffuses before it glows), so the sheets widen with height.
    float above = max(a - AU_BASE, 0.0);
    float spread = 1.0 + 70.0 * above;
    float sheets = 0.0;
    for (int k = 0; k < 3; k++) {
        float off = float(k) * 0.011 + 0.004 * sin(psi * (3.0 + float(k)) + float(k) * 1.7 + T * 0.01 * act);
        float w = (0.0024 + 0.0012 * float(k)) * spread;
        float dk = d - off;
        sheets += exp(-dk * dk / (w * w)) * (1.0 - 0.28 * float(k)) / sqrt(spread);
    }
    // a faint diffuse green glow poleward of the curtains, fading out well before the cut-off
    float diffuse = 0.012 * smoothstep(0.0, 0.01, d) * exp(-max(d, 0.0) / 0.025) * smoothstep(0.075, 0.04, d);
    // rays: fine vertical striations that shimmer and drift along the curtain, read from the table
    float4 lb = lut.sample(ls, float2(lu, 0.75), level(0.0));   // row 1
    float r1 = la.y, r2 = la.z;
    // the finest striations are sharpest at the bottom and wash out into the broad rays above
    float fineK = exp(-above / 0.012);
    float rays = 0.12 + 0.9 * lb.z * fineK + (0.9 * lb.w + 0.25 * (1.0 - fineK));
    // patches brighten and fade along the oval, and waves of brightness run along it (from the table)
    float patches = la.w;
    float boost = S.b.w * (1.0 + 1.3 * sub);
    float bright = boost * sheets * rays * patches;
    // the colors by height: a nitrogen fringe along the bottom edge, oxygen green above it,
    // and oxygen red up top, fading into space
    // the lower edge is crisp and brightest; the light thins out upward
    float green = smoothstep(AU_BASE - 0.0008, AU_BASE + 0.0008, a)
                * (0.3 + 0.9 * exp(-max(a - AU_BASE, 0.0) / 0.004)) * exp(-max(a - AU_BASE - 0.002, 0.0) / 0.014);
    // the red tops reach higher in some places than others (the height is in the table)
    float topH = lb.x;
    float red = smoothstep(topH - 0.012, topH, a) * exp(-max(a - topH, 0.0) / 0.012) * 0.24;
    float fringe = exp(-sq((a - AU_BASE + 0.0004) / 0.0011)) * (0.45 + 0.6 * sub);
    // Each ray reaches its own height and fades out softly above it, so the tops are ragged
    // and dissolve into space instead of ending on a line.
    // The broad rays set the heights, and the fade is long, so the tops dissolve as gradually
    // as the curtains' lower parts do.
    float reach = 0.036 + 0.008 * r1 + 0.03 * r2;
    float top = smoothstep(reach + 0.022, reach - 0.014, a);
    // some stretches lean teal, others yellow-green, drifting with the patches (the mix is in the table)
    float3 g = mix(S.b.rgb * float3(0.35, 0.95, 1.25), S.b.rgb * float3(1.25, 1.0, 0.55), lb.y);
    return (bright * (g * green + S.c.rgb * red) * top + bright * S.d.rgb * fringe) + boost * diffuse * patches * g * green;
}

// Where unit point P (scene frame) is on Earth: latitude, longitude, and the Earth-fixed unit
// vector the clouds and storms are pinned to.
static float3 auGeo(float3 P, constant SceneParams& S, thread float& lat, thread float& lon) {
    float phi = AU_VIEW_LAT;
    float3 north = float3(0.0, sin(phi), cos(phi));      // Earth's spin axis
    float3 meridian = float3(0.0, cos(phi), -sin(phi));  // the view's meridian at the equator
    lat = asin(clamp(dot(P, north), -1.0, 1.0));
    lon = S.g.w + atan2(P.x, dot(P, meridian));          // +x is east
    return float3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
}

// The real night side: Black Marble city lights (square-root encoded) over the dim ground they
// were laid on, which tells land from sea and shows snow, plus clouds and moonlight.
static float3 auEarth(float lat, float lon, float3 g, float fp, float T, constant SceneParams& S,
                      texture2d<float> lightsTex, texture2d<float> groundTex, thread float& cloudOut) {
    constexpr sampler sm(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float2 uv = float2(lon / (2.0 * M_PI_F) + 0.5, (M_PI_2_F - lat) / (M_PI_2_F - AU_MAP_SOUTH));
    // the footprint in texels, with the east-west squeeze toward the pole split between the axes
    float lod = log2(max(fp, 1e-6) / (AU_TEXEL * sqrt(max(cos(lat), 0.05))));
    float li = sq(lightsTex.sample(sm, uv, level(max(lod, 0.0))).r);
    float gr = sq(groundTex.sample(sm, uv, level(max(lod - 2.0, 0.0))).r);
    // Where a pixel is finer than the map, a fine speckle breaks a town's soft texel up into
    // streets and blocks, keeping its average.
    float sharp = 1.0 - smoothstep(-1.5, 0.0, lod);
    float specks = smoothstep(0.42, 0.7, fbmLOD(g * 1400.0 + 13.0, fp * 1400.0));
    li *= mix(1.0, 0.35 + 2.2 * specks, sharp);
    float lights = li * S.e.w * 2.6;
    // dim suburbs glow sodium orange, bright centers burn whiter
    float3 lc = mix(S.e.rgb, float3(0.85, 0.9, 1.0), smoothstep(0.15, 0.9, li) * 0.55);
    float cloud = smoothstep(0.46, 0.78, fbm(g * 4.0 + float3(S.g.y + 7.0, 0.0, T * 0.0004))) * S.f.x;
    cloudOut = cloud;
    float moon = S.f.y;
    float3 col = lc * lights * (1.0 - 0.85 * cloud);
    // moonlit ground: the sea near black, land a little brighter, snow and ice brightest
    col += (float3(0.0015, 0.003, 0.008) + float3(0.11, 0.1, 0.095) * max(gr - 0.027, 0.0)) * moon;
    col += float3(0.02, 0.022, 0.03) * cloud * moon;
    return col;
}

// A made-up Earth for when the maps are missing, at Earth-fixed unit point g and pixel footprint
// fp (Earth radii): land and sea, city lights strung along coasts and rivers of population,
// clouds, and moonlight.
static float3 auGround(float3 g, float fp, float T, constant SceneParams& S, thread float& cloudOut) {
    float seed = S.g.y;
    float land = smoothstep(0.5, 0.54, fbm(g * 2.2 + seed) + 0.12 * (fbmLOD(g * 9.0 + 3.0, fp * 9.0) - 0.5));
    float pop = smoothstep(0.36, 0.7, fbm(g * 5.0 + seed + 11.0)) * land;
    float fine = fbmLOD(g * 160.0 + 7.0, fp * 160.0);
    // towns: clusters of bright specks (finer than the clusters themselves) with a dim glow between
    float specks = smoothstep(0.5, 0.66, fbmLOD(g * 700.0 + 13.0, fp * 700.0));
    float towns = smoothstep(0.5, 0.78, fine) * (0.5 + 5.0 * specks) + smoothstep(0.45, 0.6, fbmLOD(g * 35.0 + 2.0, fp * 35.0)) * 0.2;
    float lights = pop * towns * S.e.w * 0.6;
    float3 lc = mix(S.e.rgb, float3(0.85, 0.9, 1.0), smoothstep(0.55, 0.8, noise3(g * 300.0 + 5.0)) * 0.6);
    float cloud = smoothstep(0.46, 0.78, fbm(g * 4.0 + float3(seed + 7.0, 0.0, T * 0.0004))) * S.f.x;
    cloudOut = cloud;
    float moon = S.f.y;
    float3 col = lc * lights * (1.0 - 0.85 * cloud);
    col += mix(float3(0.002, 0.004, 0.01), float3(0.007, 0.006, 0.005), land) * moon;
    col += float3(0.02, 0.022, 0.03) * cloud * moon;
    return col;
}

// Lightning in storm clouds: storm cells sit on a grid in the drifting ground frame, and each
// flashes now and then, lighting a patch of cloud from inside.
static float3 auLightning(float3 g, float cloud, float T, float rate, float seed) {
    if (rate <= 0.0 || cloud < 0.2) return float3(0.0);
    const float cell = 0.06;
    float3 base = floor(g / cell);
    float3 col = float3(0.0);
    for (int i = 0; i < 8; i++) {
        float3 c = base + float3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        float h = hash13(c + seed);
        if (h > 0.18) continue;
        float3 center = (c + float3(hash13(c + 1.3), hash13(c + 2.7), hash13(c + 4.1))) * cell;
        float dist = length(g - center);
        if (dist > 0.03) continue;
        float slot = T * (2.2 + 2.0 * h) * rate + h * 40.0;
        float roll = hash13(float3(c.xy, floor(slot)));
        float flash = roll > 0.86 ? exp(-fract(slot) * 7.0) * (0.6 + 0.8 * fract(roll * 13.0)) : 0.0;
        col += float3(0.75, 0.82, 1.0) * flash * exp(-sq(dist / 0.012)) * (0.5 + cloud) * 2.2;
    }
    return col;
}

// Where a ray is inside the cone of half-angle acos(c) round `axis`, apex at Earth's center:
// (enter, exit), empty when enter >= exit. The oval's band lies between two such cones round
// the magnetic pole.
static float2 auCone(float3 ro, float3 rd, float3 axis, float c) {
    float ra = dot(ro, axis), da = dot(rd, axis), c2 = sq(c);
    float A = sq(da) - c2, B = ra * da - c2 * dot(ro, rd), C = sq(ra) - c2 * dot(ro, ro);
    float disc = sq(B) - A * C;
    if (disc <= 0.0) return float2(1.0, 0.0);
    // the stable form of the quadratic's roots: one stays finite as the ray turns parallel to the cone
    float q = -(B + (B < 0.0 ? -1.0 : 1.0) * sqrt(disc));
    float x1 = clamp(q / A, -1e9, 1e9), x2 = C / q;
    float lo = min(x1, x2), hi = max(x1, x2);
    // a ray heading outside the cone's directions is inside it between the roots (if they are on
    // the pole's side); one heading within them enters and never leaves
    if (A < 0.0) return ra + da * x2 > 0.0 ? float2(lo, hi) : float2(1.0, 0.0);
    return da > 0.0 ? float2(hi, 1e9) : float2(-1e9, lo);
}

fragment float4 auroraFragment(FRAME_INPUTS,
                               texture2d<float> earthLights [[texture(10)]],
                               texture2d<float> earthGround [[texture(11)]],
                               texture2d<float> auLut [[texture(12)]])
{
    uint2 p = uint2(in.pos.xy);
    float3 rdw = octDecode(dirTex.read(p).xy);
    float T = F.time;
    float3 right = F.camRight.xyz, up = F.camUp.xyz, fwd = cross(right, up);
    float3 l = float3(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    float pitch = S.a.x;
    float3 rd = normalize(float3(l.x, l.y * cos(pitch) + l.z * sin(pitch), -l.y * sin(pitch) + l.z * cos(pitch)));
    float h = S.a.y;
    float3 ro = float3(0.0, 1.0 + h, 0.0);
    float pixAng = F.pixelAngle;

    float2 ground = sphereSpan(ro, rd, 1.0);
    bool hitGround = ground.x < ground.y && ground.x > 0.0;
    float tEnd = hitGround ? ground.x : 1e9;
    float b = length(ro - rd * dot(ro, rd));           // how close the ray passes to Earth's center

    float3 col = float3(0.0);
    if (hitGround) {
        float3 P = ro + rd * ground.x;
        float fp = pixAng * ground.x / max(dot(P, -rd), 0.06);
        float lat, lon, cloud;
        float3 g = auGeo(P, S, lat, lon);
        col = S.g.z > 0.5 ? auEarth(lat, lon, g, fp, T, S, earthLights, earthGround, cloud)
                          : auGround(g, fp, T, S, cloud);
        col += auLightning(g, cloud, T, S.f.w, S.g.y);
        // the aurora overhead lights the ground and clouds below it a little
        float3 pole = float3(0.0, cos(S.a.z), sin(S.a.z));
        float gam = acos(clamp(dot(P, pole), -1.0, 1.0));
        col += S.b.rgb * S.b.w * (1.0 + 2.0 * S.d.w) * exp(-sq((gam - S.a.w) / 0.03)) * (0.006 + 0.03 * cloud);
        // seen through more air toward the limb, the ground fades into a blue haze
        float slant = 1.0 / max(dot(normalize(P), -rd), 0.05);
        col = col * exp(-0.035 * slant) + float3(0.001, 0.003, 0.009) * (1.0 - exp(-0.03 * slant)) * (0.3 + S.f.y);
    } else {
        // stars, dimmed where they shine through the air at the limb
        col = SKY(p, rdw, false) * smoothstep(1.0, 1.03, b);
    }

    // airglow: a thin shell of faint green light about 95 km up; edge-on at the limb it piles
    // up into a bright line
    {
        float2 so = sphereSpan(ro, rd, 1.0 + AU_AIRGLOW + 0.0012), si = sphereSpan(ro, rd, 1.0 + AU_AIRGLOW - 0.0012);
        float len = max(min(so.y, tEnd) - max(so.x, 0.0), 0.0);
        if (si.x < si.y) len -= max(min(si.y, tEnd) - max(si.x, 0.0), 0.0);
        // seen face-on over the disk it's only a faint tint; edge-on above the limb, a bright line
        col += float3(0.35, 1.0, 0.45) * max(len, 0.0) * (hitGround ? 0.12 : 0.9) * (0.8 + 0.4 * noise3(rd * 40.0 + float3(T * 0.01, 0.0, 0.0)));
    }
    // the atmosphere's own glow above the limb, and sunrise warming one end of it
    float rim = exp(-max(b - 1.0, 0.0) / 0.0025) * (b > 1.0 || !hitGround ? 1.0 : 0.0);
    float dawn = S.g.x * smoothstep(0.1, 0.85, rd.x / max(length(rd.xz), 1e-3));
    col += (float3(0.03, 0.06, 0.16) * 0.35 + mix(float3(0.25, 0.4, 0.9), float3(1.0, 0.45, 0.15), exp(-max(b - 1.0, 0.0) / 0.004)) * dawn * 0.7) * rim;

    // The aurora: march the ray where it's inside the aurora's shell and in front of the ground.
    // The thin curtains live in the lower part, so that stretch gets dense steps; the soft tops
    // above it only need a few.
    float2 top = sphereSpan(ro, rd, 1.0 + AU_TOP);
    float t0 = max(top.x, 0.0), t1 = min(top.y, tEnd);
    if (t1 > t0 && S.b.w > 0.0) {
        const float split = 0.05;
        const int N = 44, M = 14;
        float3 pole = float3(0.0, cos(S.a.z), sin(S.a.z));
        float3 pe1 = float3(1.0, 0.0, 0.0), pe2 = cross(pole, pe1);
        float jit = hash13(float3(float2(p), 1.0));
        // Light only comes from within 0.12 rad of the oval (auEmission's own test), a band between
        // two cones round the pole, and from above the curtains' lower edge. Steps outside that
        // would add nothing, so only the steps inside it are run, at the places they always were.
        float rho = S.a.w + 0.012 + 0.012 * S.d.w;
        float2 oc = auCone(ro, rd, pole, cos(rho + 0.12));
        float2 ic = auCone(ro, rd, pole, cos(max(rho - 0.12, 0.0)));
        float2 band[2] = { oc, float2(1.0, 0.0) };
        if (ic.x < ic.y) { band[0].y = min(oc.y, ic.x); band[1] = float2(max(oc.x, ic.y), oc.y); }
        float2 low = sphereSpan(ro, rd, 1.0 + split);
        float l0 = max(low.x, 0.0), l1 = min(low.y, tEnd);
        bool hasLow = l1 > l0;
        float2 base = sphereSpan(ro, rd, 1.0 + AU_BASE - 0.0015);
        bool hasBase = base.x < base.y;
        float dtL = (l1 - l0) / float(N), dtH = (t1 - t0) / float(M);
        // stretches of the ray to sample: (from, to, 1 = dense steps below the split)
        float3 piece[4] = {
            float3(t0, hasLow ? l0 : t1, 0.0), float3(hasLow ? l1 : t1, t1, 0.0),
            float3(l0, hasBase ? min(base.x, l1) : l1, 1.0), float3(hasBase ? max(base.y, l0) : l1, l1, 1.0) };
        float3 acc = float3(0.0);
        for (int k = 0; k < 4; k++) {
            bool dense = piece[k].z > 0.5;
            if (dense && !hasLow) continue;
            float org = dense ? l0 : t0, dt = dense ? dtL : dtH;
            int n = dense ? N : M;
            for (int j = 0; j < 2; j++) {
                // a little slack, so rounding never drops a step; auEmission's own tests still decide
                float s = max(piece[k].x, band[j].x) - 1e-4, e = min(piece[k].y, band[j].y) + 1e-4;
                if (e <= s) continue;
                int i0 = max(int(ceil((s - org) / dt - jit)), 0), i1 = min(int(ceil((e - org) / dt - jit)), n);
                for (int i = i0; i < i1; i++) {
                    float3 x = ro + rd * (org + (float(i) + jit) * dt);
                    if (!dense && length(x) < 1.0 + split) continue;      // covered by the dense steps
                    acc += auEmission(x, pole, pe1, pe2, T, S, auLut) * dt;
                }
            }
        }
        col += acc * 14.0;
    }
    // The scene's own look, on top of the global image settings: about a third more light and
    // a contrast curve (1.3 around mid gray), so the curtains stand out against the night side.
    {
        float3 x = max(col, 0.0) * 1.3 * F.exposure;
        x = 0.18 * pow(x / 0.18, float3(1.3));
        col = x / max(F.exposure, 1e-3);
    }
    return finalize(col, p, F);
}
"""
}
