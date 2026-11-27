// ---------- per-frame: comet ---------- (ShaderComet.swift)
// Screen-space, in units of half the screen height (y up). S.a = head xy, activity, tail length;
// S.b = ion tail direction, dust curvature, outburst; S.c = ion color, disconnection position;
// S.d = dust color, disconnection strength; S.e = outburst shell radius, jet angle, outburst
// shell brightness.

@fragment
fn cometFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    var col = SKY(p, octDecode(readTex(dirTex, p).xy), false);
    let W = F.camRight.w;
    let H = F.camUp.w;
    var q = vec2<f32>((f32(p.x) + 0.5 - W * 0.5) / (H * 0.5), -(f32(p.y) + 0.5 - H * 0.5) / (H * 0.5));
    q *= F.screenScale;
    let v = q - S.a.xy;
    let act = S.a.z;
    let L = S.a.w;
    let burst = S.b.w;
    let u = S.b.xy;
    let n = vec2<f32>(-u.y, u.x);
    let time = F.time;

    // ion tail: straight, narrow, blue, combed by the solar wind into streamers that fan out
    // from the head, with kinks that ripple outward along it
    let a = dot(v, u);
    let b = dot(v, n);
    var ion = 0.0;
    let width = 0.012 + 0.05 * max(a, 0.0);
    let kink = (sin(a * 6.0 - time * 0.5) * 0.008 + sin(a * 2.3 - time * 0.21 + 1.7) * 0.012) * a;
    var bb = (b - kink) / width;
    let dc = select(0.0, max(a - S.c.w, 0.0), S.c.w > 0.0);   // distance past a disconnection
    if (dc > 0.0) {
        // the cut-off piece drifts away and sags sideways, frayed and spread
        let sag = S.d.w * (0.06 * smoothstep(0.0, 0.5, dc) + 0.02 * sin(dc * 9.0 - time * 0.4));
        bb = (b - kink - sag) / (width * (1.0 + 0.6 * S.d.w * smoothstep(0.0, 0.3, dc)));
    }
    if (a > -0.03 && bb * bb < 14.0) {          // (beyond that the tail is below e^-14)
        let fan = b / (a + 0.06);              // angle from the nucleus: streamers diverge from it
        let streak = fbm(vec3<f32>(a * 2.6 - time * 0.22, fan * 26.0, time * 0.03));
        let rays = pow(max(streak, 0.0), 3.0) * 3.2 + 0.35 * pow(0.5 + 0.5 * cos(fan * 70.0 + streak * 6.0), 6.0);
        ion = exp(-bb * bb) * exp(-max(a, 0.0) / (1.4 * L)) * (0.3 + rays) * smoothstep(-0.03, 0.04, a);
        // a bright core line close to the head
        ion += exp(-bb * bb * 9.0) * exp(-max(a, 0.0) / 0.12) * 0.6;
        if (S.c.w > 0.0) {
            // a disconnection: the tail snaps; the piece beyond the break glows where the
            // reconnecting field squeezes it, and the new tail regrows from the head behind it
            let gap = exp(-sq((a - S.c.w) / (0.05 + 0.08 * S.c.w)));
            let regrow = smoothstep(S.c.w * 0.45, S.c.w * 0.95, a) * (1.0 - step(S.c.w, a));
            ion *= 1.0 - S.d.w * saturate(gap * 0.92 + regrow * 0.45);
            let knot = exp(-sq((dc - 0.1) / 0.07)) * step(S.c.w, a);
            let piece = smoothstep(0.0, 0.12, dc) * (1.0 - smoothstep(0.2, 0.7, dc));
            ion *= 1.0 + S.d.w * (1.8 * knot + 0.8 * piece);
        }
    }

    // dust tail: broader, curved, yellow-white, with a sharper, brighter leading edge and
    // striae (bands of dust released in bursts) slanting across it
    let ud = normalize(u + n * 0.45);
    let nd = vec2<f32>(-ud.y, ud.x);
    let ad = dot(v, ud);
    let bd = dot(v, nd) + S.b.z * ad * ad;
    var dustT = 0.0;
    let widthD = 0.02 + 0.16 * max(ad, 0.0);
    let bbD = bd / widthD;
    if (ad > -0.03 && bbD * bbD < 16.0) {
        let bb = bbD;
        let side = select(0.8, 1.4, bb < 0.0);      // the convex (leading) side falls off faster
        let prof = exp(-bb * bb * 0.8 * side * side) * (1.0 + 0.35 * exp(-sq((bb + 0.9) / 0.5)));
        let sl = bd * 40.0 + ad * 8.0 - time * 0.05;
        let striae = 0.72 + 0.28 * sin(sl) * fbm(vec3<f32>(ad * 2.0 - time * 0.04, bb, 9.0))
                     + 0.12 * sin(sl * 0.37 + 1.3);
        let grain = 0.85 + 0.3 * noise3(vec3<f32>(ad * 30.0, bb * 3.0, time * 0.02));
        dustT = prof * exp(-max(ad, 0.0) / (1.1 * L)) * striae * grain * smoothstep(-0.03, 0.06, ad);
    }

    // coma, nucleus, and jets. The coma is brighter and more compact sunward (the side away
    // from the tails), with a green glow of carbon gas inside the dusty outer coma. Jets from
    // active spots on the spinning nucleus curl into spirals as it turns, and only blow on the
    // day side.
    let rr = length(v);
    let ang = atan2(v.y, v.x);
    let sunward = dot(v, -u) / max(rr, 1e-4);
    let lop = 1.0 + 0.45 * sunward;
    let spiral = ang - S.e.y + rr * 55.0;
    let jets = (pow(0.5 + 0.5 * cos(spiral * 2.0), 12.0) + 0.6 * pow(0.5 + 0.5 * cos(spiral + 2.2), 16.0))
               * exp(-rr / 0.04) * smoothstep(-0.5, 0.6, sunward) * 0.9;
    let inner = exp(-rr / (0.022 * lop));
    let outer = exp(-rr / (0.08 * lop)) * 0.3 + exp(-rr / 0.22) * 0.035;
    let nucleus = exp(-sq(rr / 0.005)) * 5.0;
    let k = act * (1.0 + 2.5 * burst);
    let gas = mix(S.d.rgb, vec3<f32>(0.5, 1.0, 0.7), 0.7);
    var comaCol = gas * (inner * 1.5 + jets + outer * 0.6) + mix(S.d.rgb, gas, 0.4) * outer * 0.5;

    // outburst: a cloud of fresh dust billowing out of the nucleus, thrown mostly sunward,
    // then pushed back around the head toward the tail by sunlight
    if (S.e.z > 0.0) {
        let c = S.a.xy + u * S.e.x * 0.45;
        let w = q - c;
        let rs = length(w);
        let facing = dot(w, -u) / max(rs, 1e-4);
        let hood = pow(saturate(0.5 + 0.5 * facing), 1.5);
        let lumpy = 0.7 + 0.6 * noise3(vec3<f32>(atan2(w.y, w.x) * 3.0, rs * 12.0, 4.0));
        let front = exp(-sq((rs - S.e.x) / (0.02 + S.e.x * 0.35))) * hood * lumpy;
        let fill = exp(-rs / max(S.e.x * 0.7, 0.01)) * 0.3;
        comaCol += mix(S.d.rgb, vec3<f32>(1.0), 0.35) * (front * 0.6 + fill * 0.7) * S.e.z;
    }

    col += S.c.rgb * mix(vec3<f32>(1.0), vec3<f32>(0.75, 0.9, 1.0), exp(-max(a, 0.0) / 0.2)) * ion * 0.9 * act;
    col += S.d.rgb * mix(vec3<f32>(1.0), vec3<f32>(1.05, 1.0, 0.92), exp(-max(ad, 0.0) / 0.3)) * dustT * 0.6 * act;
    col += comaCol * k + vec3<f32>(1.0) * nucleus;
    return finalize(col, p);
}
