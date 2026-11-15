extension ShaderSource {
    static let gasGiant = """
// ---------- per-frame: gas giant storms ----------
// A giant planet close up: its clouds flow. Each point of the cloud deck is traced back along the
// wind (alternating jets, and storms spinning in place) to find which bit of cloud texture has
// arrived there. Traced back too far the texture smears into streaks, so two copies run half a
// cycle apart, each restarting while it's faded out, and the picture is their blend.
// The scene has its own frame: the camera at the origin looking down +z, x right, y up.
//
// S.a = planet center, radius
// S.b = spin axis, wind
// S.c = direction to the sun, turbulence
// S.d = zone (light band) color, storm size
// S.e = belt (dark band) color, flow cycle (s)
// S.f = storm color, lightning rate
// S.g = moon center, radius (0 = none)
// S.h = impact site (unit vector from the planet's center), progress (0 = none)
// S.i = x seed

constant int GG_STORMS = 5;

// Wind speed (radians of longitude per second) at latitude sine sl: alternating jets.
static float ggWind(float sl, float wind) {
    return wind * 0.0025 * (0.75 * sin(sl * 21.0) + 0.35 * cos(sl * 8.0) + 0.25);
}

// Storm k: latitude sine, longitude at time zero, size (radians), spin (radians per second,
// negative = anticyclone), and how it tints the clouds (0 the storm color, 1 white).
static float4 ggStorm(int k, thread float& tint) {
    switch (k) {
    case 0: tint = 0.0; return float4(0.36, -0.05, 0.12, -0.05);       // the great spot
    case 1: tint = 1.0; return float4(0.55, 1.0, 0.05, -0.08);        // white ovals
    case 2: tint = 1.0; return float4(0.55, -0.4, 0.045, -0.08);
    case 3: tint = 0.7; return float4(0.2, 0.9, 0.035, 0.09);         // a small barge
    default: tint = 1.0; return float4(0.68, 0.2, 0.04, -0.07);
    }
}

static float3 ggPoint(float sl, float lon, float3 axis, float3 e1, float3 e2) {
    float cl = sqrt(max(1.0 - sl * sl, 0.0));
    return axis * sl + (e1 * cos(lon) + e2 * sin(lon)) * cl;
}

// The cloud texture at unit point q (planet frame through axis/e1/e2), with footprint fp.
static float3 ggTexture(float3 q, float3 axis, float fp, float turb, float3 zone, float3 belt, float seed) {
    float sl = dot(q, axis);
    float warp = fbm(q * 3.0 + seed) - 0.5;
    float lt = sl + warp * 0.05 * turb;
    float bands = 0.5 + 0.5 * sin(lt * 34.0 + 2.6 * sin(lt * 9.0 + seed));
    // curls where the jets shear the band edges: detail displaced along the bands
    float2 cw = float2(fbmLOD(q * 22.0 + seed, fp * 22.0), fbmLOD(q * 22.0 + seed + 7.0, fp * 22.0)) - 0.5;
    float fine = fbmLOD(q * 26.0 + float3(cw * 1.6 * turb, lt * 70.0 + seed), fp * 26.0);
    float eddies = fbmLOD(q * 60.0 + seed * 1.7, fp * 60.0);
    float edge = 1.0 - abs(2.0 * bands - 1.0);                      // strongest at the band edges
    float t = smoothstep(0.12, 0.88, bands + (fine - 0.5) * (0.6 + 1.2 * edge) * turb + (eddies - 0.5) * 0.4 * turb);
    // three tones: ivory zones, rust belts, and a deeper brown at the belts' hearts
    float3 c = mix(belt, zone, t);
    c = mix(c, belt * float3(0.65, 0.5, 0.42), smoothstep(0.35, 0.0, bands) * 0.6);
    c *= 0.88 + 0.24 * fbmLOD(q * 12.0 + seed + 3.0, fp * 12.0);    // patchy tone within each band
    // the equatorial zone is brightest, and dark blue-gray festoons trail from its edge
    float eq = smoothstep(0.14, 0.0, abs(sl));
    c = mix(c, zone * 1.05, eq * 0.4);
    float fest = smoothstep(0.58, 0.85, fbmLOD(q * 9.0 + float3(seed, 0.0, 3.0), fp * 9.0)) * smoothstep(0.05, 0.1, abs(sl)) * smoothstep(0.18, 0.12, abs(sl));
    c = mix(c, float3(0.25, 0.3, 0.4) * dot(belt, float3(0.5)), fest * 0.6);
    // cooler, darker toward the poles
    c = mix(c, belt * float3(0.6, 0.7, 0.85), smoothstep(0.65, 0.95, abs(sl)) * 0.7);
    return c;
}

fragment float4 gasGiantFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rdw = octDecode(dirTex.read(p).xy);
    float3 right = F.camRight.xyz, up = F.camUp.xyz, fwd = cross(right, up);
    float3 rd = float3(dot(rdw, right), dot(rdw, up), dot(rdw, fwd));
    float T = F.time;
    float3 C = S.a.xyz;
    float R = S.a.w;
    float3 axis = S.b.xyz;
    float3 L = S.c.xyz;
    float wind = S.b.w, turb = S.c.w, seed = S.i.x;
    float3 e1 = normalize(float3(0.0, 0.0, -1.0) - axis * dot(float3(0.0, 0.0, -1.0), axis)), e2 = cross(axis, e1);

    float3 col = SKY(p, rdw, false);
    float2 s = sphereSpan(-C, rd, R);
    float tP = s.x;
    bool hit = s.x < s.y && s.x > 0.0;
    if (hit) {
        float3 P = rd * tP;
        float3 N = normalize(P - C);
        float sl = dot(N, axis);
        float mu = saturate(dot(N, -rd));
        float fp = F.pixelAngle * tP / R / max(mu, 0.1);

        // trace back along the flow, for two copies half a cycle apart
        float cycle = S.e.w;
        float3 alb = float3(0.0);
        float stormMask = 0.0, rimMask = 0.0, paleMask = 0.0, stormRed = 0.0;
        float3 stormTint = float3(0.0);
        for (int k = 0; k < 2; k++) {
            float ph = T / cycle + 0.5 * float(k);
            float f = fract(ph);
            float w = 1.0 - abs(2.0 * f - 1.0);
            float tau = f * cycle;
            float3 q = N;
            float zonal = ggWind(sl, wind);
            for (int j = 0; j < GG_STORMS; j++) {
                float tint;
                float4 st = ggStorm(j, tint);
                float size = st.z * S.d.w;
                float ws = ggWind(st.x, wind);
                float3 c = ggPoint(st.x, st.y + ws * 0.12 * T, axis, e1, e2);
                float3 dq = q - c;
                float east = dot(dq, normalize(cross(axis, c))), north = dot(dq, axis);
                float r = length(float2(east / 1.7, north));             // ovals, longer east-west
                if (r > size * 3.0) continue;
                float inside = exp(-sq(r / size));
                // inside, it spins (fastest just inside its edge) and rides along with its band
                float spin = st.w * wind * smoothstep(0.0, 0.6 * size, r) * exp(-sq(r / (1.3 * size)));
                q = rotateAbout(q, c, -spin * tau);
                zonal = mix(zonal, ws, inside);
                if (k == 0) {
                    float m = smoothstep(1.2 * size, 0.35 * size, r);
                    if (m > stormMask) {
                        stormMask = m;
                        stormTint = mix(S.f.rgb, float3(1.0, 0.97, 0.92) * max(S.d.r, 0.8), tint);
                        stormRed = 1.0 - tint;
                    }
                    float collar = exp(-sq((r - 1.2 * size) / (0.32 * size)));
                    rimMask = max(rimMask, collar * tint);           // dark collars round the white ovals
                    paleMask = max(paleMask, collar * (1.0 - tint)); // a pale hollow round the great spot
                }
            }
            q = rotateAbout(q, axis, -zonal * tau);
            // the texture is laid out in the frame the bands drift through, so it never ages
            alb += ggTexture(q, axis, fp, turb, S.d.rgb, S.e.rgb, seed + float(k) * 0.0) * w;
        }
        // the storms' own color, with their spiral texture showing through
        float lum = dot(alb, float3(0.3, 0.5, 0.2));
        alb = mix(alb, stormTint * (0.45 + 0.9 * lum), stormMask * mix(0.6, 0.85, stormRed));
        alb = mix(alb, S.d.rgb * 1.05, paleMask * 0.5);
        alb *= 1.0 - 0.22 * rimMask;                                   // a darker collar round each storm

        // impact scars: a dark chain of spots, smeared along the band as it shears them
        if (S.h.w > 0.0) {
            float3 site = S.h.xyz;
            for (int i = 0; i < 4; i++) {
                float lonOff = float(i) * 0.09 - 0.12;
                float3 c = rotateAbout(site, axis, lonOff + ggWind(dot(site, axis), wind) * S.h.w * 360.0);
                float3 d = N - c;
                float along = dot(d, cross(axis, c)), across = dot(d, axis);
                float size = (0.012 + 0.03 * sqrt(S.h.w)) * (1.0 - 0.15 * float(i));
                float scar = exp(-sq(along / (size * (1.0 + 4.0 * S.h.w))) - sq(across / size));
                float fade = smoothstep(0.0, 0.03, S.h.w) * (1.0 - smoothstep(0.75, 1.0, S.h.w));
                alb = mix(alb, float3(0.12, 0.08, 0.06), scar * fade * 0.85);
            }
        }

        // light: soft terminator, darkening toward the limb, a faint haze on the rim
        float nl = dot(N, L);
        float shade = 1.0;
        if (S.g.w > 0.0) {
            // the moon's shadow
            float sm = dot(S.g.xyz - P, L);
            if (sm > 0.0) shade *= smoothstep(S.g.w * 0.7, S.g.w * 1.2, length(S.g.xyz - (P + L * sm)));
        }
        float day = saturate((nl + 0.05) / 1.05);
        float limb = 0.35 + 0.65 * pow(mu, 0.6);
        col = alb * day * shade * limb * 0.85;
        col += mix(S.d.rgb, float3(0.6, 0.75, 1.0), 0.5) * pow(1.0 - mu, 2.5) * saturate(nl + 0.3) * 0.16;

        // lightning in the belts on the night side
        if (S.f.w > 0.0 && nl < 0.1) {
            const float cell = 0.05;
            float3 base = floor(N / cell);
            for (int i = 0; i < 8; i++) {
                float3 cc = base + float3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
                float h = hash13(cc + seed);
                if (h > 0.12) continue;
                float3 ctr = (cc + float3(hash13(cc + 1.3), hash13(cc + 2.7), hash13(cc + 4.1))) * cell;
                float dist = length(N - ctr);
                if (dist > 0.03) continue;
                float slot = T * (0.5 + 0.8 * h) * S.f.w + h * 50.0;
                float roll = hash13(float3(cc.xy, floor(slot)));
                float flash = roll > 0.9 ? exp(-fract(slot) * 8.0) : 0.0;
                col += float3(0.7, 0.8, 1.0) * flash * exp(-sq(dist / 0.006)) * 2.5 * smoothstep(0.1, -0.15, nl);
            }
        }
        // the impact's flash
        if (S.h.w > 0.0 && S.h.w < 0.03) {
            float d = length(N - S.h.xyz);
            col += float3(1.0, 0.9, 0.75) * exp(-sq(d / 0.03)) * (1.0 - S.h.w / 0.03) * 6.0;
        }
    } else {
        // the atmosphere's glow just off the limb
        float b = length(-C - rd * dot(-C, rd)) / R;
        col += mix(S.d.rgb, float3(0.55, 0.7, 1.0), 0.5) * exp(-max(b - 1.0, 0.0) / 0.012) * 0.1;
    }

    // the moon, in front of or beside the planet
    if (S.g.w > 0.0) {
        float2 ms = sphereSpan(-S.g.xyz, rd, S.g.w);
        if (ms.x < ms.y && ms.x > 0.0 && (!hit || ms.x < tP)) {
            float3 N = normalize(rd * ms.x - S.g.xyz);
            float alb = 0.6 + 0.4 * fbm(N * 5.0 + 3.0);
            float3 mc = mix(float3(0.95, 0.75, 0.35), float3(1.0, 0.95, 0.7), fbm(N * 9.0 + 1.0)) * alb;
            col = mc * saturate(dot(N, L)) * 1.1;
        }
    }
    return finalize(col, p, F);
}
"""
}
