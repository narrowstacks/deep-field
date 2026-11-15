extension ShaderSource {
    static let comet = """
// ---------- per-frame: comet ----------
// Screen-space, in units of half the screen height (y up). S.a = head xy, activity, tail length;
// S.b = ion tail direction, dust curvature, outburst; S.c = ion color, disconnection position;
// S.d = dust color, disconnection strength; S.e.y = jet angle.

fragment float4 cometFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float4 sky = skyTex.read(p);
    float4 X = extraTex.read(p);
    float3 col = skyColor(sky, X, false, F, E, Pal);
    float W = F.camRight.w, H = F.camUp.w;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    float2 v = q - S.a.xy;
    float act = S.a.z, L = S.a.w;
    float burst = S.b.w;
    float2 u = S.b.xy, n = float2(-u.y, u.x);

    // ion tail: straight, narrow, blue, combed into streamers by the solar wind
    float a = dot(v, u), b = dot(v, n);
    float ion = 0.0;
    if (a > -0.03) {
        float width = 0.012 + 0.05 * max(a, 0.0);
        float streak = fbm(float3(a * 3.0 - F.time * 0.22, b / width * 2.2, F.time * 0.03));
        float rays = pow(streak, 3.0) * 3.0;
        float kink = sin(a * 6.0 - F.time * 0.5) * 0.008 * a;
        float bb = (b - kink) / width;
        ion = exp(-bb * bb) * exp(-max(a, 0.0) / (1.4 * L)) * (0.35 + rays) * smoothstep(-0.03, 0.04, a);
        if (S.c.w > 0.0) {
            // a disconnection event: the tail snaps and the loose piece drifts away
            float gap = exp(-pow((a - S.c.w) / 0.04, 2.0));
            ion *= 1.0 - S.d.w * gap * 0.9 * step(a, S.c.w + 0.02);
            ion *= mix(1.0, 1.0 + 1.5 * S.d.w * smoothstep(S.c.w, S.c.w + 0.15, a) * (1.0 - smoothstep(S.c.w + 0.15, S.c.w + 0.45, a)), step(S.c.w, a));
        }
    }

    // dust tail: broader, curved, yellow-white, with striations
    float2 ud = normalize(u + n * 0.45), nd = float2(-ud.y, ud.x);
    float ad = dot(v, ud), bd = dot(v, nd) + S.b.z * ad * ad;
    float dustT = 0.0;
    if (ad > -0.03) {
        float width = 0.02 + 0.16 * max(ad, 0.0);
        float bb = bd / width;
        float striae = 0.75 + 0.25 * sin(bd * 40.0 + ad * 8.0 - F.time * 0.05) * fbm(float3(ad * 2.0 - F.time * 0.04, bb, 9.0));
        dustT = exp(-bb * bb * 0.8) * exp(-max(ad, 0.0) / (1.1 * L)) * striae * smoothstep(-0.03, 0.06, ad);
    }

    // coma, nucleus, and rotating jets
    float rr = length(v);
    float ang = atan2(v.y, v.x);
    float jets = pow(0.5 + 0.5 * cos(ang * 2.0 - S.e.y), 10.0) * exp(-rr / 0.035) * 0.8;
    float coma = exp(-rr / 0.028) * 1.4 + exp(-rr / 0.1) * 0.35;
    float nucleus = exp(-pow(rr / 0.005, 2.0)) * 5.0;
    float k = act * (1.0 + 2.5 * burst);
    col += S.c.rgb * ion * 0.9 * act;
    col += S.d.rgb * dustT * 0.6 * act;
    col += mix(S.d.rgb, float3(0.7, 1.0, 0.85), 0.5) * (coma + jets) * k + float3(1.0) * nucleus;
    return finalize(col, p, F);
}
"""
}
