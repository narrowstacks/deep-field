extension ShaderSource {
    static let comet = """
// ---------- per-frame: comet ----------
// Screen-space, in units of half the screen height (y up). S.a = head xy, activity, tail length;
// S.b = ion tail direction, dust curvature, outburst; S.c = ion color, disconnection position;
// S.d = dust color, disconnection strength; S.e = outburst shell radius, jet angle, outburst
// shell brightness.

fragment float4 cometFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 col = SKY(p, octDecode(dirTex.read(p).xy), false);
    float W = F.camRight.w, H = F.camUp.w;
    float2 q = float2((float(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(float(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    float2 v = q - S.a.xy;
    float act = S.a.z, L = S.a.w;
    float burst = S.b.w;
    float2 u = S.b.xy, n = float2(-u.y, u.x);
    float time = F.time;

    // ion tail: straight, narrow, blue, combed by the solar wind into streamers that fan out
    // from the head, with kinks that ripple outward along it
    float a = dot(v, u), b = dot(v, n);
    float ion = 0.0;
    float width = 0.012 + 0.05 * max(a, 0.0);
    float kink = (sin(a * 6.0 - time * 0.5) * 0.008 + sin(a * 2.3 - time * 0.21 + 1.7) * 0.012) * a;
    float bb = (b - kink) / width;
    float dc = S.c.w > 0.0 ? max(a - S.c.w, 0.0) : 0.0;   // distance past a disconnection
    if (dc > 0.0) {
        // the cut-off piece drifts away and sags sideways, frayed and spread
        float sag = S.d.w * (0.06 * smoothstep(0.0, 0.5, dc) + 0.02 * sin(dc * 9.0 - time * 0.4));
        bb = (b - kink - sag) / (width * (1.0 + 0.6 * S.d.w * smoothstep(0.0, 0.3, dc)));
    }
    if (a > -0.03 && bb * bb < 14.0) {          // (beyond that the tail is below e^-14)
        float fan = b / (a + 0.06);              // angle from the nucleus: streamers diverge from it
        float streak = fbm(float3(a * 2.6 - time * 0.22, fan * 26.0, time * 0.03));
        float rays = pow(streak, 3.0) * 3.2 + 0.35 * pow(0.5 + 0.5 * cos(fan * 70.0 + streak * 6.0), 6.0);
        ion = exp(-bb * bb) * exp(-max(a, 0.0) / (1.4 * L)) * (0.3 + rays) * smoothstep(-0.03, 0.04, a);
        // a bright core line close to the head
        ion += exp(-bb * bb * 9.0) * exp(-max(a, 0.0) / 0.12) * 0.6;
        if (S.c.w > 0.0) {
            // a disconnection: the tail snaps; the piece beyond the break glows where the
            // reconnecting field squeezes it, and the new tail regrows from the head behind it
            float gap = exp(-pow((a - S.c.w) / (0.05 + 0.08 * S.c.w), 2.0));
            float regrow = smoothstep(S.c.w * 0.45, S.c.w * 0.95, a) * (1.0 - step(S.c.w, a));
            ion *= 1.0 - S.d.w * saturate(gap * 0.92 + regrow * 0.45);
            float knot = exp(-pow((dc - 0.1) / 0.07, 2.0)) * step(S.c.w, a);
            float piece = smoothstep(0.0, 0.12, dc) * (1.0 - smoothstep(0.2, 0.7, dc));
            ion *= 1.0 + S.d.w * (1.8 * knot + 0.8 * piece);
        }
    }

    // dust tail: broader, curved, yellow-white, with a sharper, brighter leading edge and
    // striae (bands of dust released in bursts) slanting across it
    float2 ud = normalize(u + n * 0.45), nd = float2(-ud.y, ud.x);
    float ad = dot(v, ud), bd = dot(v, nd) + S.b.z * ad * ad;
    float dustT = 0.0;
    float widthD = 0.02 + 0.16 * max(ad, 0.0);
    float bbD = bd / widthD;
    if (ad > -0.03 && bbD * bbD < 16.0) {
        float bb = bbD;
        float side = bb < 0.0 ? 1.4 : 0.8;      // the convex (leading) side falls off faster
        float prof = exp(-bb * bb * 0.8 * side * side) * (1.0 + 0.35 * exp(-pow((bb + 0.9) / 0.5, 2.0)));
        float sl = bd * 40.0 + ad * 8.0 - time * 0.05;
        float striae = 0.72 + 0.28 * sin(sl) * fbm(float3(ad * 2.0 - time * 0.04, bb, 9.0))
                     + 0.12 * sin(sl * 0.37 + 1.3);
        float grain = 0.85 + 0.3 * noise3(float3(ad * 30.0, bb * 3.0, time * 0.02));
        dustT = prof * exp(-max(ad, 0.0) / (1.1 * L)) * striae * grain * smoothstep(-0.03, 0.06, ad);
    }

    // coma, nucleus, and jets. The coma is brighter and more compact sunward (the side away
    // from the tails), with a green glow of carbon gas inside the dusty outer coma. Jets from
    // active spots on the spinning nucleus curl into spirals as it turns, and only blow on the
    // day side.
    float rr = length(v);
    float ang = atan2(v.y, v.x);
    float sunward = dot(v, -u) / max(rr, 1e-4);
    float lop = 1.0 + 0.45 * sunward;
    float spiral = ang - S.e.y + rr * 55.0;
    float jets = (pow(0.5 + 0.5 * cos(spiral * 2.0), 12.0) + 0.6 * pow(0.5 + 0.5 * cos(spiral + 2.2), 16.0))
               * exp(-rr / 0.04) * smoothstep(-0.5, 0.6, sunward) * 0.9;
    float inner = exp(-rr / (0.022 * lop));
    float outer = exp(-rr / (0.08 * lop)) * 0.3 + exp(-rr / 0.22) * 0.035;
    float nucleus = exp(-pow(rr / 0.005, 2.0)) * 5.0;
    float k = act * (1.0 + 2.5 * burst);
    float3 gas = mix(S.d.rgb, float3(0.5, 1.0, 0.7), 0.7);
    float3 comaCol = gas * (inner * 1.5 + jets + outer * 0.6) + mix(S.d.rgb, gas, 0.4) * outer * 0.5;

    // outburst: a cloud of fresh dust billowing out of the nucleus, thrown mostly sunward,
    // then pushed back around the head toward the tail by sunlight
    if (S.e.z > 0.0) {
        float2 c = S.a.xy + u * S.e.x * 0.45;
        float2 w = q - c;
        float rs = length(w);
        float facing = dot(w, -u) / max(rs, 1e-4);
        float hood = pow(saturate(0.5 + 0.5 * facing), 1.5);
        float lumpy = 0.7 + 0.6 * noise3(float3(atan2(w.y, w.x) * 3.0, rs * 12.0, 4.0));
        float front = exp(-pow((rs - S.e.x) / (0.02 + S.e.x * 0.35), 2.0)) * hood * lumpy;
        float fill = exp(-rs / max(S.e.x * 0.7, 0.01)) * 0.3;
        comaCol += mix(S.d.rgb, float3(1.0), 0.35) * (front * 0.6 + fill * 0.7) * S.e.z;
    }

    col += S.c.rgb * mix(float3(1.0), float3(0.75, 0.9, 1.0), exp(-max(a, 0.0) / 0.2)) * ion * 0.9 * act;
    col += S.d.rgb * mix(float3(1.0), float3(1.05, 1.0, 0.92), exp(-max(ad, 0.0) / 0.3)) * dustT * 0.6 * act;
    col += comaCol * k + float3(1.0) * nucleus;
    return finalize(col, p, F);
}
"""
}
