extension ShaderSource {
    static let blackHoleMerger = """
// ---------- per-frame: black hole merger ----------
// The neutron star merger's loop with black holes: a remnant waits, a companion falls in and is
// worn down by gravitational waves into the chirp, and the two shadows run together into one
// that rings down. Nothing here shines on its own, so the holes show by their shadows, thin
// photon rings and the light they bend. Lensing is done per pixel as two point lenses: a ray
// passing at angle theta from a lens sees the sky at theta - thetaE^2 / theta, which draws each
// star behind a hole into arcs and a ring. What surrounds the pair depends on its size (S.g.w):
// 0 empty space (stellar), 1 a dense star cluster (intermediate), 2 a gas disk with a cleared
// cavity, mini-disks, streams and jets (supermassive).
//
// S.a = remnant center, shadow radius        S.b = companion center, shadow radius
// S.c = orbit normal, wave strength          S.d = orbit basis e1, tau (minus the time since the last merger)
// S.e = photon ring color, the companion's presence for the gas (it fades over seconds after the merger)
// S.f = hot color, age since the last merger S.g = cool color, model
// S.h = K, phi0, tauC, unequal-mass harmonic weight
// S.i = remnant Einstein radius, companion Einstein radius, remnant spin, photon ring boost
// S.j = ringdown angular frequency, ringdown decay time, gas cavity radius, afterglow
// S.k = remnant spin axis, jet strength      S.l = the last remnant's spin axis, its jets' strength
// S.m = disk normal (the total angular momentum, or the quasar disk's), the binary's angle in the orbital plane (for the gas)
// S.n = periapsis angle, eccentricity kept through the chirp, rosette rate, lobes (1 for the pair, fading after the merger)
// S.o = system center (the recoil kick moves it), flags (1 strain trace, 2 background galaxy)
// S.p = remnant velocity, the scene's own time (its Speed applied)
// (S.j.w is the supermassive disk's refill glow, or the quasar disk's flare)

constant float BBH_V = 0.6;        // wave speed

// Reflects a pixel coordinate back into [0, n): a lensed ray leaving the frame takes the sky from
// the mirrored side, which a random star field doesn't give away.
static int bbhMirror(int x, int n) {
    int m = 2 * n;
    x = x % m;
    if (x < 0) x += m;
    return x < n ? x : m - 1 - x;
}

// Point lens at c with Einstein radius rE (world units at the lens). Returns the shift that takes
// rd to the direction it sees, the impact distance b at the lens, and the unit offset from it.
static float3 bbhLens(float3 ro, float3 rd, float3 c, float rE, thread float& b, thread float3& perp) {
    float3 oc = c - ro;
    float dist = length(oc);
    float3 l = oc / dist;
    float3 v = rd - l * dot(rd, l);
    float th = max(length(v), 1e-6);
    b = th * dist;
    perp = v / th;
    float thE = rE / dist;
    return -perp * min(thE * thE / th, 0.5);
}

// How much farther than a circle's edge a point lies on an outline stretched by e along axis
// (seen from direction l; the stretch shows less as the axis turns toward us). Area is kept.
static float bbhStretch(float3 perp, float3 l, float3 axis, float e) {
    float3 a = axis - l * dot(axis, l);
    float la = length(a);
    if (la < 1e-4 || e <= 0.0) return 1.0;
    float ee = e * min(la / max(length(axis), 1e-4), 1.0);
    float c = dot(perp, a / la);
    return sqrt(c * c / sq(1.0 + ee) + (1.0 - c * c) * (1.0 + ee));
}

static float bbhSmin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// A jet from o along axis j (both ways): a thin bright spine in a soft sheath, with knots
// moving out. Fades toward its tips rather than ending on an edge.
static float bbhJet(float3 ro, float3 rd, float3 o, float3 j, float T, float pixW) {
    float3 w = ro - o;
    float b = dot(rd, j), e = dot(j, w), dd = dot(rd, w);
    float den = max(1.0 - b * b, 1e-4);
    float t = (b * e - dd) / den;
    if (t <= 0.0) return 0.0;
    float s = e + t * b;
    float as = abs(s);
    if (as > 13.0) return 0.0;
    float d = length(w + rd * t - j * s);
    float wd = 0.07 + 0.045 * as;
    float knots = 0.55 + 0.9 * sq(noise3(float3(as * 0.9 - T * 0.8, s > 0.0 ? 0.0 : 7.0, 0.0)));
    float along = smoothstep(0.4, 1.5, as) * (1.0 - smoothstep(5.0, 13.0, as));
    float wc = max(wd * 0.22, pixW * 0.7);
    return ((exp(-sq(d / wd)) * knots * 0.5 + exp(-d / (wd * 3.0)) * 0.12)
            + exp(-sq(d / wc)) * (wd * 0.22 / wc) * 0.15) * along;
}

// The supermassive pair's gas at X in the disk plane: emission and opacity. A circumbinary disk
// with a cleared middle, a lump riding its inner edge, two streams falling from that edge to
// mini-disks around each hole, hotter (bluer) inward and brighter on the side turning toward us.
static float4 bbhGas(float3 X, float3 rd, float3 nD, float3 cA, float3 cB, float rA, float rB, float3 bDir,
                     float presence, float sep, float cavity, float afterglow,
                     float3 hotCol, float3 coolCol, float T) {
    float3 g1 = normalize(abs(nD.y) < 0.9 ? cross(nD, float3(0.0, 1.0, 0.0)) : cross(nD, float3(1.0, 0.0, 0.0)));
    float3 g2 = cross(nD, g1);
    float2 P = float2(dot(X, g1), dot(X, g2));
    float rho = length(P);
    if (rho > 20.0) return float4(0.0);
    float th = atan2(P.y, P.x);
    float phB = atan2(dot(bDir, g2), dot(bDir, g1));

    // Keplerian shear without winding up forever: two copies of the texture, each sheared for
    // at most one flow period, cross-faded as they reset.
    float om = 0.9 * pow(max(rho, 0.6), -1.5);
    const float per = 40.0;
    float f1 = fract(T / per), f2 = fract(T / per + 0.5);
    float a1 = th - om * f1 * per, a2 = th - om * f2 * per;
    float t1 = fbm(float3(cos(a1) * rho, sin(a1) * rho, rho * 0.5) * 0.55);
    float t2 = fbm(float3(cos(a2) * rho, sin(a2) * rho, rho * 0.5 + 9.0) * 0.55);
    float tex = mix(t1, t2, abs(2.0 * f1 - 1.0));

    // the circumbinary disk: brightest just outside the cavity, two arms raised by the binary
    float inner = smoothstep(cavity * 0.75, cavity * 1.25, rho);
    float prof = inner * exp(-rho / 4.5) * (1.0 - smoothstep(11.0, 20.0, rho)) * 1.1 * pow(cavity / max(rho, cavity * 0.75), 0.5);
    float arms = 1.0 + 0.45 * presence * cos(2.0 * (th - phB) + 2.2 * log(max(rho / cavity, 0.2)));
    float lump = 1.0 + 1.2 * presence * exp(-sq((rho - 1.25 * cavity) / (0.3 * cavity)))
                     * (0.5 + 0.5 * cos(th - T * 0.9 * pow(1.25 * cavity, -1.5)));
    float dens = prof * arms * lump * (0.35 + 1.3 * sq(tex));

    // streams from the cavity's edge down to the holes, trailing their orbit
    float inside = 1.0 - smoothstep(cavity * 0.9, cavity * 1.3, rho);
    float sp = 0.5 + 0.5 * cos(2.0 * (th - phB) - 3.0 * log(max(rho / cavity, 0.05)));
    float stream = pow(sp, 10.0) * inside * smoothstep(0.4 * sep, 0.9 * sep + 0.3, rho) * presence;
    dens += stream * (0.5 + tex) * 0.9;

    // mini-disks around each hole, and the remnant's own inner disk when it is alone
    float3 hot = float3(0.0);
    for (int i = 0; i < 2; i++) {
        float3 c = i == 0 ? cA : cB;
        float r = i == 0 ? rA : rB;
        float w = i == 0 ? mix(1.0, 0.6, presence) : presence;
        if (w <= 0.0 || r <= 0.0) continue;
        float size = i == 0 ? mix(1.6, clamp(0.3 * sep, 0.4, 1.6), presence) : clamp(0.3 * sep, 0.2, 1.4);
        float d = length(X - c);
        float md = exp(-(d - r) / (0.35 * size)) * smoothstep(r, r * 2.5, d) * (1.0 - smoothstep(size, size * 2.2, d));
        float boost = i == 0 ? 1.0 + 2.0 * afterglow : 1.0;
        md *= (0.6 + 0.8 * tex) * boost * w;
        dens += md * 1.5;
        hot += hotCol * md * 1.6;
    }
    if (dens < 1e-4) return float4(0.0);
    // temperature falls as r^(-3/4): hot near the middle, cool and red outside
    float heat = saturate(1.4 * pow(cavity / max(rho, 0.3), 0.75) - 0.35);
    float3 c = nsmMix(coolCol, hotCol, heat * 0.7);
    // Doppler: the side turning toward us is brighter
    float3 vdir = normalize(cross(nD, X / max(rho, 1e-3)));
    float beam = 1.0 + 0.5 * dot(vdir, -rd) * saturate(1.5 / sqrt(max(rho, 0.5)));
    float3 em = (c * (dens - min(dens, length(hot) / 1.6)) + hot) * beam * (1.0 + 0.6 * afterglow * heat) * 0.6;
    float alpha = 1.0 - exp(-dens * 2.5);
    return float4(em, alpha);
}

// The wave signal leaving the pair at tr (the time left before the merger then): amplitude, the
// orbit's angle, the orbital angular frequency (negative for the ringdown's), and the strain a
// detector sees, 1 at the merger (it grows as the frequency to the 2/3).
static float4 bbhSignal(float tr, constant SceneParams& S) {
    float K = S.h.x, phi0 = S.h.y, tauC = S.h.z;
    float qnmW = S.j.x, qnmT = S.j.y;
    if (tr > 0.0 && tr < tauC) {
        float trc = max(tr, 0.03);
        float omega = 0.625 * K * pow(trc, -0.375);
        float phiR = phi0 - K * pow(trc, 0.625);
        float fade = smoothstep(tauC, tauC * 0.6, tr);
        float amp = min(pow(omega / 0.4, 0.667), 2.2) * fade;
        float strain = pow(omega / (0.625 * K * 3.72), 0.667) * fade;    // 3.72 = 0.03^(-3/8)
        float ecc = S.n.y * smoothstep(0.3, 4.0, tr);
        if (ecc > 0.0) {
            // On an eccentric orbit the waves come in bursts at each close pass, where the
            // holes move fastest: Kepler's equation gives where the companion was.
            float peri = S.n.x;
            float m = phiR - peri;
            float E = m + ecc * sin(m);
            for (int i = 0; i < 4; i++) E -= (E - ecc * sin(E) - m) / (1.0 - ecc * cos(E));
            float nu = 2.0 * atan2(sqrt(1.0 + ecc) * sin(0.5 * E), sqrt(1.0 - ecc) * cos(0.5 * E));
            float rr = 1.0 - ecc * cos(E);
            amp *= pow(1.0 - ecc, 1.5) / (rr * rr);
            strain *= pow(1.0 - ecc, 1.5) / (rr * rr);
            omega *= sqrt(1.0 - ecc * ecc) / (rr * rr);
            phiR = nu + peri - S.n.z * K * pow(trc, 0.625);
        }
        return float4(amp, phiR, omega, strain);
    }
    // the ringdown picks up where the inspiral's phase left off
    if (tr <= 0.0 && tr > -6.0 * qnmT)
        return float4(2.2 * exp(tr / qnmT), phi0 - K * 0.112 + 0.5 * qnmW * tr, -qnmW, exp(tr / qnmT));   // 0.112 = 0.03^(5/8)
    return float4(0.0);
}

// A spiral galaxy far behind the pair, a little off the line through it, so the holes draw it
// into an Einstein ring that breaks into arcs as they move. dir is the (lensed) direction seen.
static float3 bbhGalaxy(float3 dir, float3 ro, constant FrameParams& F) {
    float dist = length(ro);
    float3 l0 = -ro / dist;
    float3 v = (dir - l0 * dot(dir, l0)) * dist;
    float2 w = float2(dot(v, F.camRight.xyz), dot(v, F.camUp.xyz)) - float2(0.45, 0.3);
    float ca = cos(0.6), sa = sin(0.6);
    float2 g = float2(ca * w.x + sa * w.y, (-sa * w.x + ca * w.y) / 0.5);    // tilted to us
    float r = length(g);
    if (r > 5.0) return float3(0.0);
    float th = atan2(g.y, g.x);
    float arms = 0.5 + 0.5 * cos(2.0 * th - 3.0 * log(max(r, 0.05)));
    float bulge = exp(-r / 0.2);
    float disk = exp(-r / 0.75) * (0.3 + 1.1 * pow(arms, 3.0)) * smoothstep(0.05, 0.35, r);
    // pink star-forming knots along the arms
    float knots = smoothstep(0.62, 0.8, noise3(float3(g * 5.0, 2.0))) * pow(arms, 4.0) * exp(-r / 1.2);
    return float3(1.0, 0.78, 0.5) * bulge * 1.2 + float3(0.45, 0.65, 1.0) * disk * 0.65
         + float3(1.0, 0.3, 0.6) * knots * 1.0;
}

// A quasar's gas disk around a stellar pair. The disk circles a supermassive hole far beyond the
// frame, so here it is a broad sheet flowing one way, faster on the side nearer that hole
// (shear), brighter toward it. The pair has blown a small hollow. After the merger the kicked
// remnant heats the gas round it (the flare) and leaves a hot wake along its path.
static float4 bbhAgn(float3 X, float3 nD, float3 cA, float rA, float3 cB, float rB, float flare, float3 vel,
                     float3 hotCol, float3 coolCol, float T) {
    float3 g1 = normalize(abs(nD.y) < 0.9 ? cross(nD, float3(0.0, 1.0, 0.0)) : cross(nD, float3(1.0, 0.0, 0.0)));
    float3 g2 = cross(nD, g1);
    float2 P = float2(dot(X, g1), dot(X, g2));
    float R = length(P);
    if (R > 60.0) return float4(0.0);
    const float per = 50.0;
    float f1 = fract(T / per), f2 = fract(T / per + 0.5);
    float sp0 = 0.35 + 0.02 * P.y;
    float t1 = fbm(float3((P.x - sp0 * f1 * per) * 0.3, P.y * 0.45, 0.0));
    float t2 = fbm(float3((P.x - sp0 * f2 * per) * 0.3, P.y * 0.45, 5.0));
    float tex = mix(t1, t2, abs(2.0 * f1 - 1.0));
    float dens = (0.25 + 1.1 * sq(tex)) * min(exp(P.y / 18.0), 1.6) * (1.0 - smoothstep(25.0, 60.0, R));
    float d = length(X - cA);
    float hollow = smoothstep(rA * 1.5, rA * 7.0, d) * (rB > 0.0 ? smoothstep(rB * 1.5, rB * 7.0, length(X - cB)) : 1.0);
    dens *= hollow;
    float3 em = nsmMix(coolCol, hotCol, saturate(0.15 + 0.45 * tex)) * dens * 0.1;
    em += hotCol * flare * exp(-d / 2.2) * (0.3 + 0.4 * tex) * smoothstep(rA * 1.2, rA * 3.0, d);
    float sp = length(vel);
    if (sp > 1e-3) {
        float3 vd = vel / sp;
        float along = dot(X - cA, -vd);
        float off = length(X - cA + vd * along);
        float wk = exp(-sq(off / (0.25 + 0.06 * max(along, 0.0)))) * smoothstep(0.0, 0.6, along) * exp(-max(along, 0.0) / 4.0);
        em += hotCol * wk * min(sp * 3.0, 1.2);
    }
    return float4(em, 1.0 - exp(-dens * 0.45));
}

// The strain a detector would record at tr, scaled to about -1..1, with a little detector noise.
static float bbhStrain(float tr, constant SceneParams& S) {
    float4 sig = bbhSignal(tr, S);
    float noise = 0.05 * (hash13(float3(floor(tr * 160.0), 3.0, 1.0)) - 0.5);
    return sig.w * cos(2.0 * sig.y) + noise;
}

fragment float4 blackHoleMergerFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float T = S.p.w;
    int flags = int(S.o.w + 0.5);

    float3 cA = S.a.xyz, cB = S.b.xyz, n = S.c.xyz, e1 = S.d.xyz, e2 = cross(n, e1);
    float rA = S.a.w, rB = S.b.w;
    float tau = S.d.w, presence = S.e.w, age = S.f.w;
    float3 ringCol = S.e.rgb, hotCol = S.f.rgb, coolCol = S.g.rgb;
    int model = int(S.g.w + 0.5);
    float harm = S.h.w;
    float3 O = S.o.xyz;
    float chi = S.i.z, ringBoost = S.i.w;
    float qnmW = S.j.x, qnmT = S.j.y, cavity = S.j.z, afterglow = S.j.w;
    // two lobes: the pair, or, just after the merger, the remnant's two lobes running together
    bool pair = S.b.w > 0.0;
    float pixW = F.pixelAngle * length(ro);
    float sep = length(cB - cA);
    float W = S.c.w;

    // ---- lensing: the direction each pixel sees, past both holes ----
    float bA, bB = 1e9;
    float3 perpA, perpB = float3(0.0);
    float3 shift = bbhLens(ro, rd, cA, S.i.x, bA, perpA);
    if (pair) shift += bbhLens(ro, rd, cB, S.i.y, bB, perpB);
    float3 rs = normalize(rd + shift);

    // ---- the shadows: one per hole, run together as they touch ----
    // In the last moments tides stretch each shadow toward the other, and they join through a
    // widening neck. After the merger the two lobes keep turning as they run together (the
    // CPU side moves them), a peanut rounding out as the ringdown carries its lumps away.
    float dC = 0.8 * (rA + rB);
    float3 axis = cB - cA;
    float tide = 0.0, neck = 0.0;
    if (pair) {
        tide = 0.35 * smoothstep(2.2 * dC, 1.05 * dC, sep) * S.n.w;
        neck = 0.6 * rB * smoothstep(1.6 * dC, 1.05 * dC, sep);
    }
    // The remnant spins: its shadow is flattened and shifted on the side turning toward us
    // (photons going with the spin can orbit closer), most when we see the spin side-on.
    float3 lA = normalize(cA - ro);
    float3 sAx = S.k.xyz - lA * dot(S.k.xyz, lA);
    float side = length(sAx);
    float3 wA = side > 1e-3 ? cross(lA, sAx / side) : F.camRight.xyz;
    float flat_ = 0.2 * chi * side;
    float x = dot(perpA, wA);
    float rAe = rA * (1.0 + 0.04 * flat_ - flat_ * sq(max(x, 0.0)));
    float dA = bA * bbhStretch(perpA, lA, axis, tide) - rAe;
    float dS = dA, rRef = rA;
    if (pair) {
        float dB = bB * bbhStretch(perpB, normalize(cB - ro), axis, tide) - rB;
        dS = bbhSmin(dA, dB, 0.45 * rB + 0.02 + neck);
        if (dB < dA) rRef = max(rB, 0.15);
    }
    float soft = max(pixW * 0.9, 0.025 * rRef);
    float shadow = 1.0 - smoothstep(-soft, soft, dS);
    // close to the shadow the lensed sky is too crushed to resolve: it fades into the ring
    float crush = smoothstep(0.15 * rRef, 0.9 * rRef, dS);

    // ---- gravitational waves in the orbital plane, as in the neutron star merger ----
    float dn = dot(rd, n);
    float tp = -dot(ro - O, n) / (abs(dn) > 1e-4 ? dn : 1e-4);
    float wave = 0.0;
    float2 disp = float2(0.0);
    if (tp > 0.0 && W > 0.0) {
        float3 xp = ro + rd * tp - O;
        float rho = length(xp);
        float tr = tau + rho / BBH_V;
        float th = atan2(dot(xp, e2), dot(xp, e1));
        float foot = F.pixelAngle * tp / max(abs(dn), 0.05);
        float4 sig = bbhSignal(tr, S);
        float amp = sig.x, psi = 2.0 * (th - sig.y), h3 = 0.0;
        // waves shorter than a few pixels would only alias: fade them out
        amp *= smoothstep(foot * 4.0, foot * 10.0, 3.14159 * BBH_V / abs(sig.z + 1e-4));
        if (sig.z > 0.0) {
            // an unequal pair also radiates at three times the orbital frequency: a third arm
            h3 = harm * 0.6 * min(pow(sig.z / 0.6, 0.333), 1.6);
            // the calm near zone round the source: the pair's size, at least the joined shadow's,
            // so it doesn't vanish when the companion does
            float src = max(pair ? sep : 0.0, 0.8 * (rA + rB));
            amp *= smoothstep(0.5 * src, 1.5 * src + 0.5, rho);
        }
        amp *= smoothstep(0.3, 1.4, rho) / (1.0 + rho / 6.0);
        wave = amp * (cos(psi) + h3 * cos(1.5 * psi));
        float3 er = xp / max(rho, 1e-3);
        float gw = amp * (sin(psi) + h3 * 1.5 * sin(1.5 * psi)) * W;
        disp = float2(dot(er, F.camRight.xyz), -dot(er, F.camUp.xyz)) * gw * 2.4;
    }

    // ---- the sky, seen through both lenses and the waves ----
    float2 lp = float2(dot(rs - rd, F.camRight.xyz), -dot(rs - rd, F.camUp.xyz)) / F.pixelAngle;
    int2 qp = int2(p) + int2(round(lp + disp));
    int Wd = int(F.camRight.w), Hd = int(F.camUp.w);
    uint2 q = uint2(bbhMirror(qp.x, Wd), bbhMirror(qp.y, Hd));
    float3 col = SKY(q, rs, false) * crush;
    col *= clamp(1.0 + 0.06 * wave * W, 0.75, 1.3);
    // a faint sheen on the wavefronts against the dark
    col += ringCol * sq(max(wave, 0.0)) * 0.004 * W;
    if ((flags & 2) != 0) col += bbhGalaxy(rs, ro, F) * crush;

    // ---- an intermediate pair's star cluster, lensed like the sky ----
    if (model == 1) {
        float3 toCam = normalize(ro);
        float tz = -dot(ro, toCam) / min(dot(rs, toCam), -1e-3);
        float3 X = ro + rs * tz;
        float2 w2 = float2(dot(X, F.camRight.xyz), dot(X, F.camUp.xyz));
        const float rc = 4.5;
        float r2 = dot(w2, w2) / (rc * rc);
        float king = pow(1.0 + r2, -1.5);
        // unresolved stars: a soft warm glow
        float3 glow = mix(coolCol, float3(dot(coolCol, float3(0.33))), 0.4) * (0.05 * king + 0.006 / (1.0 + r2));
        float3 stars = float3(0.0);
        float cs = pixW * 6.0;
        for (int L = 0; L < 3; L++) {
            // each layer of orbits turns its own way: a cluster's stars move every which way
            float om = L == 0 ? 0.012 : (L == 1 ? -0.008 : 0.005);
            float ca = cos(om * T), sa = sin(om * T);
            float2 wr = float2(ca * w2.x - sa * w2.y, sa * w2.x + ca * w2.y);
            float2 cell = floor(wr / cs);
            float3 hs = float3(cell, float(L) * 17.0 + 3.0);
            float h0 = hash13(hs), h1 = hash13(hs + 11.0), h2 = hash13(hs + 23.0), h3s = hash13(hs + 37.0);
            if (h0 > 0.5 * king + 0.01) continue;
            float2 c = (cell + 0.2 + 0.6 * float2(h1, h2)) * cs;
            float d = length(wr - c);
            float br = 0.15 + 2.5 * pow(h3s, 6.0);
            float sz = pixW * (0.55 + 0.5 * h3s);
            // mostly old red giants, some hot blue stragglers
            float3 sc = h1 > 0.8 ? hotCol : mix(coolCol, float3(dot(coolCol, float3(0.33))) * 1.2, 0.5 * h2);
            stars += sc * br * exp(-sq(d / sz));
        }
        col += (glow + stars) * crush;
    }

    // ---- a supermassive pair's gas. Light from the disk's far side passes the holes on its
    // way to us and is bent, more the farther behind them it starts; the near side is seen
    // directly and hides the shadows behind it ----
    float4 front = float4(0.0);
    float3 nD = S.m.xyz;
    if (model >= 2) {
        float3 toCam = normalize(ro);
        float df = dot(rd, nD);
        if (abs(df) > 1e-4) {
            float tf = -dot(ro - O, nD) / df;
            float behind = -dot(ro + rd * tf - O, toCam);
            float3 rg = normalize(rd + shift * smoothstep(0.0, 4.0, behind));
            float dg = dot(rg, nD);
            float tg = abs(dg) > 1e-4 ? -dot(ro - O, nD) / dg : -1.0;
            if (tg > 0.0) {
                float3 X = ro + rg * tg - O;
                float4 g = model == 2
                    ? bbhGas(X, rg, nD, cA - O, cB - O, rA, rB, cos(S.m.w) * e1 + sin(S.m.w) * e2, presence, sep, cavity, afterglow, hotCol, coolCol, T)
                    : bbhAgn(X + O, nD, cA, rA, cB, pair ? rB : 0.0, afterglow, S.p.xyz, hotCol, coolCol, T);
                if (dot(X, toCam) > 0.0) front = g;
                else col = col * (1.0 - g.a) + g.rgb * crush;
            }
        }
        // jets along the remnant's spin, and the fading ones of the remnant before it
        float jn = S.k.w > 0.0 ? bbhJet(ro, rd, cA, S.k.xyz, T, pixW) * S.k.w : 0.0;
        float jo = S.l.w > 0.0 ? bbhJet(ro, rd, cA, S.l.xyz, T, pixW) * S.l.w : 0.0;
        col += mix(hotCol, float3(dot(hotCol, float3(0.33))), 0.3) * (jn + jo) * 0.6;
        if (model == 3 && afterglow > 0.0) {
            // the flare's light, a soft glow round the remnant
            float d0 = length(cross(rd, cA - ro));
            col += hotCol * afterglow * (exp(-d0 / 1.2) * 0.45 + exp(-d0 / 5.0) * 0.1);
        }
    }

    // ---- shadows and photon rings ----
    col *= 1.0 - shadow;
    float wR = max(0.1 * rRef, pixW * 1.2);
    float ring = exp(-sq(dS / wR)) * 0.7 + exp(-max(dS, 0.0) / (0.3 * rRef)) * 0.2 * (1.0 - shadow);
    // the faint inner ring of light that went round the hole once more
    ring += exp(-sq((dS - 0.06 * rRef) / (wR * 0.5))) * 0.25;
    col += ringCol * ring * ringBoost;

    col = col * (1.0 - front.a) + front.rgb;

    // ---- the strain trace: the signal as a detector records it, the newest at the right ----
    if ((flags & 1) != 0) {
        float Hf = F.camUp.w, Wf = F.camRight.w;
        float yc = Hf * 0.86, hh = Hf * 0.055;
        float px = in.pos.x, py = in.pos.y;
        float dy = abs(py - yc);
        if (dy < hh * 1.8) {
            const float span = 4.0;      // seconds across the screen
            float yA = yc - bbhStrain(tau + (1.0 - px / Wf) * span, S) * hh;
            float yB = yc - bbhStrain(tau + (1.0 - (px + 1.0) / Wf) * span, S) * hh;
            float lo = min(yA, yB) - 0.5, hi = max(yA, yB) + 0.5;
            float dd = max(max(lo - py, py - hi), 0.0);
            float fade = smoothstep(0.0, 0.3, px / Wf) * smoothstep(1.0, 0.98, px / Wf);
            col *= 1.0 - 0.45 * smoothstep(hh * 1.8, hh * 1.2, dy) * fade;
            col += ringCol * exp(-sq(dd / 0.8)) * fade;
        }
    }
    return finalize(col, p, F);
}
"""
}
