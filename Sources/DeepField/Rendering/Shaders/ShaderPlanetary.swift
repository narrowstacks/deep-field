extension ShaderSource {
    static let planetary = """
// ---------- per-frame: planetary nebula ----------
// A dying star's shed envelope, lit by the hot white dwarf left behind. Every layer is optically
// thin glowing gas, so each is drawn as its column along the ray: the length of the chord through
// it (found in closed form) times a 3D texture sampled where the ray is inside it. A uniform shell
// seen this way brightens toward its edge, which is what makes the ring.
//
// S.a = barrel axis (unit), outer equatorial radius R
// S.b = inner gas color (doubly ionized oxygen), elongation (polar semi-axis / R)
// S.c = rim color (hydrogen and nitrogen), knots (0..1.5)
// S.d = halo color, halo on (0/1)
// S.e = x unused, y seed, z ejected shell radius (fraction of R, 0 = none), w its brightness
// S.f = central star color, w = brightness

// Where a ray is inside a spheroid with equatorial radius a and polar semi-axis c along ax:
// (enter, exit) in ray lengths, enter > exit when it misses.
static float2 spheroidSpan(float3 ro, float3 rd, float3 ax, float a, float c) {
    float k = 1.0 / c - 1.0 / a;
    float3 o = ro / a + ax * (dot(ro, ax) * k);
    float3 d = rd / a + ax * (dot(rd, ax) * k);
    float A = dot(d, d), B = dot(o, d), C = dot(o, o) - 1.0;
    float disc = B * B - A * C;
    if (disc <= 0.0) return float2(1.0, 0.0);
    float q = sqrt(disc);
    return float2((-B - q) / A, (-B + q) / A);
}

static float2 sphereSpan(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd), disc = b * b - (dot(ro, ro) - r * r);
    if (disc <= 0.0) return float2(1.0, 0.0);
    float q = sqrt(disc);
    return float2(-b - q, -b + q);
}

static float spanLength(float2 s) { return max(s.y - s.x, 0.0); }

// The rim's gas: bright clumps with dark gaps and dust lanes between them, and filaments
// streaming outward from the star. Thin over the barrel's open ends, so looking down its axis
// shows the inner glow rather than a red cap.
static float pnRimTexture(float3 x, float3 ax, float R, float T, float seed) {
    float r = length(x);
    float3 u = x / max(r, 1e-4);
    float caps = 1.0 - 0.97 * smoothstep(0.35, 0.8, abs(dot(u, ax)));
    float clumps = fbm(x / R * 3.2 + float3(seed, 0.0, T * 0.004));
    float fil = fbm(u * 7.0 + float3(seed * 0.7, 0.0, r / R * 1.6 - T * 0.006));
    float streaks = pow(1.0 - abs(2.0 * fil - 1.0), 3.0);
    float lanes = smoothstep(0.52, 0.68, fbm(x / R * 6.5 + float3(seed + 2.0, T * 0.003, 0.0)));
    float body = 0.06 + 2.4 * pow(smoothstep(0.36, 0.76, clumps), 1.6);
    return caps * body * (0.4 + 1.3 * streaks) * (1.0 - 0.75 * lanes);
}

// The rim's color across its thickness (s: 0 at the inner edge, 1 at the outer): golden where it
// meets the oxygen glow, the picked color through the middle, crimson to magenta at the outside.
static float3 pnRimColor(float3 c, float s) {
    float3 gold = c * float3(1.0, 1.9, 0.55) + float3(0.0, 0.03, 0.0);
    float3 deep = c * float3(0.95, 0.5, 1.3);
    return s < 0.45 ? mix(gold, c, smoothstep(0.0, 0.45, s)) : mix(c, deep, smoothstep(0.45, 1.0, s));
}

// Normalized spheroidal radius: 1 on the surface with equatorial radius R.
static float pnRadius(float3 x, float3 ax, float R, float el) {
    float h = dot(x, ax);
    return length(x - ax * h + ax * (h / el)) / R;
}

// The rim's light along the ray: the front and back walls of a thick shell, each textured at its
// middle, so the texture is the same 3D gas from any viewing angle. The wall lengths are averaged
// over a few nested shells (and the outer edge is roughened by `jitter`), so both edges fade out
// rather than end on a line.
static float3 pnShell(float3 ro, float3 rd, float3 ax, float R, float el, float jitter, float3 colRim,
                      float T, float seed) {
    float front = 0.0, back = 0.0;
    float2 outer = float2(1.0, 0.0);
    for (int k = 0; k < 3; k++) {
        float ko = (0.8 + 0.16 * float(k)) * jitter, ki = 0.6 + 0.09 * float(k);
        float2 so = spheroidSpan(ro, rd, ax, R * ko, R * el * ko);
        if (so.x >= so.y) continue;
        float2 si = spheroidSpan(ro, rd, ax, R * ki, R * el * ki);
        if (si.x < si.y) {
            front += si.x - so.x;
            back += so.y - si.y;
        } else {
            front += 0.5 * (so.y - so.x);
            back += 0.5 * (so.y - so.x);
        }
        outer = so;
    }
    if (outer.x >= outer.y) return float3(0.0);
    // Texture each wall a fixed depth in from where the ray enters (or leaves) the outermost shell,
    // capped at the middle of the chord: the sample points move smoothly from pixel to pixel.
    float depth = min(0.2 * R, 0.5 * (outer.y - outer.x));
    float3 pf = ro + rd * (outer.x + depth), pb = ro + rd * (outer.y - depth);
    // The color gradient: looking down the barrel it follows where the ray passes the star, so it
    // runs cleanly across the ring; seen from the side, where that says little, it follows each
    // wall's own distance from the star.
    float ca = abs(dot(ax, normalize(-ro)));
    float sp = saturate((pnRadius(ro + rd * dot(-ro, rd), ax, R, el) - 0.6) / 0.5);
    float sf = mix(saturate((pnRadius(pf, ax, R, el) - 0.8) / 0.35), sp, ca * ca);
    float sb = mix(saturate((pnRadius(pb, ax, R, el) - 0.8) / 0.35), sp, ca * ca);
    return (front * pnRimTexture(pf, ax, R, T, seed) * pnRimColor(colRim, sf)
          + back * pnRimTexture(pb, ax, R, T, seed + 3.1) * pnRimColor(colRim, sb)) / 3.0;
}

// Cometary knots around the inside of the rim, as in the Helix: dense droplets of gas lit on the
// side facing the star, with a darker head and a shadowed tail trailing away from it. Each one
// differs: size, stretch, how far round its lit side wraps and which way it leans, brightness,
// tail length and curl, and color (from the rim's gradient, now and then nearly white-hot); some
// are only dark smudges. Placed on a grid in the nebula's projected ellipse (angle and normalized
// radius), so each pixel only checks a few cells. Returns (light, absorption).
static float4 pnKnots(float3 X, float3 v, float3 ap, float3 bp, float sa, float R, float amount,
                      float3 colRim, float pixW, float T, float seed) {
    float2 q = float2(dot(X, ap) / sa, dot(X, bp) / R);
    float rho = length(q);
    const float rho0 = 0.6, dr = 0.075;
    const int N = 72;
    if (rho < rho0 - 2.0 * dr || rho > rho0 + 6.0 * dr) return float4(0.0);
    float th = atan2(q.y, q.x);
    int ci = int(floor((th / 6.2831853 + 0.5) * float(N)));
    int cj = int(floor((rho - rho0) / dr));
    float3 light = float3(0.0);
    float absorb = 0.0;
    for (int dj = -2; dj <= 1; dj++) {
        int j = cj + dj;
        if (j < 0 || j > 4) continue;
        for (int di = -1; di <= 1; di++) {
            int i = (ci + di + N) % N;
            float3 h3 = float3(float(i), float(j), seed);
            // denser toward the inner edge, where the knots are freshest
            float keep = amount * (0.42 - 0.07 * float(j));
            if (hash13(h3) > keep) continue;
            float tk = (float(i) + 0.15 + 0.7 * hash13(h3 + 1.7)) / float(N) * 6.2831853 - 3.14159265;
            float rk = rho0 + (float(j) + 0.15 + 0.7 * hash13(h3 + 4.3)) * dr;
            float3 K = ap * (cos(tk) * rk * sa) + bp * (sin(tk) * rk * R);
            float3 er = normalize(K), et = cross(v, er);
            float3 d = X - K;
            float along = dot(d, er), perp = dot(d, et);
            float hA = hash13(h3 + 11.1), hB = hash13(h3 + 13.7), hC = hash13(h3 + 17.3);
            float hD = hash13(h3 + 19.9), hE = hash13(h3 + 23.5), hF = hash13(h3 + 29.3);
            float h = max(R * (0.012 + 0.022 * hash13(h3 + 7.9) * hash13(h3 + 8.3)), pixW * 1.4);
            // the head: an egg stretched along the line to the star, leaning a little to one side
            float lean = (hA - 0.5) * 1.1;
            float cl = cos(lean), sl = sin(lean);
            float a2 = cl * along + sl * perp, p2 = -sl * along + cl * perp;
            float stretch = 1.0 + 1.4 * hB;
            float hd = length(float2(a2 / (h * stretch), p2 / h));
            // lit side: a soft glow that wraps further round some knots than others
            float wrap = mix(0.6, -0.3, hC);
            float side = smoothstep(wrap, -1.0, a2 / (h * stretch));
            float lit = exp(-sq((hd - 0.85) / 0.6)) * side + 0.05 * exp(-hd * hd);
            float bright = hF < 0.15 ? 0.0 : 0.35 + 1.3 * hD * hD;      // some are only dark smudges
            float flick = 0.85 + 0.3 * noise3(float3(float(i), float(j), T * 0.12));
            float3 kc = pnRimColor(colRim, 0.3 + 0.6 * hE);
            if (hE > 0.93) kc = mix(kc, float3(1.0, 0.92, 0.8), 0.55);
            light += kc * lit * bright * flick;
            // a tail curling slightly as it trails away
            float L = h * (2.0 + 6.0 * hash13(h3 + 2.2));
            float curl = (hash13(h3 + 31.1) - 0.5) * 1.2 / L;
            float pc = perp - curl * along * along;
            float tail = along > 0.0 ? exp(-sq(pc / (h * (0.7 + 0.6 * along / L)))) * exp(-along / L) : 0.0;
            absorb = max(absorb, max(exp(-hd * hd * 1.2) * (0.35 + 0.4 * hB), tail * (0.2 + 0.35 * hA)));
        }
    }
    return float4(light, absorb);
}

fragment float4 planetaryFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = F.time;
    float3 ax = S.a.xyz;
    float R = S.a.w, el = S.b.w, seed = S.e.y;
    float3 colIn = S.b.rgb, colRim = S.c.rgb, colHalo = S.d.rgb;
    float tc = -dot(ro, rd);
    float3 X = ro + rd * tc;               // closest point to the star, in the plane facing us
    float dmin = length(X);
    float pixW = F.pixelAngle * length(ro);
    float3 col = SKY(p, rd, false);

    float3 neb = float3(0.0);
    float absorb = 0.0;
    float3 knotLight = float3(0.0);
    if (dmin < R * 3.6) {
        // the rim: hydrogen and nitrogen in a thick barrel, with a faint skirt beyond it
        float jitter = 0.9 + 0.22 * fbm(normalize(X + 1e-4) * 1.7 + float3(seed, 1.0, 0.0));
        neb += pnShell(ro, rd, ax, R, el, jitter, colRim, T, seed) * 0.24;
        // a faint, uneven skirt fading out beyond the rim
        float skirt = exp(-pow(max(dmin - 0.9 * R, 0.0) / (0.45 * R), 1.5)) * smoothstep(0.55 * R, 0.95 * R, dmin);
        neb += pnRimColor(colRim, 1.0) * skirt * 0.14 * sq(fbm(X / R * 2.2 + seed + 4.0));

        // the inside: oxygen ionized twice over by the star's hard light, thinning at the very middle
        float inner = 0.0;
        for (int k = 0; k < 4; k++) {
            float ki = 0.54 + 0.11 * float(k);
            inner += spanLength(spheroidSpan(ro, rd, ax, R * ki, R * el * ki * 1.04));
        }
        if (inner > 0.0) {
            float tex = 0.45 + 1.1 * pow(fbm(X / R * 2.4 + float3(seed + 5.0, 0.0, T * 0.006)), 1.5);
            float hollow = spanLength(spheroidSpan(ro, rd, ax, R * 0.32, R * el * 0.32));
            // hotter and bluer toward the star, greener toward the rim
            float c = saturate(dmin / (0.7 * R));
            float3 tint = mix(colIn * float3(0.55, 0.8, 1.5), colIn * float3(0.8, 1.15, 0.75), c * c);
            neb += tint * (inner / 4.0 - 0.55 * hollow) * tex * 0.046;
        }

        // the halo: older, fainter shells from earlier puffs, drifting outward and fading
        if (S.d.w > 0.5) {
            // a soft glow falling away beyond the rim, and the thin edges of older shells
            float out_ = smoothstep(0.9 * R, 1.3 * R, dmin) * exp(-max(dmin - 1.1 * R, 0.0) / (0.6 * R)) * smoothstep(3.5 * R, 2.2 * R, dmin);
            neb += colHalo * out_ * 0.03 * pow(fbm(X / R * 1.8 + seed + 9.0) * 1.6, 2.5);
            for (int k = 0; k < 4; k++) {
                float ph = fract(T / 400.0 + float(k) * 0.25);
                float rr = R * (1.15 + 0.85 * ph), w = R * 0.07;
                // a thin shell seen edge-on: a soft ring at its radius, broken into arcs
                float ring = exp(-sq((dmin - rr) / w));
                if (ring < 0.01) continue;
                float3 u = normalize(X + 1e-4);
                float arcs = smoothstep(0.4, 0.75, fbm(u * 2.2 + float3(float(k) * 7.3 + seed, 0.0, 0.0)));
                float life = sq(sin(3.14159265 * ph)) * (1.0 - 0.6 * ph);
                neb += mix(colHalo, colHalo * float3(1.0, 0.6, 1.4), ph) * ring * arcs * life * 0.09;
            }
        }

        // a fresh shell blown off the star (event)
        if (S.e.w > 0.001) {
            // seen edge-on it's a soft bright ring at its radius, with a fainter fill across it
            float rr = S.e.z * R, w = R * (0.05 + 0.06 * S.e.z);
            float shell = exp(-sq((dmin - rr) / w)) + 0.25 * smoothstep(rr, 0.5 * rr, dmin);
            float clumpy = 0.55 + 0.9 * fbm(normalize(X + 1e-4) * 4.0 + float3(seed, 3.0, 0.0));
            neb += mix(colIn, float3(1.0, 0.95, 0.9), 0.35) * shell * clumpy * S.e.w * 0.32;
        }

        // the cometary knots
        if (S.c.w > 0.0) {
            float3 v = normalize(-ro);
            float3 ap = ax - v * dot(ax, v);
            ap = length(ap) > 1e-3 ? normalize(ap) : F.camRight.xyz;
            float3 bp = cross(v, ap);
            float ca = abs(dot(ax, v));
            float sa = R * sqrt(el * el * (1.0 - ca * ca) + ca * ca);
            // the knots are placed on the projected ring, which only matches the barrel's inner
            // edge when we look down it; seen from the side they thin out
            float4 kn = pnKnots(X, v, ap, bp, sa, R, S.c.w * mix(0.15, 1.0, smoothstep(0.35, 0.85, ca)), colRim, pixW, T, seed);
            knotLight = kn.rgb;
            absorb = kn.w;
        }
    }
    col = (col + neb) * (1.0 - 0.8 * absorb);
    col += knotLight * 0.9;

    // the white dwarf: tiny and very hot, with a soft blue glow of its own
    float core = max(pixW * 0.9, R * 0.006);
    col += S.f.rgb * S.f.w * (exp(-(dmin * dmin) / (core * core)) * 5.0 + exp(-dmin / (R * 0.05)) * 0.35 + exp(-dmin / (R * 0.25)) * 0.05);
    return finalize(col, p, F);
}
"""
}
