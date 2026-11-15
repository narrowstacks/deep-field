extension ShaderSource {
    static let pulsar = """
// ---------- per-frame: pulsar ----------
// S.a = magnetic axis, beam half-width; S.b = spin axis, flash; S.c = beam color, nebula on;
// S.d = nebula color, field lines on; S.e = a vector perpendicular to the magnetic axis.

fragment float4 pulsarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 rd = octDecode(X.xy);
    float3 ro = F.camPos.xyz;
    float3 col = skyColor(sky, X, false, F, E, Pal);

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
        float3 acc = float3(0.0);
        for (int i = 0; i < N; i++) {
            float3 x = ro + rd * (tc - half_ + (float(i) + 0.5) * dt);
            float r = length(x);
            if (r < 0.3) continue;
            float3 xn = x / r;
            float c = dot(xn, m);
            // two lighthouse beams along the magnetic axis
            float ang = acos(min(abs(c), 1.0));
            float beam = exp(-pow(ang / w, 2.0)) / (1.0 + r * 0.35) * smoothstep(0.35, 1.2, r);
            acc += beamCol * beam * 0.55;
            if (S.d.w > 0.5) {
                // dipole field lines: r = L sin^2(theta), in three planes around the magnetic axis
                float s2 = max(1.0 - c * c, 1e-3);
                float L = r / s2;
                float lines = 0.0;
                for (int k = 0; k < 3; k++) {
                    float Lk = 2.0 + 1.6 * float(k);
                    lines += exp(-pow((L - Lk) / (0.06 * Lk), 2.0));
                }
                float az = atan2(dot(x, b2), dot(x, b1));
                lines *= pow(0.5 + 0.5 * cos(az * 3.0), 24.0) * smoothstep(0.3, 0.6, r);
                acc += mix(beamCol, float3(1.0), 0.3) * lines * 0.12;
            }
            if (S.c.w > 0.5) {
                // pulsar wind nebula: an equatorial torus and two polar jets, both churning
                float hgt = dot(x, spin);
                float perp = length(x - spin * hgt);
                float churn = noise3(x * 0.9 + float3(0.0, F.time * 0.15, 0.0));
                float torus = exp(-(pow(perp - 4.2, 2.0) + hgt * hgt * 3.0) / 0.9) * (0.4 + 0.9 * churn);
                float jets = exp(-pow(perp / (0.25 + 0.06 * abs(hgt)), 2.0)) * exp(-abs(hgt) / 5.0)
                           * smoothstep(0.6, 1.6, abs(hgt)) * (0.4 + 0.9 * noise3(x * 1.4 - float3(0.0, F.time * 0.6 * sign(hgt), 0.0)));
                acc += nebCol * (torus * 0.07 + jets * 0.22);
            }
        }
        col += acc * dt;
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
