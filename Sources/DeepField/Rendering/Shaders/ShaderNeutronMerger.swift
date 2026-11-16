extension ShaderSource {
    static let neutronMerger = """
// ---------- per-frame: neutron star merger ----------
// A loop with no empty moment. A magnetar, the remnant of the last merger, sits in its fading
// kilonova nebula. A new neutron star falls in from beyond the frame on a long eccentric orbit;
// gravitational waves wear the orbit round and small (the chirp), and the pair merge in a flash,
// a short jet and a fresh kilonova, leaving a new remnant at the center. Once the orbit is
// circular it follows the quadrupole chirp: with tau the time left before the merger, the phase
// is phi = phi0 - K tau^(5/8). The waves leave at speed v, so a point at distance rho in the
// orbital plane sees the orbit as it was at tau + rho / v: a trailing two-armed spiral that
// winds tighter as the chirp climbs, and that bends the starlight behind it slightly.
// The system sits at the origin, in the camera's usual frame.
//
// S.a = remnant center, remnant glow (its magnetar beat and early spin-down brightening; 1 = plain)
// S.b = companion center, tidal stretch (long axis over radius)
// S.c = orbit normal, wave ripple strength
// S.d = orbit basis e1 (e2 = n x e1), tau: time to the next merger, or minus the time since the last
// S.e = star glow color x brightness, companion presence (0..1)
// S.f = kilonova hot color, age since the last merger (s)
// S.g = kilonova cool color, kilonova brightness (1 fresh, lower for the lingering nebula)
// S.h = remnant magnetic axis, jet on
// S.i = companion magnetic axis, glow size
// S.j = K, phi0, tauC (before it the orbit was still eccentric, so its waves are left out), flash

constant float NSM_R = 0.2;      // star radius
constant float NSM_V = 0.6;      // wave speed

// Ray against an ellipsoid of radius R stretched by s along unit axis u (volume kept, so the
// cross section shrinks by sqrt(s)). Returns the entry distance (or -1) and the normal there.
static float nsmEllipsoid(float3 ro, float3 rd, float3 c, float3 u, float R, float s, thread float3& nrm) {
    float3 o = ro - c;
    float k = sqrt(s);
    // into the unit sphere's frame: divide by R s along u and by R / sqrt(s) across it
    float ou = dot(o, u), du = dot(rd, u);
    float3 op = o - u * ou, dp = rd - u * du;
    float3 O = op * (k / R) + u * (ou / (R * s));
    float3 D = dp * (k / R) + u * (du / (R * s));
    float a = dot(D, D), b = dot(O, D), cc = dot(O, O) - 1.0;
    float disc = b * b - a * cc;
    if (disc < 0.0) return -1.0;
    float t = (-b - sqrt(disc)) / a;
    if (t < 0.0) return -1.0;
    float3 P = O + D * t;
    // the gradient of the implicit surface, back in world space
    float pu = dot(P, u);
    float3 pp = P - u * pu;
    nrm = normalize(pp * (k / R) + u * (pu / (R * s)));
    return t;
}

// Blends two colors keeping their saturation, so a hue change doesn't pass through gray.
static float3 nsmMix(float3 a, float3 b, float t) {
    float3 c = mix(a, b, t);
    float ma = dot(a, float3(0.333)), mb = dot(b, float3(0.333)), m = dot(c, float3(0.333));
    float sa = length(a - ma) / max(ma, 1e-4), sb = length(b - mb) / max(mb, 1e-4);
    float sc = length(c - m) / max(m, 1e-4);
    return max(m + (c - m) * mix(sa, sb, t) / max(sc, 1e-3), 0.0);
}

// Dipole field lines seen around a star: the slice through its center facing us, where the
// lines r = L sin^2(theta) are drawn as soft threads with charges streaming along them.
static float nsmField(float3 q, float3 m, float R, float T, float seed) {
    float r = length(q);
    if (r < R * 1.05 || r > R * 12.0) return 0.0;
    float c = dot(q, m) / r;
    float s2 = max(1.0 - c * c, 1e-3);
    float L = r / s2;
    float lines = 0.0;
    for (int k = 0; k < 3; k++) {
        float Lk = R * (2.6 + 2.0 * float(k));
        float e = (L - Lk) / (0.1 * Lk);
        lines += (exp(-e * e) + 0.08 * exp(-abs(e) * 0.7)) * (1.0 - 0.3 * float(k));
    }
    float flow = 0.55 + 0.45 * sin(c * 7.0 - T * 2.5 + seed);
    return lines * flow * smoothstep(R * 1.05, R * 1.8, r) * (1.0 - smoothstep(R * 6.0, R * 12.0, r));
}

fragment float4 neutronMergerFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = F.time;

    float3 cA = S.a.xyz, cB = S.b.xyz, n = S.c.xyz, e1 = S.d.xyz, e2 = cross(n, e1);
    const float R = NSM_R, vw = NSM_V;
    float remGlow = S.a.w, stretch = S.b.w;
    float tau = S.d.w, presence = S.e.w;
    float3 glowCol = S.e.rgb;
    float age = S.f.w, kfade = S.g.w;
    float3 hotCol = S.f.rgb, coolCol = S.g.rgb;
    float K = S.j.x, phi0 = S.j.y, tauC = S.j.z, flash = S.j.w;
    float glowSize = S.i.w;
    bool pair = presence > 0.0;
    float pixW = F.pixelAngle * length(ro);              // world size of a pixel at the system
    float3 sepV = cB - cA;
    float sep = pair ? length(sepV) : 0.0;

    // ---- gravitational waves in the orbital plane ----
    float dn = dot(rd, n);
    float tp = -dot(ro, n) / (abs(dn) > 1e-4 ? dn : 1e-4);
    float wave = 0.0;
    float2 disp = float2(0.0);
    if (tp > 0.0 && S.c.w > 0.0) {
        float3 x = ro + rd * tp;
        float rho = length(x);
        float tr = tau + rho / vw;                       // time to merger when this bit left
        float th = atan2(dot(x, e2), dot(x, e1));
        // a pixel's footprint on the plane, stretched where we look along it at a slant
        float foot = F.pixelAngle * tp / max(abs(dn), 0.05);
        float amp = 0.0, psi = 0.0;
        if (tr > 0.0 && tr < tauC) {
            float trc = max(tr, 0.03);
            float omega = 0.625 * K * pow(trc, -0.375);
            float phiR = phi0 - K * pow(trc, 0.625);
            psi = 2.0 * (th - phiR);
            // strain grows as omega^(2/3); the local wavelength is pi v / omega, faded out
            // where it gets down to a few pixels, and the near zone inside the orbit is calm
            float lam = 3.14159 * vw / omega;
            amp = min(pow(omega / 0.4, 0.667), 2.0) * smoothstep(foot * 4.0, foot * 10.0, lam);
            amp *= smoothstep(0.5 * sep, 1.5 * sep + 0.4, rho) * smoothstep(tauC, tauC * 0.6, tr);
        } else if (tr <= 0.0 && tr > -0.8) {
            // the ringdown of the merged remnant: one last fast, fading burst
            float omega = 14.0;
            psi = 2.0 * th - omega * tr * 2.0;
            amp = 1.5 * exp(tr / 0.2) * smoothstep(foot * 4.0, foot * 10.0, 3.14159 * vw / omega);
        }
        // falls off with distance, and is soft at both ends
        amp *= smoothstep(0.2, 1.0, rho) / (1.0 + rho / 5.0);
        wave = amp * cos(psi);
        // the light is nudged across the wavefronts (the strain's gradient points radially)
        float3 er = x / max(rho, 1e-3);
        float g = amp * sin(psi) * S.c.w;
        disp = float2(dot(er, F.camRight.xyz), -dot(er, F.camUp.xyz)) * g * 2.2;
    }
    int2 q = int2(p) + int2(round(disp));
    q = clamp(q, int2(0), int2(int(F.camRight.w) - 1, int(F.camUp.w) - 1));
    float3 col = SKY(uint2(q), rd, false);
    // where the waves squeeze space the stars behind brighten a touch, and a faint sheen
    // shows the wavefronts against the dark
    col *= clamp(1.0 + 0.06 * wave * S.c.w, 0.75, 1.3);
    col += glowCol * float3(0.45, 0.6, 1.0) * sq(max(wave, 0.0)) * 0.004 * S.c.w;

    float tc0 = -dot(ro, rd);
    float d0 = length(ro + rd * tc0);
    float3 x0 = ro + rd * tc0;
    // the hot color's hue at unit strength (a saturated pick can carry several units of light)
    float3 hotN = hotCol / max(max(hotCol.r, hotCol.g), max(hotCol.b, 1e-3));

    // ---- the kilonova, then the nebula it leaves ----
    // Radioactive ejecta glowing as it expands. Two outflows: a fast, lanthanide-poor polar wind
    // that glows hot blue and fades first, and a slower, heavier equatorial torus that turns
    // red. Fingers of ejecta streak outward. Long after, a faint red and gold shell lingers.
    float Rk = 0.3 + 3.6 * (1.0 - exp(-age / 14.0)) + age * 0.004;
    float Rb = Rk * 1.45;
    if (d0 < Rb && kfade > 0.0) {
        float half_ = sqrt(Rb * Rb - d0 * d0);
        // the faint lingering nebula is smooth enough for fewer samples
        int N = kfade > 0.5 ? 22 : 12;
        float dt = 2.0 * half_ / float(N);
        float jitter = hash13(float3(float2(p), 7.0));
        float3 acc = float3(0.0);
        float heat0 = exp(-age / 7.0);
        // Cooling runs like a blackbody's colors (blue-white, gold, red), so each outflow
        // has its own color: the polar wind stays hot blue for a while and cools to gold;
        // the equatorial torus starts gold-white and soon turns red.
        float bright = (dot(hotCol, float3(0.33)) + dot(coolCol, float3(0.33))) * 0.5;
        float3 warm = float3(1.2, 0.8, 0.4) * bright, white = float3(1.0, 0.97, 0.92) * bright * 1.3;
        float3 polarC = nsmMix(warm, nsmMix(hotCol, white, heat0 * 0.3), exp(-age / 24.0));
        float3 equatC = heat0 > 0.5 ? nsmMix(warm, white, heat0 * 2.0 - 1.0) : nsmMix(coolCol, warm, heat0 * 2.0);
        for (int i = 0; i < N; i++) {
            float ti = tc0 - half_ + (float(i) + jitter) * dt;
            float3 x = ro + rd * ti;
            float r = length(x) / Rk;
            if (r > 1.45) continue;
            float3 dir = x / max(length(x), 1e-4);
            float z = dot(dir, n);
            float z2 = z * z;
            // radial streaks: noise on the direction alone keeps them radial; they thin
            // out toward their tips instead of ending on an edge
            float sN = noise3(dir * 13.0 + 3.0) * 0.65 + noise3(dir * 29.0 + 9.0) * 0.35;
            float streak = sq(smoothstep(0.48, 0.82, sN));
            float clump = fbm(x / Rk * 2.6 + float3(0.0, 0.0, age * 0.04));
            float rr = r * (1.0 + 0.35 * (0.5 - clump));        // a ragged, not round, edge
            float edge = 1.0 - smoothstep(0.45, 1.05, rr);
            float blue = exp(-sq((rr - 0.5 - 0.3 * z2) / 0.32)) * (0.08 + z2 * 1.6) * edge;
            float red = exp(-sq(rr / 0.6)) * (1.0 - 0.75 * z2) * edge * 1.3;
            float lumpy = 0.15 + 1.8 * sq(clump);
            float st = streak * (1.0 - smoothstep(0.5, 1.45, r)) * smoothstep(0.15, 0.6, r) * (0.5 + 1.1 * clump);
            // the streaks take the color of the outflow they fly out with
            float pw = smoothstep(0.15, 0.6, z2);
            acc += polarC * (blue * lumpy * 1.3 + st * pw) + equatC * (red * lumpy + st * (1.0 - pw));
        }
        // brightness: up within a second or so, then down as the ejecta thins out
        float lum = smoothstep(0.0, 1.2, age) * (0.3 + 1.3 * exp(-age / 9.0)) / (Rk * 0.5 + 0.4);
        col += acc * dt * lum * kfade * 0.6;
    }

    // ---- the stars: the remnant always, and the companion once it has arrived ----
    float3 u = pair ? sepV / max(sep, 1e-4) : n;
    float close = pair ? smoothstep(2.2, 0.6, sep) : 0.0;    // the last seconds of the chirp
    if (close > 0.0) {
        // stripped matter: two tidal tails winding out of the pair and a hot common glow
        if (tp > 0.0) {
            float3 x = ro + rd * tp;
            float rho = length(x);
            float th = atan2(dot(x, e2), dot(x, e1));
            float phi = phi0 - K * pow(max(tau, 0.0), 0.625);
            float arms = 0.5 + 0.5 * cos(2.0 * (th - phi) + log(max(rho, 0.05)) * 5.0);
            float tail = exp(-rho / (0.5 + 0.6 * sep)) * pow(arms, 3.0) * smoothstep(0.3 * sep, 0.6 * sep, rho);
            col += mix(glowCol, hotCol, 0.5) * tail * close * 1.4;
        }
        col += mix(glowCol, hotCol, 0.4) * exp(-d0 / (0.35 + 0.3 * sep)) * close * close * 1.5;
    }
    float tHit = 1e9, surfVis = 1.0;
    float3 surf = float3(0.0);
    for (int k = 0; k < 2; k++) {
        float vis = k == 0 ? 1.0 : presence;
        if (vis <= 0.0) continue;
        float3 c = k == 0 ? cA : cB;
        float3 m = k == 0 ? S.h.xyz : S.i.xyz;
        float3 toward = k == 0 ? u : -u;
        // the remnant's magnetar beat swells its halo and its field together, and its
        // young, hot surface leans toward the kilonova's hot color
        float gain = k == 0 ? remGlow : 1.0;
        float3 sc = k == 0 ? nsmMix(glowCol, hotN * dot(glowCol, float3(0.33)), 0.5 * saturate(remGlow - 1.0)) : glowCol;
        // glow: a soft halo around a bright core, hotter as they close in
        float tcs = dot(c - ro, rd);
        float3 qv = ro + rd * tcs - c;
        float d = length(qv);
        float gs = glowSize * (1.0 + 0.6 * close);
        col += sc * (exp(-d / (R * 0.9 * gs)) * 1.6 + exp(-d / (R * 3.0 * gs)) * 0.15 * gain
                     + exp(-d / (R * 10.0 * gs)) * 0.012 * gain) * vis;
        // magnetic field hints, brighter as the magnetospheres are squeezed together
        float fl = nsmField(qv, m, R, T, float(k) * 2.1);
        float3 fieldCol = mix(sc, float3(0.45, 0.55, 1.0) * dot(sc, float3(0.33)), 0.55);
        col += fieldCol * fl * (0.22 + 0.4 * close) * gain * gain * vis;
        // the star itself, stretched by tides only while it has a partner
        float3 nrm;
        float th = nsmEllipsoid(ro, rd, c, u, R, pair ? stretch : 1.0, nrm);
        if (th > 0.0 && th < tHit) {
            tHit = th;
            surfVis = vis;
            float mu = max(dot(nrm, -rd), 0.0);
            float limb = 0.55 + 0.45 * mu;
            float pole = pow(abs(dot(nrm, m)), 10.0);
            float tidal = pow(max(dot(nrm, toward), 0.0), 3.0) * close;   // the heated near side
            float3 white = mix(sc, float3(dot(sc, float3(0.33))), 0.6);
            surf = white * (3.0 * limb + 3.0 * pole) + hotCol * tidal * 3.0;
        }
    }
    if (tHit < 1e9) col = mix(col, surf, surfVis);

    // ---- the jet: punches out along the orbit axis in the first seconds, then fades ----
    if (S.h.w > 0.5 && age < 20.0) {
        float jl = 0.0;
        float head = min(age * 6.0, 7.0);
        float b = dot(rd, n), e = dot(n, ro), dd = dot(rd, ro);
        float den = max(1.0 - b * b, 1e-4);
        float t = (b * e - dd) / den;
        float s = e + t * b;
        float as = abs(s);
        if (t > 0.0 && as < head) {
            float d = length(ro + rd * t - n * s);
            float w = 0.06 + 0.05 * as;
            float knots = 0.6 + 0.8 * noise3(float3(as * 1.2 - age * 6.0, s > 0.0 ? 0.0 : 5.0, 0.0));
            float along = smoothstep(0.05, 0.6, as) * (1.0 - smoothstep(head * 0.4, head, as)) * exp(-as / 5.0);
            float wc = max(w * 0.25, pixW * 0.7);
            jl = (exp(-sq(d / w)) * knots * 0.6 + exp(-d / (w * 3.0)) * 0.15) * along
               + exp(-sq(d / wc)) * along * (w * 0.3 / wc) * 0.35;
        }
        float jt = smoothstep(0.2, 0.8, age) * exp(-age / 3.0);
        col += mix(hotN, float3(1.0), 0.3) * jl * jt * 3.2;
    }

    // ---- the flash: a bright burst around the merger with a few diffraction spikes; only
    // the first instant lifts the whole screen, and only slightly ----
    if (flash > 0.001) {
        float wx = abs(dot(x0, F.camRight.xyz)), wy = abs(dot(x0, F.camUp.xyz));
        float spikes = exp(-wy / 0.05) * exp(-wx / 3.0) + exp(-wx / 0.05) * exp(-wy / 2.0);
        float3 fc = mix(hotN, float3(1.0), 0.6);
        col += fc * (exp(-d0 / 0.4) * 14.0 + exp(-d0 / 1.6) * 1.8 + exp(-d0 / 5.0) * 0.05 + spikes * 2.5) * flash;
        col += fc * 0.015 * flash * flash * flash;
    }
    return finalize(col, p, F);
}
"""
}
