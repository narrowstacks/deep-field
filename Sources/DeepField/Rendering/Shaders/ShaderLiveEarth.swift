extension ShaderSource {
    static let liveEarth = """
// ---------- per-frame: live Earth ----------
// The whole Earth as it is right now, seen from far above a chosen place that stays in the
// middle of the disk: real sunlight and seasons, city lights on the night side, the Moon where it
// really is (in its real phase, with earthshine and eclipses), and optionally the latest cloud
// map and NOAA's aurora forecast. Everything is in Earth-fixed coordinates, Earth radius 1:
// x toward 0 N 0 E, y toward 0 N 90 E, z the north pole. The sun and Moon positions come from
// the CPU (SceneParams.liveEarth), worked out for the scene's date.
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
// S.n = star brightness, Milky Way brightness
//
// Textures: 10 city lights, 11 night ground, 12 and 13 the January and July surface,
// 14 open water, 15 the Moon, 16 the cloud map, 17 the aurora forecast, 18 the star catalog
// splatted into a map, 19 the Milky Way (see EarthMaps, LiveEarthFeeds).

constant float LE_ATMO = 0.06;          // the air and the aurora above it, up to ~380 km
constant float LE_SCALE_H = 0.0075;     // its scale height (~48 km, real is 8)
constant float LE_SUN_R = 0.00465;      // the sun's angular radius
constant float3 LE_RAYLEIGH = float3(0.17, 0.42, 1.0);   // ~ 1 / wavelength^4 for 680, 550, 440 nm

static float2 leUV(float3 n) {
    float lat = asin(clamp(n.z, -1.0, 1.0));
    float lon = atan2(n.y, n.x);
    return float2(lon / (2.0 * M_PI_F) + 0.5, 0.5 - lat / M_PI_F);
}

// Sunlight reaching height-point p after its slant path through the air: reddens and fades as the
// sun sets, so the terminator glows orange. mu is the sun's elevation sine at p.
static float3 leSunColor(float mu) {
    float airmass = 1.0 / max(mu + 0.12, 0.04);
    return exp(-LE_RAYLEIGH * 0.09 * airmass) * smoothstep(-0.12, 0.02, mu);
}

// A sphere at center c, radius r: (enter, exit), empty when enter >= exit.
static float2 leSphere(float3 ro, float3 rd, float3 c, float r) {
    float3 oc = ro - c;
    float b = dot(oc, rd), cc = dot(oc, oc) - r * r;
    float h = b * b - cc;
    if (h < 0.0) return float2(1.0, 0.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// How much of the sun the Moon hides, seen from point p: 0 none, 1 total (a solar eclipse's
// shadow on Earth). Disks of angular radius LE_SUN_R and am, centers sep apart.
static float leEclipse(float3 p, float3 s, float3 moon, float rm) {
    float3 v = moon - p;
    float dv = length(v);
    float am = rm / dv;
    // the angle from the cross product: acos of a dot product this close to 1 loses the
    // fraction of a degree that matters here
    float3 u = v / dv;
    if (dot(u, s) <= 0.0) return 0.0;
    float sep = asin(min(length(cross(u, s)), 1.0));
    float covered = 1.0 - smoothstep(abs(LE_SUN_R - am), LE_SUN_R + am, sep);
    return covered * min(sq(am / LE_SUN_R), 1.0);
}

// The aurora forecast (chance of aurora overhead, 0..1) at unit point n. NOAA's grid has
// column i at longitude i degrees east and row j at latitude 90 - j.
static float leAuroraMap(float3 n, texture2d<float> tex) {
    constexpr sampler sm(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float lat = asin(clamp(n.z, -1.0, 1.0)) * (180.0 / M_PI_F);
    float lon = atan2(n.y, n.x) * (180.0 / M_PI_F);
    float2 uv = float2((lon + 0.5) / 360.0, (90.0 - lat + 0.5) / 181.0);
    return tex.sample(sm, uv, level(0.0)).r;
}

// Aurora light emitted per unit length at p (height a above the ground), in arcs that run
// east-west along the oval. By height: a pink-purple nitrogen fringe along the lower edge
// (~95 km), oxygen green above it (~120 km), oxygen red higher up (~240 km, stronger in storms),
// and, near the day-night line, blue-violet tops where the highest curtains catch sunlight
// (nitrogen ions scattering it).
static float3 leAuroraEmit(float3 p, float a, float T, texture2d<float> tex, float3 s) {
    float3 n = p / (1.0 + a);
    float chance = leAuroraMap(n, tex);
    if (chance < 0.01) return float3(0.0);
    // only where it's dark below: the sky has to be past twilight for the glow to show
    float mu = dot(n, s);
    float dark = smoothstep(0.05, -0.2, mu);
    if (dark <= 0.0) return float3(0.0);
    float lat = asin(clamp(n.z, -1.0, 1.0)), lon = atan2(n.y, n.x);
    // Arcs stretched along the lines of latitude. They drift along the oval and fold into
    // swirls over a minute or so, fine rays shimmer across them in seconds, and surges of
    // brightness run along them, the way active aurora pulses.
    // Earth's field lines lean equatorward as they rise, so a curtain's upper parts sit a little
    // equatorward of its base (exaggerated a few times here). Seen from above, that keeps the red
    // tops beside the green instead of on top of it, where the two would add up to olive.
    float lean = (a - 0.019) * 0.4 * sign(lat);
    float latA = lat - lean;
    float fold = noise3(float3(lon * 6.0 - T * 0.02, latA * 12.0, T * 0.12));
    float arcRaw = noise3(float3(lon * 3.0 + T * 0.035, latA * 70.0 + 5.0 * fold, T * 0.1));
    // a wide falloff and a broad glow underneath, so each arc fades out over its edges
    float glow = noise3(float3(lon * 2.0 + T * 0.03, latA * 22.0 + 2.0 * fold, T * 0.06));
    float arcs = mix(smoothstep(0.3, 0.92, arcRaw), smoothstep(0.35, 0.85, glow), 0.2);
    float rays = 0.45 + 0.55 * noise3(float3(lon * 260.0 - T * 0.25, latA * 20.0, T * 0.7));
    float surge = 0.55 + 0.9 * smoothstep(0.2, 1.0, sin(lon * 14.0 - T * 0.45 + 3.0 * fold));
    float strength = smoothstep(0.0, 0.25, chance) * (0.4 + chance) * dark;
    // the green and the nitrogen fringe follow the sharp arcs and their rays; the red, slow to
    // emit, spreads into a softer glow round them
    float sharp = (0.15 + 1.8 * arcs * rays * surge) * strength;
    float soft = (0.08 + 1.2 * mix(smoothstep(0.15, 0.9, arcRaw), glow, 0.25) * surge) * strength;
    float green = exp(-sq((a - 0.019) / 0.006)) + 0.3 * exp(-max(a - 0.019, 0.0) / 0.008) * step(0.017, a);
    float red = exp(-sq((a - 0.038) / 0.013)) * (0.35 + 0.8 * chance);
    float fringe = exp(-sq((a - 0.0155) / 0.0025)) * 0.42 * smoothstep(0.1, 0.5, chance);
    // sunlit tops: the curtains' upper parts are still in sunlight just past the terminator
    float sunlitTop = exp(-sq((a - 0.05) / 0.012)) * smoothstep(-0.4, -0.12, mu) * 0.35;
    return sharp * (float3(0.12, 1.0, 0.38) * green * 1.9 + float3(0.85, 0.2, 1.0) * fringe)
         + soft * (float3(1.0, 0.1, 0.32) * red + float3(0.5, 0.3, 1.0) * sunlitTop);
}

// The real sky in direction rd (Earth-fixed): the catalog's stars where they are tonight, in
// their own colors, over the Milky Way's glow. Each star sits in one texel of the map and is
// spread over the pixels round it by its angular distance, so it glides smoothly as the sky
// turns instead of hopping from pixel to pixel.
static float3 leSky(float3 rd, constant SceneParams& S, float pixAng,
                    texture2d<float> stars, texture2d<float> milky) {
    constexpr sampler ms(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float3 c = float3(dot(S.k.xyz, rd), dot(S.l.xyz, rd), dot(S.m.xyz, rd));
    float dec = asin(clamp(c.z, -1.0, 1.0));
    float ra = atan2(c.y, c.x);
    if (ra < 0.0) ra += 2.0 * M_PI_F;
    int W = int(stars.get_width()), H = int(stars.get_height());
    float2 uv = float2(ra / (2.0 * M_PI_F), 0.5 - dec / M_PI_F);
    // Half the map sits below about 12% gray (faint stars and sky glow, in linear light about
    // 0.012). Fading that out with a soft knee leaves the Milky Way's band, with soft edges,
    // instead of a haze over the whole sky.
    float3 mw = milky.sample(ms, uv, level(0.0)).rgb;
    mw *= smoothstep(0.006, 0.04, dot(mw, float3(0.3, 0.5, 0.2)));
    // its dust lanes print brown; most of the glow reads as a neutral starlit haze
    float3 col = mix(float3(dot(mw, float3(0.3, 0.5, 0.2))), mw, 0.6) * S.n.y * 0.06;
    float texel = 2.0 * M_PI_F / float(W);
    float sigma = max(pixAng * 0.75, texel * 0.6);
    float reach = 2.2 * sigma;
    int ny = min(int(ceil(reach / texel)), 3);
    int nx = min(int(ceil(reach / (texel * max(cos(dec), 0.05)))), 8);
    int2 at = int2(floor(uv * float2(W, H)));
    float3 acc = float3(0.0);
    for (int dy = -ny; dy <= ny; dy++) {
        int y = at.y + dy;
        if (y < 0 || y >= H) continue;
        for (int dx = -nx; dx <= nx; dx++) {
            int x = (at.x + dx + W) % W;
            float4 t = stars.read(uint2(x, y));
            if (t.a <= 0.0) continue;
            float sra = (float(x) + 0.5) / float(W) * 2.0 * M_PI_F;
            float sdec = (0.5 - (float(y) + 0.5) / float(H)) * M_PI_F;
            float3 sd = float3(cos(sdec) * cos(sra), cos(sdec) * sin(sra), sin(sdec));
            float d2 = 2.0 * max(1.0 - dot(sd, c), 0.0);     // the angle squared
            // brightness from the magnitude, a little compressed (flux to the 0.75) so the
            // faintest naked-eye stars still show next to Sirius
            float v = 7.0 - 9.0 * t.a;
            acc += t.rgb * exp2(-0.9966 * v) * exp(-d2 / sq(sigma));
        }
    }
    return col + acc * S.n.x * 4.0;
}

static float3 leMoonColor(float3 q, float3 mc, float rTrue, float3 s, constant SceneParams& S,
                          texture2d<float> moonTex, bool mapped) {
    constexpr sampler sm(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float3 n = normalize(q - mc);
    // the near side always faces Earth; its pole is close enough to Earth's
    float3 xm = normalize(-mc);
    float3 zm = normalize(float3(0.0, 0.0, 1.0) - xm * xm.z);
    float3 ym = cross(zm, xm);
    float lat = asin(clamp(dot(n, zm), -1.0, 1.0));
    float lon = atan2(dot(n, ym), dot(n, xm));
    float alb = mapped ? sq(moonTex.sample(sm, float2(lon / (2.0 * M_PI_F) + 0.5, 0.5 - lat / M_PI_F)).r) * 0.9
                       : 0.18 + 0.1 * noise3(n * 6.0);
    // where Earth's shadow falls on the real Moon (a lunar eclipse): the umbra narrows to about
    // 0.73 Earth radii at the Moon's distance, the penumbra widens to about 1.27, and inside the
    // umbra only sunlight bent red through Earth's air gets in
    float3 qt = mc + n * rTrue;
    float along = dot(qt, -s);
    float3 lit = float3(1.0);
    if (along > 0.0) {
        float off = length(qt + s * along);
        float um = 1.0 - along * 0.0045, pen = 1.0 + along * 0.0045;
        float f = smoothstep(um, pen, off);
        lit = mix(float3(0.06, 0.018, 0.008), float3(1.0), f);
    }
    float ndl = max(dot(n, s), 0.0);
    // earthshine: the day side of Earth faintly lights the Moon's night side
    float earthshine = max(dot(n, xm), 0.0) * 0.004 * (0.5 - 0.5 * dot(s, -xm));
    return float3(1.0, 0.97, 0.92) * alb * (ndl * 1.6 * lit + earthshine);
}

fragment float4 liveEarthFragment(FRAME_INPUTS,
                                  texture2d<float> lightsTex [[texture(10)]],
                                  texture2d<float> groundTex [[texture(11)]],
                                  texture2d<float> dayJan [[texture(12)]],
                                  texture2d<float> dayJul [[texture(13)]],
                                  texture2d<float> waterTex [[texture(14)]],
                                  texture2d<float> moonTex [[texture(15)]],
                                  texture2d<float> cloudTex [[texture(16)]],
                                  texture2d<float> auroraTex [[texture(17)]],
                                  texture2d<float> starTex [[texture(18)]],
                                  texture2d<float> milkyTex [[texture(19)]])
{
    constexpr sampler sm(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    uint2 p = uint2(in.pos.xy);
    float3 rdw = octDecode(dirTex.read(p).xy);
    float T = F.time;
    float3 right = F.camRight.xyz, up = F.camUp.xyz, fwd = cross(right, up);
    float3 l = float3(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    float3 rd = normalize(l.x * S.b.xyz + l.y * S.c.xyz + l.z * S.d.xyz);
    float3 ro = S.a.xyz;
    float3 s = S.e.xyz;
    float3 moonC = S.f.xyz;
    bool mapped = S.h.z > 0.5;

    float2 ground = leSphere(ro, rd, float3(0.0), 1.0);
    bool hit = ground.x < ground.y && ground.x > 0.0;
    float tEnd = hit ? ground.x : 1e9;
    float3 col = float3(0.0);
    float moonlight = S.g.w * 0.5 * (1.0 - dot(s, normalize(moonC)));   // scaled by the Moon's lit fraction

    if (hit) {
        float3 P = ro + rd * ground.x;
        float3 n = P;
        float fp = F.pixelAngle * ground.x / max(dot(n, -rd), 0.05);
        float2 uv = leUV(n);
        float mu = dot(n, s);
        float3 sun = leSunColor(mu);
        if (S.j.w > 0.5) sun *= 1.0 - leEclipse(P, s, moonC, S.j.y);
        float3 m = normalize(moonC - P);
        float mlight = max(dot(n, m), 0.0) * moonlight;

        float lat = asin(clamp(n.z, -1.0, 1.0));
        float lod = log2(max(fp, 1e-6) / (7.67e-4 * sqrt(max(cos(lat), 0.05))));
        float3 alb;
        float water, lights, gr;
        if (mapped) {
            float lodDay = log2(max(fp, 1e-6) / (2.1817e-3 * sqrt(max(cos(lat), 0.05))));
            alb = mix(dayJan.sample(sm, uv, level(max(lodDay, 0.0))).rgb, dayJul.sample(sm, uv, level(max(lodDay, 0.0))).rgb, S.h.w);
            water = waterTex.sample(sm, uv, level(max(lodDay - 1.0, 0.0))).r;
            lights = sq(lightsTex.sample(sm, uv, level(max(lod, 0.0))).r);
            gr = sq(groundTex.sample(sm, uv, level(max(lod - 2.0, 0.0))).r);
        } else {
            float land = smoothstep(0.5, 0.54, fbm(n * 2.2 + 5.3));
            alb = mix(float3(0.004, 0.008, 0.03), float3(0.12, 0.13, 0.07), land);
            water = 1.0 - land;
            lights = land * smoothstep(0.6, 0.8, fbm(n * 30.0)) * 0.3;
            gr = land * 0.1;
        }
        float cloud = 0.0;
        if (S.h.x > 0.5 && S.g.x > 0.0) {
            float c = cloudTex.sample(sm, uv, level(max(lod - 1.0, 0.0))).r;
            // The map is infrared: warm clear ground reads mid gray, cold high cloud near white, and
            // cold clear ground in winter in between, so only the brighter part counts as cloud.
            cloud = smoothstep(0.58, 0.97, c) * min(S.g.x, 1.0);
            cloud = min(cloud * max(S.g.x, 1.0), 1.0);
        }
        // the day side: the surface, then cloud over it, lit by sunlight that reddens toward dusk
        float ndl = max(mu, 0.0);
        float3 surf = alb * mix(1.0, 0.25, cloud) + float3(0.82, 0.84, 0.88) * cloud;
        float3 day = surf * sun * (ndl * 1.25 + 0.03 * smoothstep(-0.08, 0.05, mu));
        // the sun's glint off open water, centered between us and the sun
        float3 h = normalize(s - rd);
        float nh = max(dot(n, h), 0.0);
        float glint = (pow(nh, 1500.0) * 1.4 + pow(nh, 120.0) * 0.07) * water * (1.0 - cloud) * smoothstep(0.0, 0.1, mu);
        day += sun * glint;
        // the night side: city lights (hidden under cloud), moonlit ground and clouds
        float night = smoothstep(0.08, -0.12, mu);
        float3 lc = mix(float3(1.0, 0.62, 0.3), float3(0.85, 0.9, 1.0), smoothstep(0.15, 0.9, lights) * 0.55);
        float flicker = 0.92 + 0.08 * noise3(n * 900.0 + float3(0.0, 0.0, T * 0.6));
        float3 city = lc * lights * S.g.z * 4.0 * flicker * (1.0 - 0.85 * cloud) * night;
        float3 moonlit = (alb * 0.9 + float3(0.01, 0.015, 0.03) * gr) * mlight * 0.03 * (1.0 - cloud)
                       + float3(0.8, 0.84, 0.95) * cloud * mlight * 0.022;
        col = day + city + moonlit * night * float3(0.85, 0.9, 1.1);
        // the chosen place: a small soft ring round it
        if (S.i.w > 0.5) {
            float d = acos(clamp(dot(n, S.i.xyz), -1.0, 1.0)) / max(fp, 1e-5);
            float ring = exp(-sq((d - 3.2) / 0.9)) + 0.6 * exp(-sq(d / 1.1));
            col = mix(col, float3(1.0, 0.85, 0.55) * (0.08 + 0.4 * max(mu, 0.0)), ring * 0.8);
        }
    } else {
        // stars, and the Moon where it really is, unless Earth is in front of it
        col = S.j.z > 0.5 ? leSky(rd, S, F.pixelAngle, starTex, milkyTex) : SKY(p, rdw, false);
        float2 mh = leSphere(ro, rd, moonC, S.f.w);
        if (mh.x < mh.y && mh.x > 0.0) {
            float3 q = ro + rd * mh.x;
            float edge = smoothstep(0.0, 1.5, (S.f.w - length(cross(moonC - ro, rd))) / (F.pixelAngle * mh.x));
            col = mix(col, leMoonColor(q, moonC, S.j.y, s, S, moonTex, mapped), edge);
        }
        // the sun itself, with its glare (hidden at night if asked; its light still falls on everything)
        if (S.e.w > 0.5) {
            float ang = acos(clamp(dot(rd, s), -1.0, 1.0));
            float disk = smoothstep(LE_SUN_R + F.pixelAngle, LE_SUN_R - F.pixelAngle * 0.5, ang);
            col += float3(1.0, 0.96, 0.9) * (disk * 40.0 + 0.5 * exp(-ang / 0.012) + 0.08 * exp(-ang / 0.08));
        }
    }

    // the air: march through the shell, scattering sunlight blue where it's lit and orange along
    // the terminator, piling up into a bright rim at the limb, and glowing faintly by moonlight
    float2 shell = leSphere(ro, rd, float3(0.0), 1.0 + LE_ATMO);
    if (shell.x < shell.y && S.j.x > 0.0) {
        float t0 = max(shell.x, 0.0), t1 = min(shell.y, tEnd);
        const int N = 16;
        float dt = (t1 - t0) / float(N);
        float jit = hash13(float3(float2(p), 3.0));
        float3 scat = float3(0.0), aur = float3(0.0);
        float depth = 0.0;
        float cosTheta = dot(rd, s);
        // Rayleigh's phase, plus a forward lobe for the haze, which lights the rim from behind
        float phase = 0.75 * (1.0 + sq(cosTheta)) + 1.2 * exp((cosTheta - 1.0) * 12.0);
        bool auroraOn = S.h.y > 0.5 && S.g.y > 0.0;
        for (int i = 0; i < N; i++) {
            float3 x = ro + rd * (t0 + (float(i) + jit) * dt);
            float r = length(x);
            float a = r - 1.0;
            float dens = exp(-max(a, 0.0) / LE_SCALE_H);
            float mu = dot(x / r, s);
            float3 sunHere = leSunColor(mu);
            // the Moon's shadow darkens the air too, which is most of the light over the sea
            if (S.j.w > 0.5) sunHere *= 1.0 - leEclipse(x, s, moonC, S.j.y);
            float3 light = sunHere * phase + float3(0.2, 0.25, 0.4) * moonlight * 0.004;
            scat += dens * light * exp(-depth * LE_RAYLEIGH * 1.6) * dt;
            depth += dens * dt;
            if (auroraOn && a > 0.012) aur += leAuroraEmit(x, a, T, auroraTex, s) * dt;
        }
        col *= exp(-depth * LE_RAYLEIGH * 0.9);
        col += scat * LE_RAYLEIGH * 9.0 * S.j.x;
        col += aur * S.g.y * 18.0;
    }
    return finalize(col, p, F);
}
"""
}
