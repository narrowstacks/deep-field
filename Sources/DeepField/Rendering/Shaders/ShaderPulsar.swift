extension ShaderSource {
    static let pulsar = """
// ---------- per-frame: pulsar ----------
// S.a = magnetic axis, beam half-width (rad); S.b = spin axis, flash;
// S.c = beam color x intensity, beams on (bit 0: the pole on the spin axis' north side, bit 1: the other);
// S.d = nebula color x intensity (0 = off), field style (0 off, 1 lines, 2 magnetar lobes);
// S.e = field color x intensity, beam trail (radians the beam winds back per unit of length);
// S.f = dust ring color x intensity (0 = off).

// The span of segment s (t0, t1) where A t^2 + B t + C >= 0, as a hull (x > y when empty).
static float2 quadSpan(float A, float B, float C, float2 s) {
    float disc = B * B - 4.0 * A * C;
    if (abs(A) < 1e-6) return s;                    // nearly linear: keep the whole segment
    if (disc < 0.0) return A > 0.0 ? s : float2(1.0, 0.0);
    float q = sqrt(disc);
    float r0 = (-B - q) / (2.0 * A), r1 = (-B + q) / (2.0 * A);
    float lo = min(r0, r1), hi = max(r0, r1);
    if (A < 0.0) return float2(max(s.x, lo), min(s.y, hi));
    // inside on both sides of the roots
    return float2(lo > s.x ? s.x : max(s.x, hi), hi < s.y ? s.y : min(s.y, lo));
}

static float2 spanUnion(float2 a, float2 b) {
    if (a.x > a.y) return b;
    if (b.x > b.y) return a;
    return float2(min(a.x, b.x), max(a.y, b.y));
}

// v turned by angle a about the unit axis k (Rodrigues).
static float3 rotateAbout(float3 v, float3 k, float a) {
    float c = cos(a), s = sin(a);
    return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
}

// One lighthouse beam, integrated along the ray in closed form instead of marched (it is far
// thinner than a march step): a narrow cone around the half-line s * axis, s > 0, wound back
// behind the rotation by `trail` radians per unit of length. Returns (glow, hot core) and, in
// tHit, the ray distance where the ray passes closest to it.
static float2 beamLight(float3 ro, float3 rd, float3 axis, float3 spin, float w, float trail,
                        float pixAng, float T, thread float &tHit) {
    float3 ax = axis;
    float t = 0.0, s = 0.0, den = 1.0;
    for (int it = 0; it < 2; it++) {
        // closest approach between the ray and the line through the star along ax
        float b = dot(rd, ax), e = dot(ax, ro), dd = dot(rd, ro);
        den = max(1.0 - b * b, 1e-5);
        t = (b * e - dd) / den;
        s = e + t * b;
        // (straightened where we look along it: there the closest point is ill-defined)
        if (it == 0) ax = rotateAbout(axis, spin, -trail * clamp(s, 0.0, 40.0) * smoothstep(0.05, 0.4, sqrt(den)));
    }
    tHit = t;
    if (s < 0.15 || t < 0.0) return float2(0.0);
    float d0 = length(ro + rd * t - ax * s);
    float ws = w * s;
    if (d0 > ws * 12.0) return float2(0.0);
    // fades with distance from the star, and where it passes close to the camera
    float along = smoothstep(0.15, 0.9, s) * exp(-s / 16.0) * smoothstep(6.0, 16.0, length(ax * s - ro));
    // A longer path through it when it points our way. Seen almost end-on the closest point is
    // ill-defined, so there the beam hands over to the flash glare (computed on the CPU).
    float sinPhi = sqrt(den);
    float path = smoothstep(0.08, 0.3, sinPhi) / max(sinPhi, 0.25);
    float wc = max(ws * 0.13, pixAng * t * 0.6);        // the hot core, at least a pixel wide
    // knots streaming outward (smoothed out where we look down the beam, or they read as rings)
    float knots = mix(1.0, 0.7 + 0.6 * noise3(float3(s * 0.8 - T * 3.0, dot(axis, spin) * 7.0, 0.0)), max(sinPhi, 0.25));
    float wg = ws * 0.4;
    float glow = (exp(-(d0 * d0) / (wg * wg)) * knots + exp(-(d0 * d0) / (ws * ws)) * 0.25 + exp(-d0 / (ws * 1.5)) * 0.03) * along * path;
    float core = exp(-(d0 * d0) / (wc * wc)) * (ws * 0.13 / wc) * along * path * (0.85 + 0.3 * knots);
    return float2(glow, core);
}

fragment float4 pulsarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = F.time;

    float3 m = S.a.xyz, spin = S.b.xyz;
    float3 b1 = normalize(cross(spin, m) + float3(1e-6, 0.0, 0.0)), b2 = cross(m, b1);
    float w = S.a.w;
    float3 beamCol = S.c.rgb, nebCol = S.d.rgb, fieldCol = S.e.rgb, ringCol = S.f.rgb;
    int beams = int(S.c.w + 0.5);
    int fieldStyle = int(S.d.w + 0.5);
    bool nebulaOn = dot(nebCol, float3(1.0)) > 0.0, ringOn = dot(ringCol, float3(1.0)) > 0.0;
    float tc = -dot(ro, rd);
    float dmin = length(ro + rd * tc);

    // dust ring: a thin, clumpy sheet in the spin plane, lit by the star from inside and
    // brightest where it scatters starlight toward us. Whatever lies behind it is dimmed.
    float tRing = 1e9, ringT = 1.0;
    float3 ringEm = float3(0.0);
    if (ringOn) {
        float sd = dot(rd, spin);
        float tp = -dot(ro, spin) / (abs(sd) > 1e-4 ? sd : 1e-4);
        float3 xp = ro + rd * tp;
        float rp = length(xp);
        if (tp > 0.0 && rp > 1.5 && rp < 7.6) {
            float3 e1 = normalize(cross(spin, float3(1.0, 0.0, 0.0))), e2 = cross(spin, e1);
            // turning slowly as a whole (true Keplerian shear would wind the clumps into grooves),
            // while the clumps themselves churn
            float az = atan2(dot(xp, e2), dot(xp, e1)) - T * 0.04;
            float2 pp = float2(cos(az), sin(az)) * rp;
            float prof = smoothstep(1.6, 2.1, rp) * (1.0 - smoothstep(4.0, 7.5, rp));
            float lanes = 0.75 + 0.25 * sin(rp * 5.0 + 3.0 * noise3(float3(pp * 0.6, T * 0.01)));
            float clumps = fbm(float3(pp * 1.6, 3.0 + T * 0.015));
            float dens = prof * lanes * (0.15 + 1.4 * smoothstep(0.3, 0.8, clumps));
            float slant = 1.0 / max(abs(sd), 0.18);
            float fwd = pow(max(dot(normalize(xp), -rd), 0.0), 6.0);
            float lit = 2.5 / (rp * rp) * (0.3 + 2.5 * fwd) + 0.6 * exp(-(rp - 1.9) * 4.0);   // hot inner rim
            ringEm = ringCol * dens * lit * min(slant, 3.0) * 0.6;
            ringT = exp(-dens * 1.6 * slant);
            tRing = tp;
        }
    }
    float3 col = SKY(p, rd, false) * ringT;

    const float Rv = 14.0;
    if (dmin < Rv) {
        float half_ = sqrt(Rv * Rv - dmin * dmin);
        const int N = 48;
        float dt = 2.0 * half_ / float(N);
        // Each feature only touches a bounded region, so every sample first checks cheaply
        // whether it is inside one (cut-offs are where a term falls below about e^-12) and
        // only then pays for its exp and noise. Only the stretch of the ray that can reach a
        // feature is marched: the jet cylinder (radius 3.8 around the spin axis) and the
        // sphere holding the torus and the field (radius 7.8). The samples stay on one grid.
        bool fieldOn = fieldStyle > 0;
        float lineAcc = 0.0, lobeAcc = 0.0, nebAcc = 0.0;
        float t0 = tc - half_;
        float2 seg = float2(t0, tc + half_);
        float ro2 = dot(ro, ro), rord = dot(ro, rd);
        float2 span = float2(1.0, 0.0);
        if (nebulaOn) {
            float s0 = dot(ro, spin), s1 = dot(rd, spin);
            span = quadSpan(s1 * s1 - 1.0, -2.0 * (rord - s0 * s1), 3.8 * 3.8 - ro2 + s0 * s0, seg);
        }
        float Rs = nebulaOn ? 7.8 : 6.6;
        if (fieldOn || nebulaOn) span = spanUnion(span, quadSpan(-1.0, -2.0 * rord, Rs * Rs - ro2, seg));
        int iLo = 0, iHi = -1;
        if (span.x <= span.y) {
            iLo = max(int(floor((span.x - t0) / dt - 0.5)), 0);
            iHi = min(int(ceil((span.y - t0) / dt - 0.5)), N - 1);
        }
        for (int i = iLo; i <= iHi; i++) {
            float ti = t0 + (float(i) + 0.5) * dt;
            float3 x = ro + rd * ti;
            float r2 = dot(x, x);
            if (r2 < 0.09) continue;
            float r = sqrt(r2);
            float wgt = ti > tRing ? ringT : 1.0;
            if (fieldOn && r < 6.5) {
                float c = dot(x, m) / r;
                float s2 = max(1.0 - c * c, 1e-3);
                float L = r / s2;                       // dipole field lines: r = L sin^2(theta)
                if (fieldStyle == 1) {
                    // three planes around the magnetic axis
                    if (L > 1.5 && L < 6.5) {
                        // cos(3 * azimuth) from cos(azimuth), instead of atan2 then cos
                        float u = dot(x, b1), v = dot(x, b2);
                        float rho = sqrt(u * u + v * v);
                        float ca = rho > 1e-6 ? u / rho : 1.0;
                        float c3 = ca * (4.0 * ca * ca - 3.0);
                        if (c3 > 0.0) {
                            float lines = 0.0;
                            for (int k = 0; k < 3; k++) {
                                float Lk = 2.0 + 1.6 * float(k);
                                float e = (L - Lk) / (0.06 * Lk);
                                lines += exp(-e * e);
                            }
                            float h1 = 0.5 + 0.5 * c3, h2 = h1 * h1, h4 = h2 * h2, h8 = h4 * h4;
                            // charges streaming along the lines, pole to pole
                            float flow = 0.6 + 0.8 * smoothstep(0.55, 0.95, sin(c * 9.0 - T * 2.0 + L * 2.0) * 0.5 + 0.5);
                            lineAcc += lines * (h8 * h8 * h8) * smoothstep(0.3, 0.6, r) * flow * wgt;   // ^24
                        }
                    }
                } else if (L < 7.0) {
                    // magnetar: the whole field glows, in nested shells drifting outward
                    float sh = 0.5 + 0.5 * cos(6.2831853 * (L * 0.85 - T * 0.12));
                    float lobe = exp(-L / 1.7) * (0.3 + 0.7 * sh * sh) * smoothstep(1.0, 1.7, L) * smoothstep(6.8, 5.5, L);
                    lobeAcc += lobe * (0.7 + 0.6 * noise3(x * 1.3 + float3(0.0, T * 0.25, 0.0))) * wgt;
                }
            }
            if (nebulaOn) {
                // pulsar wind nebula: an equatorial torus and two polar jets, both churning
                float hgt = dot(x, spin);
                float ah = abs(hgt);
                float perp = sqrt(max(r2 - hgt * hgt, 0.0));
                float dp = perp - 4.2;
                float tq = (dp * dp + hgt * hgt * 3.0) / 0.9;
                if (tq < 12.0) {
                    float churn = noise3(x * 0.9 + float3(0.0, T * 0.15, 0.0));
                    nebAcc += exp(-tq) * (0.4 + 0.9 * churn) * 0.07 * wgt;
                }
                float jq = perp / (0.25 + 0.06 * ah);
                if (ah > 0.6 && jq < 3.5) {
                    float churn = noise3(x * 1.4 - float3(0.0, T * 0.6 * sign(hgt), 0.0));
                    nebAcc += exp(-jq * jq) * exp(-ah / 5.0) * smoothstep(0.6, 1.6, ah) * (0.4 + 0.9 * churn) * 0.22 * wgt;
                }
            }
        }
        col += (fieldCol * (lineAcc * 0.14 + lobeAcc * 0.16) + nebCol * nebAcc) * dt;
    }

    // the lighthouse beams: a white-hot core inside a colored glow
    if (beams > 0) {
        float3 coreCol = mix(beamCol, float3(dot(beamCol, float3(0.33))), 0.6) * 1.6;
        for (int k = 0; k < 2; k++) {
            if ((beams & (1 << k)) == 0) continue;
            float tHit;
            float2 bl = beamLight(ro, rd, k == 0 ? m : -m, spin, w, S.e.w, F.pixelAngle, T, tHit);
            float vis = tHit > tRing ? ringT : 1.0;
            col += (beamCol * bl.x * 1.0 + coreCol * bl.y * 2.4) * vis;
        }
    }

    // the neutron star: tiny, white-hot, brightest at its magnetic poles
    float starVis = tc > tRing ? ringT : 1.0;
    float b = dot(ro, rd), disc = b * b - (dot(ro, ro) - 0.09);
    if (disc > 0.0) {
        float3 P = ro + rd * (-b - sqrt(disc));
        float pole = pow(abs(dot(normalize(P), m)), 8.0);
        col = mix(col, float3(0.85, 0.92, 1.0) * (2.0 + 4.0 * pole), starVis);
    }
    col += float3(0.8, 0.9, 1.0) * (exp(-dmin / 0.35) * 1.2 + exp(-dmin / 1.5) * 0.12) * starVis;
    col += ringEm;

    // the lighthouse flash when a beam sweeps past us: a glare around the star with a glint
    // of spikes, not a full-screen blink
    float fl = S.b.w;
    if (fl > 0.001) {
        float3 wv = ro + rd * tc;
        float wx = abs(dot(wv, F.camRight.xyz)), wy = abs(dot(wv, F.camUp.xyz));
        float spikes = exp(-wy / 0.04) * exp(-wx / 1.6) + exp(-wx / 0.04) * exp(-wy / 1.1);
        col += (beamCol * (exp(-dmin / 1.1) * 1.8 + exp(-dmin / 2.5) * 0.15) + mix(beamCol, float3(1.0), 0.5) * spikes * 1.2) * fl * starVis;
    }
    return finalize(col, p, F);
}
"""
}
