extension ShaderSource {
    static let pulsar = """
// ---------- per-frame: pulsar ----------
// S.a = magnetic axis, beam half-width; S.b = spin axis, flash; S.c = beam color, nebula on;
// S.d = nebula color, field lines on; S.e = a vector perpendicular to the magnetic axis.

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

fragment float4 pulsarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float3 col = SKY(p, rd, false);

    float3 m = S.a.xyz, spin = S.b.xyz, b1 = S.e.xyz, b2 = cross(m, b1);
    float w = S.a.w;
    float3 beamCol = S.c.rgb, nebCol = S.d.rgb;
    float tc = -dot(ro, rd);
    float dmin = length(ro + rd * tc);
    const float Rv = 14.0;
    if (dmin < Rv) {
        float half_ = sqrt(Rv * Rv - dmin * dmin);
        const int N = 48;
        float dt = 2.0 * half_ / float(N);
        // Each feature only touches a bounded region, so every sample first checks cheaply
        // whether it is inside one (cut-offs are where a term falls below about e^-12) and
        // only then pays for its acos, exp and noise.
        float cosBeam = cos(min(4.0 * w, 1.5707963));      // beam cone: 4 widths off axis
        bool fieldOn = S.d.w > 0.5, nebulaOn = S.c.w > 0.5;
        float3 lineCol = mix(beamCol, float3(1.0), 0.3);
        float beamAcc = 0.0, lineAcc = 0.0, nebAcc = 0.0;

        // Only march the stretch of the ray that can reach a feature: the beam cone, the jet
        // cylinder (radius 3.8 around the spin axis) and the sphere holding the torus and
        // field lines (radius 7.8). The samples stay on the same grid.
        float t0 = tc - half_;
        float2 seg = float2(t0, tc + half_);
        float ro2 = dot(ro, ro), rord = dot(ro, rd);
        float k = cosBeam * cosBeam, a0 = dot(ro, m), a1 = dot(rd, m);
        float2 span = quadSpan(a1 * a1 - k, 2.0 * (a0 * a1 - k * rord), a0 * a0 - k * ro2, seg);
        if (nebulaOn) {
            float s0 = dot(ro, spin), s1 = dot(rd, spin);
            span = spanUnion(span, quadSpan(s1 * s1 - 1.0, -2.0 * (rord - s0 * s1), 3.8 * 3.8 - ro2 + s0 * s0, seg));
        }
        if (fieldOn || nebulaOn) span = spanUnion(span, quadSpan(-1.0, -2.0 * rord, 7.8 * 7.8 - ro2, seg));
        int iLo = 0, iHi = -1;
        if (span.x <= span.y) {
            iLo = max(int(floor((span.x - t0) / dt - 0.5)), 0);
            iHi = min(int(ceil((span.y - t0) / dt - 0.5)), N - 1);
        }
        for (int i = iLo; i <= iHi; i++) {
            float3 x = ro + rd * (t0 + (float(i) + 0.5) * dt);
            float r2 = dot(x, x);
            if (r2 < 0.09) continue;
            float r = sqrt(r2);
            float c = dot(x, m) / r;
            float ac = abs(c);
            // two lighthouse beams along the magnetic axis
            if (ac > cosBeam) {
                float a = acos(min(ac, 1.0)) / w;
                beamAcc += exp(-a * a) / (1.0 + r * 0.35) * smoothstep(0.35, 1.2, r);
            }
            if (fieldOn && r < 6.5) {
                // dipole field lines: r = L sin^2(theta), in three planes around the magnetic axis
                float s2 = max(1.0 - c * c, 1e-3);
                float L = r / s2;
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
                        lineAcc += lines * (h8 * h8 * h8) * smoothstep(0.3, 0.6, r);   // ^24
                    }
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
                    float churn = noise3(x * 0.9 + float3(0.0, F.time * 0.15, 0.0));
                    nebAcc += exp(-tq) * (0.4 + 0.9 * churn) * 0.07;
                }
                float jq = perp / (0.25 + 0.06 * ah);
                if (ah > 0.6 && jq < 3.5) {
                    float churn = noise3(x * 1.4 - float3(0.0, F.time * 0.6 * sign(hgt), 0.0));
                    nebAcc += exp(-jq * jq) * exp(-ah / 5.0) * smoothstep(0.6, 1.6, ah) * (0.4 + 0.9 * churn) * 0.22;
                }
            }
        }
        col += (beamCol * beamAcc * 0.55 + lineCol * lineAcc * 0.12 + nebCol * nebAcc) * dt;
        // the neutron star: tiny, white-hot, brightest at its magnetic poles
        float b = dot(ro, rd), disc = b * b - (dot(ro, ro) - 0.09);
        if (disc > 0.0) {
            float3 P = ro + rd * (-b - sqrt(disc));
            float pole = pow(abs(dot(normalize(P), m)), 8.0);
            col = float3(0.85, 0.92, 1.0) * (2.0 + 4.0 * pole);
        }
        col += float3(0.8, 0.9, 1.0) * exp(-dmin / 0.35) * 1.2;
    }
    // the lighthouse flash when a beam sweeps past us
    col += beamCol * S.b.w * (exp(-dmin / 2.5) * 1.5 + 0.03);
    return finalize(col, p, F);
}
"""
}
