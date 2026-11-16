extension ShaderSource {
    static let eclipse = """
// ---------- per-frame: eclipse ----------
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
// S.m = eruption style (0 a lifting prominence and its bubble, 1 a bare, fast ejection), eruption scale

constant float EC_HEIGHT = 0.0098;   // the camera above the ground, moon radii (the horizon dips 8 degrees)
constant float EC_MOUNT = 0.012;     // the occluder's limb relief, sun radii
constant float EC_AXIS = 0.35;       // the sun's spin axis, radians from the sky's up

// The occluder's limb: mountains (+) and valleys (-), whole numbers of waves round the limb so
// there's no seam. Valleys let the last beads of sunlight through. Mirrors SceneParams.eclipseLimb.
static float ecLimb(float a) {
    float hills = 0.35 * sin(7.0 * a + 1.3) + 0.2 * sin(13.0 * a + 0.4) + 0.1 * sin(29.0 * a + 2.1);
    float notches = pow(max(sin(11.0 * a + 0.7), 0.0), 12.0) + 0.8 * pow(max(sin(17.0 * a + 2.9), 0.0), 12.0)
                  + 0.7 * pow(max(sin(23.0 * a + 4.4), 0.0), 16.0);
    return hills - 1.3 * notches;
}

// The share of the sun's disk (radius 1) left uncovered by a smooth disk of radius R, d away.
static float ecUncovered(float d, float R) {
    if (d >= 1.0 + R) return 1.0;
    if (d <= R - 1.0) return 0.0;
    float a1 = acos(clamp((d * d + 1.0 - R * R) / (2.0 * d), -1.0, 1.0));
    float a2 = acos(clamp((d * d + R * R - 1.0) / (2.0 * d * R), -1.0, 1.0));
    float k = max((-d + 1.0 + R) * (d + 1.0 - R) * (d - 1.0 + R) * (d + 1.0 + R), 0.0);
    return 1.0 - (a1 + R * R * a2 - 0.5 * sqrt(k)) / M_PI_F;
}

// The corona: a smooth K corona falling steeply from the limb, helmet streamers (broad over
// the active belts, narrowing into long rays) and polar plumes, with fine radial striations and
// density drifting outward in the solar wind. The streamers sway, swell and fade over minutes,
// sped up from the days the real ones take. Returns light.
static float3 ecCorona(float2 d, float r, float T, float size, float3 tint) {
    float a = atan2(d.y, d.x);
    float rs = 1.0 + (r - 1.0) / size;
    float u = log(rs);
    float2 cs = float2(cos(a), sin(a));
    float base = 0.42 * pow(rs, -14.0) + 0.16 * pow(rs, -3.0);
    // streamers: rooted along the equator (90 degrees from the axis), leaning with the field
    float str = 0.0;
    for (int k = 0; k < 12; k++) {
        float fk = float(k);
        float3 hk = hash33(float3(fk * 3.1, 7.7, 1.9));
        float h4 = fract(hk.x * 7.3 + hk.y * 3.1);
        float side = hk.x < 0.5 ? 0.0 : M_PI_F;
        float sway = 0.12 * sin(T * (0.006 + 0.004 * hk.z) + fk * 1.7) + 0.05 * sin(T * 0.017 + fk * 4.1);
        float a0 = EC_AXIS + 1.5708 + side + (hk.y - 0.5) * (k < 6 ? 1.2 : 2.6) + sway;
        float bend = ((hk.z - 0.5) * 0.9 + 0.25 * sin(T * 0.009 + fk * 2.3)) * (1.0 - 1.0 / rs);
        // a broad helmet near the limb pinching into a long thin stalk, swelling and thinning
        float breathe = 0.85 + 0.25 * sin(T * (0.011 + 0.006 * h4) + fk * 5.3);
        float w = (0.16 + 0.24 * hk.z) * (0.45 + 1.0 * exp(-(rs - 1.0) * 1.6)) * breathe;
        float da = wrapPi(a - a0 - bend);
        float reach = 1.0 + 1.3 * h4;              // how far it carries: lower falls off faster
        float amp = (0.25 + 0.5 * h4) * (0.75 + 0.35 * sin(T * (0.008 + 0.005 * hk.y) + fk * 3.7));
        str += exp(-sq(da / w)) * amp * pow(rs, -reach);
    }
    float stream = str;
    // polar plumes: thin straight rays fanning out of the poles, flickering slowly
    float pa = abs(cos(wrapPi(a - EC_AXIS)));
    float plumes = smoothstep(0.75, 0.97, pa) * pow(rs, -4.5) * (0.4 + 0.9 * smoothstep(0.45, 0.8, noise3(float3(cs * 30.0, 3.0 + T * 0.01))));
    float rays = 0.7 + 0.6 * noise3(float3(cs * 16.0, u * 0.8 + 4.0 + T * 0.004));
    float flow = 0.7 + 0.6 * noise3(float3(cs * 7.0, u * 5.0 - T * 0.05));
    float flow2 = 0.8 + 0.4 * noise3(float3(cs * 12.0, u * 7.0 - T * 0.09 + 9.0));
    float I = base * (0.85 + 0.3 * rays) + stream * mix(1.0, rays * flow * flow2, 0.7) * 0.6 + plumes * rays * 0.4 + 0.06 * pow(rs, -1.8);
    I *= exp(-sq((rs - 1.0) / 8.0));   // the outer corona thins into the sky, no edge
    // pearly near the limb, toward the corona color farther out, the hue drifting round it
    float drift = noise3(float3(cs * 2.0, 11.0 + T * 0.003));
    float3 pearl = float3(1.0, 0.96, 0.9);
    float3 c = mix(pearl, tint, smoothstep(1.1, 2.6, rs) * (0.65 + 0.5 * drift));
    c = mix(c, c * float3(1.05, 0.92, 1.1), smoothstep(0.4, 0.8, drift) * smoothstep(1.4, 3.0, rs));
    return c * I;
}

// One layer of craters `cell` apart: bowls with raised rims and ejecta aprons, `depth` deep
// (1 = fresh). Adds height, slope (in the uv plane), and the shadows the rims cast onto the
// floors for two lights, each given as a horizontal direction (xy) and the tangent of its
// elevation (z), w = penumbra.
static void ecCraters(float2 uv, float cell, float seed, float fp, float depth, float4 L1, float4 L2,
                      thread float& h, thread float2& g, thread float& sh1, thread float& sh2, thread float& alb) {
    if (cell * 0.12 < fp) return;     // the whole layer is under a pixel: just the albedo
    float2 cid = floor(uv / cell);
    float D = 0.26 * depth, RIM = 0.06 * depth;
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        float2 c = cid + float2(i, j);
        float3 hh = hash33(float3(c, seed));
        if (hh.z > 0.75) continue;
        float rad = cell * (0.12 + 0.38 * sq(hh.z / 0.75));
        float2 ctr = (c + 0.2 + 0.6 * hh.xy) * cell;
        float2 l = (uv - ctr) / rad;
        // worn, slightly polygonal rims rather than perfect circles
        float wob = noise3(float3(normalize(l + 1e-5) * 1.8, seed * 3.0 + c.x * 0.37 + c.y));
        float rho = length(l) * (1.0 + 0.14 * (wob - 0.5));
        if (rho > 2.6) continue;
        float k = smoothstep(0.8, 2.5, rad / fp);   // craters near a pixel across fade out
        float fin = D * (rho * rho - 1.0) + RIM, din = 2.0 * D * rho;
        float eo = exp(-(rho - 1.0) * 2.4);
        float fout = RIM * eo, dout = -2.4 * RIM * eo;
        float m = smoothstep(0.9, 1.1, rho);
        float f = mix(fin, fout, m), df = mix(din, dout, m);
        h += k * f * rad;
        g += k * df * l / max(rho, 1e-4);
        if (rho < 1.05) {
            // the rim on the light's side shades the floor below it
            float b1 = dot(l, L1.xy), b2 = dot(l, L2.xy);
            float t1 = -b1 + sqrt(max(b1 * b1 - rho * rho + 1.0, 0.0));
            float t2 = -b2 + sqrt(max(b2 * b2 - rho * rho + 1.0, 0.0));
            float drop = RIM + 0.02 * depth - f;
            float p1 = 0.04 + L1.w * t1, p2 = 0.04 + L2.w * t2;
            sh1 *= mix(1.0, smoothstep(-p1, p1, t1 * L1.z - drop), k);
            sh2 *= mix(1.0, smoothstep(-p2, p2, t2 * L2.z - drop), k);
        }
        // fresh craters: a bright apron streaked with rays
        if (hh.x > 0.86) {
            float ang = atan2(l.y, l.x);
            float streak = 0.5 + 0.8 * smoothstep(0.45, 0.8, noise3(float3(cos(ang) * 6.0, sin(ang) * 6.0, seed + c.x)));
            alb += 0.45 * k * depth * exp(-max(rho - 1.0, 0.0) * 1.1) * smoothstep(0.6, 1.0, rho) * streak;
        }
    }
}

// Distance to the nearest border of a jittered grid of cells one unit apart (roughly): the
// cracks in ice plates and in a cooling lava crust.
static float ecCellEdge(float2 x, float seed) {
    float2 i = floor(x), f = fract(x);
    float f1 = 8.0, f2 = 8.0;
    for (int yy = -1; yy <= 1; yy++)
    for (int xx = -1; xx <= 1; xx++) {
        float2 g = float2(xx, yy);
        float2 o = g + hash33(float3(i + g, seed)).xy - f;
        float dd = dot(o, o);
        if (dd < f1) { f2 = f1; f1 = dd; } else if (dd < f2) { f2 = dd; }
    }
    return 0.5 * (sqrt(f2) - sqrt(f1));
}

// The far rims standing along the horizon, radians above the smooth horizon, by azimuth.
static float ecSkyline(float az, float relief) {
    float2 c = float2(cos(az), sin(az));
    float mesa = smoothstep(0.35, 0.75, fbm(float3(c * 2.6, 1.7)));
    return (0.003 + 0.016 * mesa + 0.006 * fbm(float3(c * 11.0, 5.0))) * relief + 0.002 * noise3(float3(c * 40.0, 2.0));
}

// Rings' opacity at r planet radii: dense middle ring, a dark gap, a fainter outer ring.
static float ecRing(float rr, float fpR) {
    if (rr < 1.28 || rr > 2.4) return 0.0;
    float fine = 1.0 - smoothstep(0.004, 0.012, fpR);
    float a = 0.55 + 0.25 * sin(rr * 41.0) + 0.15 * sin(rr * 113.0 + 1.0) * fine;
    a *= smoothstep(1.28, 1.42, rr) * smoothstep(2.4, 2.22, rr);
    a *= mix(0.35, 1.0, smoothstep(1.42, 1.68, rr));                 // the thin inner ring
    a *= 1.0 - 0.85 * exp(-sq((rr - 1.97) / 0.03));                   // the gap
    a *= mix(1.0, 0.6, smoothstep(2.0, 2.06, rr));                    // the outer ring is fainter
    return saturate(a) * 0.9;
}

// Air mass along a ray at elevation sine y: 1 overhead, growing toward the horizon.
static float ecAirmass(float y) {
    float yy = max(y, 0.0);
    return 1.0 / (yy + 0.065 * exp(-yy * 10.0) + 0.012);
}

fragment float4 eclipseFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float W = F.camRight.w, H = F.camUp.w;
    float T = F.time;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5)) * F.screenScale;
    float th = S.i.x, pitch = S.i.y;
    float3 rc = normalize(float3(q * th, 1.0));
    float cp = cos(pitch), sp = sin(pitch);
    float3 rd = float3(rc.x, rc.y * cp + rc.z * sp, -rc.y * sp + rc.z * cp);
    float pixA = 2.0 * th * F.screenScale / H;       // radians per pixel, near the middle

    float3 sunD = S.a.xyz;
    float ts = S.a.w;
    float3 sx = normalize(cross(float3(0.0, 1.0, 0.0), sunD)), sy = cross(sunD, sx);
    float2 o = S.b.xy;
    float Ro = S.b.z;
    float eCam = S.b.w, gain = S.j.z, logE = S.j.w;
    float adapt = gain / 2.5;                          // how far the eye has opened since full sun
    float coronaVis = smoothstep(-2.4, -4.3, logE);
    float starVis = smoothstep(-2.6, -4.5, logE);
    float glareAmp = smoothstep(-5.6, -4.0, logE) * (0.6 + 2.4 * smoothstep(-3.5, 0.0, logE));
    float3 sunCol = float3(1.0, 0.94, 0.85);
    int body = int(S.l.z + 0.5), world = int(S.l.w + 0.5);

    // ---- air: what it scatters toward us along this ray, and what it lets through ----
    float dens = S.k.w;
    bool air = dens > 0.0;
    float3 airC = S.k.rgb;
    float haze = S.l.x, clouds = S.l.y;
    // extinction per unit air mass: the gas scatters its sky color out of the beam; haze is
    // mostly gray, but absorbs the sky color's complement (Titan's smog swallows blue, which is
    // why it glows orange)
    float3 beta = airC * (1.0 - 0.5 * saturate(haze)) + 0.6 * haze * mix(float3(1.0), max(1.15 - airC, 0.0), 0.7);
    float3 Tview = float3(1.0), skyIn = float3(0.0), sunT = float3(1.0), sunset = float3(1.0);
    float shadeDeep = 0.0;
    float sunLight = gain * eCam;                                  // the adapted sunlight still arriving
    if (air) {
        float mV = ecAirmass(rd.y), mS = ecAirmass(sunD.y);
        Tview = exp(-dens * 0.3 * mV * beta);
        sunT = exp(-dens * 0.13 * mS * beta);
        float cosS = dot(rd, sunD);
        // the haze's own color, and the forward glow round the sun, tinted toward the
        // complement of the sky (fine dust throws its blue forward, as on Mars)
        float3 hazeCol = mix(airC, float3(1.0, 0.95, 0.88), 0.35);
        float3 aureole = mix(float3(1.0), normalize(max(1.15 - airC, 0.05)) * 1.5, 0.55);
        float near = exp((cosS - 1.0) / 0.04);
        float phaseR = 0.75 * (1.0 + cosS * cosS);
        float phaseM = 0.3 + 3.0 * near + 0.6 * exp((cosS - 1.0) / 0.3);
        float3 scat = (airC * phaseR + haze * mix(hazeCol, aureole, near) * phaseM) / (beta + 1e-3);
        skyIn = sunLight * sunT * scat * (1.0 - Tview) * 0.5;
        // in the shadow, sunlight scattered in from beyond its edge: a sunset glow all round the
        // horizon (light that's crossed a long path of air, so reddened), deep blue-violet above
        shadeDeep = 1.0 - smoothstep(-2.6, -0.9, logE);
        // its color: a blue (molecular) sky's glow has lost its blue on the long path, so it's
        // orange; a hazy, colored sky's glow is that color deepened
        float blueness = saturate(airC.b - airC.r);
        sunset = mix(pow(airC, float3(1.6)), float3(1.0, 0.42, 0.12), blueness);
        sunset /= max(max(sunset.r, sunset.g), max(sunset.b, 1e-3));
        float yy = max(rd.y, 0.0);
        float band = 0.75 * exp(-yy / 0.035) + 0.25 * exp(-yy / 0.12);
        float3 low = mix(sunset, sunset * float3(1.0, 0.6, 0.5), exp(-yy / 0.015) * 0.6);   // reddest right at the horizon
        float3 above = airC * float3(0.6, 0.45, 1.2);
        skyIn += gain * 0.0045 * min(dens, 2.0) * shadeDeep * (low * band * 1.2 + above * 0.22 * (1.0 - band));
        // and the air drowns the fainter stars
        float lum = dot(skyIn, float3(0.2126, 0.7152, 0.0722));
        starVis *= exp(-dens * 0.2 * mV) / (1.0 + lum * 60.0);
    }

    // ---- sky ----
    float sd = dot(rd, sunD);
    float2 d = float2(dot(rd, sx), dot(rd, sy)) / max(sd, 1e-3) / ts;
    if (sd <= 0.0) d = float2(1e4);
    float r = length(d);
    float px = pixA / ts;                              // one pixel in sun radii
    float3 col = SKY(p, octDecode(dirTex.read(p).xy), false) * starVis;

    // the body in the sky, lit by the sun from beside it, so a crescent
    float tp = S.f.w;
    float pHit = 0.0;
    float3 planetCol = S.g.rgb;
    if (tp > 0.0) {
        float3 Pc = S.f.xyz;
        float Rp = tp / sqrt(1.0 + tp * tp);
        float2 ps = sphereSpan(-Pc, rd, Rp);
        float bp = length(cross(rd, Pc));               // ray's closest approach to its center
        bool hitP = ps.x < ps.y && ps.x > 0.0;
        float3 rn = normalize(float3(0.6, 1.0, -0.1));  // the ring plane, the planet's equator
        if (hitP) {
            float3 Pp = rd * ps.x;
            float3 N = normalize(Pp - Pc);
            float3 ax = body == 2 ? rn : normalize(float3(-0.25, 1.0, -0.1));
            float lat = dot(N, ax);
            float fpP = pixA / Rp;
            float warp = fbm(N * 3.0 + 2.0) - 0.5;
            float mu = saturate(dot(N, -rd));
            float nl = dot(N, sunD);
            float3 alb;
            float rim = 0.6;
            if (body == 4) {
                // a cratered moon: patchy maria and highlands, crater rims, no air
                float big = fbm(N * 2.2 + 4.0);
                float cr = ecCellEdge(float2(atan2(N.x, N.z), lat) * 7.0, 3.0);
                float rimL = exp(-sq(cr / max(0.06, fpP * 10.0)));
                alb = planetCol * (0.55 + 0.6 * smoothstep(0.35, 0.65, big) + 0.25 * (fbmLOD(N * 16.0, fpP * 16.0) - 0.5) + 0.2 * rimL);
                rim = 0.0;
            } else {
                float lt = lat + warp * (body == 1 ? 0.1 : 0.06);
                float bands = 0.5 + 0.5 * sin(lt * 26.0 + 2.0 * sin(lt * 7.0 + 1.0));
                float fine = fbmLOD(float3(N.xz * 18.0, lt * 60.0), fpP * 18.0);
                if (body == 1) {
                    // ivory zones and rust belts, curling where they meet, darker toward the poles
                    float tz = smoothstep(0.3, 0.7, bands + (fine - 0.5) * 0.7);
                    alb = mix(planetCol * float3(0.72, 0.48, 0.32), planetCol, tz);
                    alb *= 1.0 - 0.35 * smoothstep(0.6, 0.95, abs(lat));
                } else if (body == 2) {
                    alb = planetCol * (0.85 + 0.2 * bands + 0.12 * (fine - 0.5));
                } else if (body == 3) {
                    alb = planetCol * (0.93 + 0.06 * bands + 0.04 * (fine - 0.5));
                    rim = 1.0;
                } else {
                    alb = planetCol * (0.62 + 0.5 * bands + 0.25 * (fine - 0.5));
                    alb = mix(alb, alb * float3(1.15, 0.95, 0.8), smoothstep(0.6, 0.85, bands) * 0.25);   // warmer light zones
                }
            }
            float day = body == 4 ? smoothstep(-0.02, 0.1, nl) * saturate(nl + 0.05)
                                  : smoothstep(-0.06, 0.25, nl) * (0.35 + 0.65 * saturate(nl));
            if (body == 2) {
                // the rings' shadow across the planet
                float den = dot(sunD, rn);
                if (abs(den) > 1e-3) {
                    float tS = dot(Pc - Pp, rn) / den;
                    if (tS > 0.0) day *= 1.0 - 0.85 * ecRing(length(Pp + sunD * tS - Pc) / Rp, fpP);
                }
            }
            float3 pc = alb * day * 1.1 * (0.5 + 0.5 * pow(mu, 0.4)) * pow(adapt, 0.2);
            // a thin haze lights up along the sunward limb
            pc += mix(planetCol, float3(0.7, 0.85, 1.0), 0.5) * pow(1.0 - mu, 3.0) * smoothstep(-0.2, 0.4, nl) * rim;
            // the night side, faintly lit by our moon
            pc += alb * 0.0003 * adapt * (1.0 - day);
            pHit = smoothstep(Rp + pixA * 1.0, Rp - pixA * 1.0, bp);
            col = mix(col, pc, pHit);
        } else if (body != 4) {
            // haze glowing just off the sunward limb
            float off = (bp - Rp) / Rp;
            float3 Nl = normalize(rd * dot(rd, Pc) - Pc);
            col += mix(planetCol, float3(0.6, 0.8, 1.0), 0.5) * exp(-max(off, 0.0) / 0.012) * smoothstep(-0.2, 0.5, dot(Nl, sunD)) * 0.25;
        }
        if (body == 2) {
            // the rings: in front of the planet or beside it, hidden where it stands in front
            float den = dot(rd, rn);
            float tR = abs(den) > 1e-4 ? dot(Pc, rn) / den : -1.0;
            if (tR > 0.0 && (!hitP || tR < ps.x)) {
                float3 R3 = rd * tR;
                float fpR = pixA * tR / Rp / max(abs(den), 0.05);
                float ra = ecRing(length(R3 - Pc) / Rp, fpR);
                if (ra > 0.0) {
                    // lit face when the sun and we are on the same side; the far side glows dimly
                    // where thin; dark inside the planet's shadow
                    bool litFace = dot(rn, sunD) * dot(rn, -rd) > 0.0;
                    float2 sh = sphereSpan(R3 - Pc, sunD, Rp);
                    float inShadow = (sh.x < sh.y && sh.y > 0.0) ? 0.03 : 1.0;
                    float lightR = litFace ? 0.35 + 0.65 * abs(dot(rn, sunD)) : 0.6 * (1.0 - ra);
                    float grain = 0.85 + 0.3 * noise3(float3(length(R3 - Pc) / Rp * 60.0, 1.0, 2.0));
                    float3 rcol = planetCol * float3(1.0, 0.95, 0.86) * grain * lightR * inShadow * 1.1 * pow(adapt, 0.2);
                    col = mix(col, rcol, ra);
                    pHit = max(pHit, ra);
                }
            }
        }
    }

    float3 sky = float3(0.0);
    if (r < 1.0 + 20.0 * S.c.w) {   // well past where the corona has faded out
        // corona, behind everything round the sun
        float3 cor = ecCorona(d, max(r, 1.0), T, S.c.w, S.c.rgb) * S.g.w;
        sky += cor * mix(0.05, 1.0, coronaVis) * smoothstep(1.0 - px, 1.0 + px, r);

        float h = r - 1.0;
        float ang = atan2(d.y, d.x);
        float3 promCol = S.d.rgb;
        float promVis = mix(0.1, 1.0, sqrt(coronaVis));
        float amt = S.d.w;
        // the chromosphere: a thin pink shell, a fringe of spicules over it
        if (h > -px && h < 0.08) {
            float2 cs = float2(cos(ang), sin(ang));
            float jets = smoothstep(0.35, 0.8, noise3(float3(cs * 140.0, h / 0.01 - T * 0.05)));
            float top = 0.012 + 0.012 * noise3(float3(cs * 60.0, T * 0.02));
            float chrom = exp(-max(h, 0.0) / 0.006) * 0.8 + smoothstep(top, top * 0.3, h) * jets * 0.6;
            sky += promCol * chrom * smoothstep(-px, px, h) * 2.5 * promVis;
        }
        // prominences round the limb: each grows up out of the chromosphere, leans and twists
        // as it stands, drains and fades, and another forms elsewhere
        if (amt > 0.0 && h < 0.45 && h > -px) {
            float prom = 0.0;
            for (int i = 0; i < 7; i++) {
                float fi = float(i);
                float life = 220.0 + 200.0 * hash13(float3(fi, 11.0, 2.0));
                float cyc = T / life + hash13(float3(fi, 12.0, 2.0));
                float gen = floor(cyc), age = fract(cyc);
                if (hash13(float3(fi, gen, 19.0)) > amt * 0.6) continue;
                float a0 = 6.2831853 * hash13(float3(fi, gen, 13.0));
                float Lp = 0.09 + 0.13 * hash13(float3(fi, gen, 14.0));
                float Hp = (0.1 + 0.16 * hash13(float3(fi, gen, 15.0))) * (0.55 + 0.6 * smoothstep(0.0, 0.6, age));
                float lean = (hash13(float3(fi, gen, 17.0)) - 0.5) * 0.8 + 0.35 * sin(T * 0.015 + fi * 2.1);
                float s = wrapPi(ang - a0) - lean * h;
                if (abs(s) > Lp * 1.4 || h > Hp * 1.7) continue;
                float vis = smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.8, 1.0, age));
                // draining: late in its life the upper part thins first
                vis *= 1.0 - smoothstep(0.7, 1.0, age) * smoothstep(0.0, Hp, h) * 0.7;
                prom += prominence(float2(s, h), Lp, Hp, hash13(float3(fi, gen, 16.0)), fi * 5.3 + gen * 1.7, T, px) * vis;
            }
            sky += promCol * prom * (4.0 + amt) * promVis;
        }
        // surges and limb flares: a jet of chromospheric plasma shot up along the field, stalling
        // and draining back, with a brief white-hot brightening at its foot as it starts
        if (amt > 0.0 && h < 0.6 && h > -px) {
            for (int k = 0; k < 2; k++) {
                float per = 75.0 + 30.0 * float(k);
                float ph = T / per + 0.43 * float(k);
                float n = floor(ph), f = fract(ph) * per / 42.0;
                if (f >= 1.0 || hash13(float3(n, float(k), 41.0)) > 0.2 + 0.4 * min(amt, 1.5)) continue;
                float sa = 6.2831853 * hash13(float3(n, float(k), 42.0));
                float seed = hash13(float3(n, float(k), 43.0)) * 50.0;
                float2 L = float2(wrapPi(ang - sa), h);
                float top = (0.16 + 0.24 * hash13(float3(seed, 2.0, 1.0))) * pow(sin(3.14159265 * f), 0.8);
                float lean = (hash13(float3(seed, 3.0, 1.0)) - 0.5) * 0.6;
                float x = L.x - lean * L.y;
                float wid = 0.012 + 0.12 * L.y;
                if (abs(x) < wid * 3.0 + 3.0 * px && L.y < top * 1.3 + 0.05) {
                    float xa = x / wid;
                    float topk = top * (0.6 + 0.5 * noise3(float3(xa * 1.5, seed, f * 3.0)));
                    float env = exp(-xa * xa * 0.7) * smoothstep(topk + 0.03, topk - 0.03, L.y);
                    float flowV = f < 0.5 ? -0.3 : 0.2;
                    float thr = threads(x, L.y / 0.03 + T * flowV, 0.006, px, seed);
                    thr *= 0.4 + 0.9 * smoothstep(0.3, 0.7, noise3(float3(xa * 0.8, L.y / 0.05 + T * flowV * 0.5, seed + 4.0)));
                    float bright = smoothstep(0.0, 0.05, f) * (1.0 - smoothstep(0.85, 1.0, f));
                    sky += promCol * env * thr * 2.2 * bright * promVis;
                }
                float flash = exp(-dot(L, L) / 0.006) * (1.0 - smoothstep(0.0, 0.12, f)) * smoothstep(0.0, 0.01, f);
                sky += mix(promCol, float3(1.0, 0.95, 0.9), 0.6) * flash * 2.5 * promVis;
            }
        }

        // eruption: a big prominence lifts off, swelling into a loop of twisted threads, ahead of a
        // faint expanding bubble of corona (a coronal mass ejection); or a bare, fast ejection
        if (S.h.z > 0.0) {
            float ea = S.h.x, fp = S.h.y, seed = S.h.w;
            bool bare = S.m.x > 0.5;
            float sc = S.m.y > 0.0 ? S.m.y : 1.0;
            float2 L = float2(wrapPi(ang - ea), h);
            float rise = max(fp - 0.12, 0.0) / 0.88;
            float Hh = 0.14 + 0.05 * smoothstep(0.0, 0.12, fp) + 2.4 * sc * pow(rise, 1.6);
            float Wp = 0.16 + 0.06 * smoothstep(0.1, 0.5, fp) + 0.3 * sc * rise;
            if (!bare && abs(L.x) < Wp * 1.5 + Hh * 0.4 + 0.08 && L.y < Hh * 1.5 + 0.08 && L.y > -px) {
                float2 Lw = L + noise2(float3(L * 2.0 / (0.15 + Hh), seed + T * 0.01)) * (0.01 + 0.18 * Hh) * smoothstep(0.0, 0.3, L.y / Hh);
                float2 en = Lw / float2(Wp, Hh);
                float e = length(en);
                float uu = atan2(max(en.y, 0.0), en.x);
                float spacing = 0.006 * (1.0 + 5.0 * rise);
                float rope = smoothstep(0.45 - 0.2 * rise, 0.72 - 0.2 * rise, e) * smoothstep(1.15 + 0.1 * rise, 0.9 - 0.1 * rise, e);
                float thr = threads(e * Hh, uu * 6.0 - T * 0.03, spacing, px, seed);
                float twist = threads(e * Hh + 0.3 * Hh * sin(uu * 3.0), uu * 3.0, spacing * 1.5, px, seed + 9.0);
                float wisps = smoothstep(0.3 + 0.15 * rise, 0.62, fbm(float3(Lw / (0.1 + Hh) * 2.0, seed)));
                float loose = smoothstep(0.0, 0.4, rise);
                float em = rope * mix(0.6 * thr + 0.4 * twist, 1.0, 0.5 * loose) * mix(1.0, wisps, smoothstep(0.2, 0.6, fp));
                em *= smoothstep(0.0, 0.015, L.y) * 1.6 / (1.0 + 2.5 * Hh);
                float hang = 1.0 - smoothstep(0.08, 0.3, fp);
                if (hang > 0.0) em += prominence(L, Wp * 0.9, Hh * 0.95, 0.4, seed, T, px) * hang * 1.5;
                if (fp > 0.35 && L.y < 0.2) {
                    float lx = abs(L.x) - Wp * 0.8;
                    em += exp(-lx * lx / 8e-4) * threads(L.x, L.y / 0.015 + T * 0.4, 0.006, px, seed + 2.0)
                          * smoothstep(0.2, 0.04, L.y) * smoothstep(0.35, 0.55, fp) * 0.6;
                }
                sky += mix(promCol, float3(1.0, 0.8, 0.85), 0.15 * loose) * em * S.h.z * promVis * 4.0;
            }
            // the bubble of corona: a soft bright front over a darker cavity, with a knot of
            // erupted prominence material trailing it
            float2 nrm = float2(cos(ea), sin(ea)), tg = float2(-nrm.y, nrm.x);
            float2 Lc = float2(dot(d, tg), dot(d, nrm));
            float rF = 1.1 + (bare ? 6.0 : 4.5) * sc * pow(max(fp - (bare ? 0.02 : 0.08), 0.0), bare ? 1.0 : 1.15);
            float hw = bare ? 0.5 : 0.42;
            float sw = sin(hw);
            float rB = rF / (1.0 + sw), rb = rB * sw;
            if (Lc.y > 0.0 && abs(Lc.x) < rb * 1.6 + 0.2 && Lc.y < rF + rb * 0.6) {
                float2 Lw = Lc + noise2(float3(Lc * 1.5 / rb, seed + T * 0.01)) * rb * 0.18;
                float2 rel = Lw - float2(0.0, rB);
                float rr = length(rel);
                float phi = atan2(rel.x, rel.y);
                float dB = rr - rb * (1.0 + 0.15 * (noise3(float3(rel / max(rr, 1e-4) * 1.3, seed)) - 0.5));
                float thk = 0.4 * rb;
                float shell = exp(-sq(max(dB, 0.0) / (thk * 0.8))) * exp(min(dB, 0.0) / thk);
                float lead = 0.25 + 0.75 * smoothstep(-0.6, 0.9, cos(phi));
                float fib = mix(1.0, threads(dB + 0.1 * rb * noise3(float3(phi * 2.0, seed, 3.0)), phi * 4.0, 0.07 * rb, px, seed), 0.25);
                float clumps = 0.65 + 0.5 * smoothstep(0.25, 0.75, noise3(float3(Lw * 2.5 / rb, seed + 1.0)));
                float cav = smoothstep(0.0, -0.4 * rb, dB) * smoothstep(0.0, 0.1, fp);
                float fade = smoothstep(0.03, 0.2, fp) / (0.4 + 0.6 * rF);
                sky *= 1.0 - 0.3 * cav * S.h.z;
                sky += mix(float3(1.0, 0.97, 0.94), S.c.rgb, 0.4) * shell * lead * fib * clumps * fade * S.h.z * (bare ? 0.9 : 0.6) * S.g.w * mix(0.1, 1.0, coronaVis);
                if (bare) {
                    float2 cw = (rel + float2(0.0, rb * 0.4)) / rb;
                    cw += noise2(float3(cw * 3.0, seed + 7.0)) * 0.25;
                    float core = exp(-dot(cw, cw * float2(1.0, 1.6)) / 0.05) * smoothstep(0.35, 0.7, fbm(float3(cw * float2(5.0, 2.5), seed + 4.0)));
                    sky += promCol * core * fade * S.h.z * 3.0 * promVis;
                }
            }
        }

        // the photosphere, where the occluder leaves it uncovered
        float limbD = 1.0 - 0.55 * (1.0 - sqrt(max(1.0 - r * r, 0.0)));
        sky += sunCol * gain * 14.0 * limbD * smoothstep(1.0 + px, 1.0 - px, r);

        // the occluder: its night side faces us, dimly lit by the planet
        float2 dv = d - o;
        float ro = length(dv);
        float phiO = atan2(dv.y, dv.x);
        float Rl = Ro + EC_MOUNT * ecLimb(phiO);
        float cover = smoothstep(Rl + px, Rl - px, ro);
        if (cover > 0.0) {
            float z = sqrt(max(1.0 - sq(ro / Ro), 0.0));
            float3 N = float3(dv / Ro, z);
            float shine = saturate(dot(N, normalize(float3(-0.9, -0.1, 0.4)))) * (0.6 + 0.5 * fbm(float3(dv * 3.0, 4.0)));
            float3 night = planetCol * shine * 0.0035 * adapt * S.i.w * step(0.0, tp);
            sky = mix(sky, night, cover);
            col *= 1.0 - cover;
        }

        // Baily's beads: the last sunlight shining through the limb's valleys, each with a glow
        if (length(o) < 1.0 && abs(ro - Ro) < 0.5 && r < 1.5) {
            float glow = 0.0;
            for (int k = -6; k <= 6; k++) {
                float a = phiO + float(k) * 0.022;
                float2 u2 = float2(cos(a), sin(a));
                float b = dot(o, u2);
                float ts2 = -b + sqrt(max(b * b - dot(o, o) + 1.0, 0.0));
                float Rk = Ro + EC_MOUNT * ecLimb(a);
                float gap = ts2 - Rk;
                if (gap <= 0.0) continue;
                float2 pt = o + u2 * (Rk + gap * 0.5);
                float dist2 = length_squared(d - pt);
                glow += saturate(gap / 0.012) * (exp(-dist2 / 0.0012) * 3.0 + exp(-dist2 / 0.015) * 0.6);
            }
            sky += sunCol * glow * smoothstep(-5.6, -4.0, logE);
        }
    }
    col += sky * (1.0 - pHit);

    // everything beyond the air is dimmed (and reddened low down) by it, and its glow added
    if (air) {
        col = col * Tview + skyIn;
        // a thin cloud deck drifting overhead, lit by the sun (silver toward it) or, at totality,
        // from below by the horizon's glow
        if (clouds > 0.0 && rd.y > 0.0) {
            float yy = max(rd.y, 0.035);
            float2 cpl = rd.xz / yy * 0.6 + float2(T * 0.012, T * 0.005);
            float fpc = pixA * 0.6 / (yy * yy);
            float cdn = fbmLOD(float3(cpl * 3.0, 2.0), fpc * 3.0);
            float cdn2 = fbmLOD(float3(cpl * 9.0 + 4.0, 5.0 + T * 0.01), fpc * 9.0);
            float cov = smoothstep(0.62 - 0.32 * clouds, 0.9 - 0.2 * clouds, cdn + 0.25 * (cdn2 - 0.5));
            cov *= smoothstep(0.0, 0.1, rd.y) * clouds * 0.85;
            float cosS = dot(rd, sunD);
            float3 lit = sunLight * sunT * (0.3 + 1.6 * exp((cosS - 1.0) / 0.06)) * mix(float3(1.0), airC, 0.15)
                       + skyIn * 0.6 + gain * 0.008 * min(dens, 2.0) * shadeDeep * sunset * (0.3 + 0.7 * exp(-rd.y / 0.15));
            col = mix(col, lit * 0.8, cov);
        }
    }

    // ---- the ground we stand on ----
    if (S.e.w > 0.5) {
        float3 Cm = float3(0.0, -(1.0 + EC_HEIGHT), 0.0);
        float2 gs = sphereSpan(-Cm, rd, 1.0);
        float dip = acos(1.0 / (1.0 + EC_HEIGHT));
        float el = asin(clamp(rd.y, -1.0, 1.0));
        float az = atan2(rd.x, rd.z);
        float relief = world == 1 ? 0.5 : (world == 2 ? 0.6 : 1.0);
        float sky_top = -dip + ecSkyline(az, relief);
        bool hitG = gs.x < gs.y && gs.x > 0.0;
        float edgeAA = pixA * 0.8;
        float ridge = hitG ? 0.0 : smoothstep(sky_top + edgeAA, sky_top - edgeAA, el);
        float3 gcol = S.e.rgb;
        // light: the sun as uncovered from each spot (the occluder's shadow has a sharp-cored
        // umbra drifting over the ground), the planet's crescent, the corona's faint glow, and
        // with air the sky's own light
        float3 Lpl = normalize(S.f.xyz + 0.6 * tp * normalize(sunD - S.f.xyz * dot(sunD, S.f.xyz)));
        float plI = tp > 0.0 ? S.i.w * 0.6 * adapt : 0.0;
        float coI = 0.006 * S.g.w * adapt * (air ? 0.5 : 1.0);
        float resid = max(eCam - ecUncovered(length(o), Ro), 0.0);
        float3 plCol = mix(planetCol, float3(0.8, 0.9, 1.0), 0.25);
        float3 coCol = mix(float3(1.0, 0.97, 0.94), S.c.rgb, 0.4);
        float3 skyAmb = air ? sunLight * sunT * airC * 0.12 * min(dens, 2.0) + gain * 0.004 * min(dens, 2.0) * shadeDeep * sunset : float3(0.0);
        float3 sunTint = sunCol * sunT;
        // the ground beyond a short way blends into the air's glow (aerial perspective)
        float3 sunAt = float3(0.0);
        if (hitG) {
            float t = gs.x;
            float3 G = rd * t;
            float3 Ns = normalize(G - Cm);
            float mu = saturate(dot(Ns, -rd));
            float fp = pixA * t / max(mu, 0.04);
            float2 uv = G.xz;
            // the lights' horizontal directions and elevations, with their penumbrae
            float2 sh2 = normalize(sunD.xz + 1e-5), ph2 = normalize(Lpl.xz + 1e-5);
            float4 L1 = float4(sh2, sunD.y / length(sunD.xz), ts * 0.7);
            float4 L2 = float4(ph2, max(Lpl.y, 0.02) / length(Lpl.xz), tp * 0.5);
            float hgt = 0.0, sS = 1.0, sP = 1.0, bright = 0.0;
            float2 grad = float2(0.0);
            // each world wears its own relief: fresh craters on rock and basalt, shallow ones on
            // ice, a few worn ones between dunes on the desert
            float depth = world == 1 ? 0.45 : (world == 2 ? 0.35 : 1.0);
            ecCraters(uv, 0.05, 1.0, fp, depth, L1, L2, hgt, grad, sS, sP, bright);
            if (world != 2) ecCraters(uv, 0.016, 2.0, fp, depth, L1, L2, hgt, grad, sS, sP, bright);
            if (world == 0 || world == 3) {
                ecCraters(uv, 0.0055, 3.0, fp, depth, L1, L2, hgt, grad, sS, sP, bright);
                ecCraters(uv, 0.0018, 4.0, fp, depth, L1, L2, hgt, grad, sS, sP, bright);
            }
            // gentle undulation and grit (smoother on ice)
            float e2 = 0.0004;
            float n0 = fbmLOD(float3(uv * 90.0, 1.0), fp * 90.0);
            float nx = fbmLOD(float3((uv + float2(e2, 0.0)) * 90.0, 1.0), fp * 90.0);
            float nz = fbmLOD(float3((uv + float2(0.0, e2)) * 90.0, 1.0), fp * 90.0);
            grad += float2(nx - n0, nz - n0) / e2 * (world == 1 ? 0.0005 : 0.0012);
            float alb = (0.72 + 0.5 * (n0 - 0.5) + 0.35 * (fbmLOD(float3(uv * 14.0, 7.0), fp * 14.0) - 0.5)) * (1.0 + bright);
            float3 tintG = float3(1.0);
            float3 glowG = float3(0.0);
            float spec = 0.0;
            if (world == 2) {
                // dunes: long asymmetric ridges (gentle windward, steep lee side), rippled
                float2 wd = normalize(float2(0.8, 0.6));
                float kd = 6.2831853 / 0.009;
                float ph = dot(uv, wd) * kd + 3.0 * fbm(float3(uv * 25.0, 3.0));
                float kf = smoothstep(0.7, 2.0, 0.009 / max(fp, 1e-6) / 2.0);
                grad += wd * 0.00028 * kd * (cos(ph) + 0.45 * cos(2.0 * ph)) * kf;
                float kr = 6.2831853 / 0.0011;
                float phr = dot(uv, float2(-0.5, 0.86)) * kr + 2.0 * noise3(float3(uv * 300.0, 1.0));
                grad += float2(-0.5, 0.86) * 0.00002 * kr * cos(phr) * smoothstep(0.7, 2.0, 0.0011 / max(fp, 1e-6) / 2.0);
                alb *= 0.9 + 0.15 * sin(ph + 0.8) * kf;
                tintG = mix(float3(1.0), float3(1.08, 0.92, 0.85), smoothstep(0.4, 0.7, n0));
            } else if (world == 1) {
                // ice plates broken by reddish-brown cracks and ridges, glinting in the sun
                float ce = ecCellEdge(uv * 70.0, 6.0), ce2 = ecCellEdge(uv * 22.0, 9.0);
                float w1 = max(0.05, fp * 70.0 * 1.2), w2 = max(0.03, fp * 22.0 * 1.2);
                float line = exp(-sq(ce / w1)) * (0.05 / w1) + exp(-sq(ce2 / w2)) * (0.03 / w2) * 1.3;
                tintG = mix(float3(1.0), float3(0.62, 0.36, 0.3), saturate(line) * 0.8);
                alb = 0.8 + 0.25 * (n0 - 0.5);
                spec = 1.0;
            } else if (world == 3) {
                // lava glowing through cracks in the cooled crust: faint in sunlight, plain at totality
                // the cracks wander, and only some stretches of them are still hot
                float2 wv = uv * 40.0 + 0.6 * float2(fbm(float3(uv * 20.0, 1.0)), fbm(float3(uv * 20.0, 4.0)));
                float ce = ecCellEdge(wv, 12.0);
                float w = max(0.025, fp * 40.0 * 1.2);
                float crack = exp(-sq(ce / w)) * (0.025 / w) + 0.25 * exp(-sq(ce / (w * 2.5))) * (0.025 / w);
                float hot = smoothstep(0.45, 0.7, noise3(float3(uv * 60.0, 8.0)));
                float flick = 0.7 + 0.3 * noise3(float3(uv * 30.0, T * 0.3));
                glowG = float3(1.0, 0.3, 0.05) * crack * hot * flick * 0.025 * adapt * (1.0 - smoothstep(0.0004, 0.0015, fp));
                alb *= 1.0 - 0.4 * saturate(crack);
            }
            alb *= 0.85 + 0.3 * noise3(float3(uv * 900.0, 3.0)) * (1.0 - smoothstep(0.3, 0.8, fp * 900.0)) * (world == 1 ? 0.3 : 1.0);
            float3 ex = normalize(float3(1.0, 0.0, 0.0) - Ns * Ns.x), ez = normalize(float3(0.0, 0.0, 1.0) - Ns * Ns.z);
            float3 N = normalize(Ns - grad.x * ex - grad.y * ez);
            float muV = saturate(dot(N, -rd));
            // regolith: between Lambert and the flat look of the Moon's own surface
            float nlS = dot(N, sunD), nlP = dot(N, Lpl);
            float ls = saturate(nlS) * (0.55 + 0.9 / (saturate(nlS) + muV + 0.3));
            float lp = saturate(nlP) * (0.55 + 0.9 / (saturate(nlP) + muV + 0.3));
            float2 oG = o - float2(dot(G, sx), dot(G, sy)) * S.i.z;
            float frac = max(ecUncovered(length(oG), Ro) + resid, 0.0);
            float glint = spec * pow(saturate(dot(reflect(rd, N), sunD)), 40.0) * 2.0;
            // light bounced off the sunlit plains around fills the shadows a little
            float3 light = sunTint * gain * frac * (ls * sS * 0.75 + 0.07 * (0.6 + 0.4 * Ns.y) + glint * sS)
                         + plCol * plI * lp * sP
                         + coCol * coI * (0.4 + 0.6 * saturate(nlS + 0.3))
                         + skyAmb * (0.5 + 0.5 * N.y);
            float3 gc = gcol * tintG * alb * light + glowG;
            if (air) {
                float3 TG = exp(-dens * 0.3 * beta * t * 25.0);
                gc = gc * TG + skyIn * (1.0 - TG);
            }
            col = gc;
        } else if (ridge > 0.0) {
            // the far rims: their faces toward us in shadow, crests catching the light
            float3 G = float3(sin(az), 0.0, cos(az)) * sqrt(2.0 * EC_HEIGHT) + float3(0.0, -EC_HEIGHT, 0.0);
            float2 oG = o - float2(dot(G, sx), dot(G, sy)) * S.i.z;
            float frac = max(ecUncovered(length(oG), Ro) + resid, 0.0);
            float below = sky_top - el;
            float crest = exp(-below / (pixA * 3.0 + 0.001));
            float face = 0.12 + 0.2 * fbm(float3(az * 40.0, below * 400.0, 3.0));
            float sideP = saturate(dot(normalize(float3(rd.x, 0.0, rd.z)), -normalize(float3(Lpl.x, 0.0, Lpl.z))) * -1.0 + 0.4);
            float3 light = sunTint * gain * frac * (face * 0.25 + crest * 0.9) * smoothstep(-0.1, 0.4, dot(normalize(float3(rd.x, 0.0, rd.z)), normalize(float3(sunD.x, 0.0, sunD.z))))
                         + plCol * plI * (0.15 + 0.35 * sideP) + coCol * coI * 0.5 + skyAmb * 0.5;
            float3 rc2 = gcol * 0.8 * light;
            if (air) {
                float3 TG = exp(-dens * 0.3 * beta * 3.5);
                rc2 = rc2 * TG + skyIn * (1.0 - TG);
            }
            col = mix(col, rc2, ridge);
        }
    }

    // glare: the uncovered sun, or at the end the diamond, scatters light in the eye and lens
    if (glareAmp > 0.0 && sd > 0.0) {
        float2 dg = d - S.j.xy;
        float g2 = dot(dg, dg);
        // with only a bead or two left the light is one point: a tight, hot core (the diamond)
        float size = 0.4 + 0.6 * smoothstep(-4.0, 0.0, logE);
        float diamond = 1.0 - smoothstep(-3.6, -2.4, logE);
        float gl = 0.8 * exp(-g2 / (0.05 * size)) + 0.1 / (1.0 + g2 / (0.3 * size)) + 0.004 / (1.0 + g2 / (5.0 * size));
        float dg2 = diamond * smoothstep(-5.6, -4.0, logE) * (4.0 * exp(-g2 / 0.03) + 1.2 * exp(-g2 / 0.25) + 0.25 / (1.0 + g2 / 1.2));
        col += sunCol * sunT * (gl * glareAmp + dg2);
    }
    return finalize(col, p, F);
}
"""
}
