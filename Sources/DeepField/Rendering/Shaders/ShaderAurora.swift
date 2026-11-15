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
// S.f = clouds, moonlight, ground drift (rad/s), lightning (0..)
// S.g = sunrise glow, seed

constant float AU_BASE = 0.0155;   // the curtains' lower edge, ~100 km
constant float AU_TOP = 0.08;      // ~510 km: well above where the tallest rays fade out
constant float AU_AIRGLOW = 0.0148;

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

// Aurora light emitted at point p (per unit length), as (rgb).
static float3 auEmission(float3 p, float3 pole, float3 pe1, float3 pe2, float T, constant SceneParams& S) {
    float r = length(p);
    float a = r - 1.0;
    if (a < AU_BASE - 0.0015 || a > AU_TOP) return float3(0.0);
    float3 u = p / r;
    float gam = acos(clamp(dot(u, pole), -1.0, 1.0));
    float act = S.c.w, sub = S.d.w, seed = S.g.y;
    // the oval spreads toward the equator in a substorm
    float rho = S.a.w + 0.012 + 0.012 * sub;
    if (abs(gam - rho) > 0.12) return float3(0.0);        // nowhere near the oval: skip the noise
    float psi = atan2(dot(u, pe2), dot(u, pe1));
    float edge = rho + auWiggle(psi, T, act, sub, seed);
    float d = gam - edge;
    if (abs(d) > 0.08) return float3(0.0);
    // a few thin sheets, one behind another, plus a faint diffuse glow poleward
    float sheets = 0.0;
    for (int k = 0; k < 3; k++) {
        float off = float(k) * 0.011 + 0.004 * sin(psi * (3.0 + float(k)) + float(k) * 1.7 + T * 0.01 * act);
        float w = 0.0024 + 0.0012 * float(k);
        float dk = d - off;
        sheets += exp(-dk * dk / (w * w)) * (1.0 - 0.28 * float(k));
    }
    // a faint diffuse green glow poleward of the curtains, fading out well before the cut-off
    float diffuse = 0.012 * smoothstep(0.0, 0.01, d) * exp(-max(d, 0.0) / 0.025) * smoothstep(0.075, 0.04, d);
    // rays: fine vertical striations that shimmer and drift along the curtain
    float r1 = noise3(float3(psi * 220.0 + T * 0.6 * act, T * 0.7 * act, seed));
    float r2 = noise3(float3(psi * 70.0 - T * 0.25 * act, T * 0.35 * act, seed + 9.0));
    float rays = 0.12 + 0.9 * pow(r1, 2.5) + 0.9 * pow(r2, 3.0);
    // patches brighten and fade along the oval, and waves of brightness run along it
    float patches = 0.6 + 0.9 * smoothstep(0.25, 0.75, noise3(float3(psi * 7.0, T * 0.06 * act, seed + 4.0)));
    patches *= 0.8 + 0.6 * smoothstep(0.0, 1.0, sin(psi * 12.0 - T * 0.45 * act + 2.0 * noise3(float3(psi * 3.0, T * 0.02, seed))));
    float boost = S.b.w * (1.0 + 1.3 * sub);
    float bright = boost * sheets * rays * patches;
    // the colors by height: a nitrogen fringe along the bottom edge, oxygen green above it,
    // and oxygen red up top, fading into space
    // the lower edge is crisp and brightest; the light thins out upward
    float green = smoothstep(AU_BASE - 0.0008, AU_BASE + 0.0008, a)
                * (0.3 + 0.9 * exp(-max(a - AU_BASE, 0.0) / 0.004)) * exp(-max(a - AU_BASE - 0.002, 0.0) / 0.014);
    // the red tops reach higher in some places than others
    float topH = 0.03 + 0.012 * noise3(float3(psi * 16.0, T * 0.03 * act, seed + 6.0));
    float red = smoothstep(topH - 0.012, topH, a) * exp(-max(a - topH, 0.0) / 0.012) * 0.24;
    float fringe = exp(-pow((a - AU_BASE + 0.0004) / 0.0011, 2.0)) * (0.45 + 0.6 * sub);
    // Each ray reaches its own height and fades out softly above it, so the tops are ragged
    // and dissolve into space instead of ending on a line.
    float reach = 0.034 + 0.03 * r1 + 0.012 * r2;
    float top = smoothstep(reach + 0.012, reach - 0.008, a);
    // some stretches lean teal, others yellow-green, drifting with the patches
    float hue = noise3(float3(psi * 5.0, T * 0.04 * act, seed + 12.0));
    float3 g = mix(S.b.rgb * float3(0.35, 0.95, 1.25), S.b.rgb * float3(1.25, 1.0, 0.55), smoothstep(0.25, 0.75, hue));
    return (bright * (g * green + S.c.rgb * red) * top + bright * S.d.rgb * fringe) + boost * diffuse * patches * g * green;
}

// The ground at unit point g (in the drifting ground frame), at pixel footprint fp (Earth radii):
// land and sea, city lights strung along coasts and rivers of population, clouds, and moonlight.
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
        col += float3(0.75, 0.82, 1.0) * flash * exp(-pow(dist / 0.012, 2.0)) * (0.5 + cloud) * 2.2;
    }
    return col;
}

fragment float4 auroraFragment(FRAME_INPUTS)
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
        float3 g = rotateAbout(P, float3(1.0, 0.0, 0.0), -T * S.f.z);
        float cloud;
        col = auGround(g, fp, T, S, cloud);
        col += auLightning(g, cloud, T, S.f.w, S.g.y);
        // the aurora overhead lights the ground and clouds below it a little
        float3 pole = float3(0.0, cos(S.a.z), sin(S.a.z));
        float gam = acos(clamp(dot(P, pole), -1.0, 1.0));
        col += S.b.rgb * S.b.w * (1.0 + 2.0 * S.d.w) * exp(-pow((gam - S.a.w) / 0.03, 2.0)) * (0.006 + 0.03 * cloud);
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
        const float split = 0.04;
        float3 pole = float3(0.0, cos(S.a.z), sin(S.a.z));
        float3 pe1 = float3(1.0, 0.0, 0.0), pe2 = cross(pole, pe1);
        float jit = hash13(float3(float2(p), 1.0));
        float3 acc = float3(0.0);
        float2 low = sphereSpan(ro, rd, 1.0 + split);
        float l0 = max(low.x, 0.0), l1 = min(low.y, tEnd);
        if (l1 > l0) {
            const int N = 44;
            float dt = (l1 - l0) / float(N);
            for (int i = 0; i < N; i++) acc += auEmission(ro + rd * (l0 + (float(i) + jit) * dt), pole, pe1, pe2, T, S) * dt;
        }
        const int M = 14;
        float dt = (t1 - t0) / float(M);
        for (int i = 0; i < M; i++) {
            float3 x = ro + rd * (t0 + (float(i) + jit) * dt);
            if (length(x) < 1.0 + split) continue;           // covered by the dense steps
            acc += auEmission(x, pole, pe1, pe2, T, S) * dt;
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
