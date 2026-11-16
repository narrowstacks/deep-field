extension ShaderSource {
    static let quasar = """
// ---------- per-frame: quasar ----------
// An active galaxy: a spiral disk around a blazing nucleus, a clumpy dusty torus, and two
// relativistic jets along the spin axis ending in radio lobes. World space, nucleus at the origin.
// S.a = jet axis (toward the approaching jet), jet length; S.b = disk axis e1, approaching knot travel;
// S.c = jet color, receding knot travel; S.d = lobe color, jet brightness;
// S.e = approaching beaming, receding beaming, galaxy brightness, arm pattern angle;
// S.f = core flare boost, flare knot position (approaching), flare knot brightness, flare knot position (receding);
// S.g = helix phase, lobe drift, hot spot boost, torus transmission toward us.

constant float QSR_GALAXY_R = 4.4;
constant float QSR_TORUS_R = 0.55;
constant float QSR_TORUS_A = 0.22;
constant float QSR_TORUS_K = 5.0;
constant float QSR_KNOT_GAP = 1.4;

// Dust density of the clumpy torus at P (axis n): a ring of clouds orbiting the nucleus.
static float qsrTorus(float3 P, float3 n, float3 e1, float3 e2, float time) {
    float h = dot(P, n);
    float2 pl = float2(dot(P, e1), dot(P, e2));
    float rho = length(pl);
    float d2 = ((rho - QSR_TORUS_R) * (rho - QSR_TORUS_R) + h * h) / (QSR_TORUS_A * QSR_TORUS_A);
    if (d2 > 9.0) return 0.0;
    // clouds carried round at the orbital speed (slowed down)
    float a = atan2(pl.y, pl.x) - time * 0.06;
    float clump = noise3(float3(cos(a) * 2.6, sin(a) * 2.6, h * 14.0) + float3(rho * 18.0, 0.0, 0.0));
    return QSR_TORUS_K * exp(-d2) * (0.25 + 1.5 * clump * clump);
}

// The jet's centerline: the axis plus a slowly precessing helix whose pattern moves outward.
static float3 qsrJetPoint(float z, float3 J, float3 e1, float3 e2, float phase, float side) {
    float amp = 0.045 * smoothstep(0.3, 3.5, z) * (1.0 + 0.05 * z);
    float psi = z * 1.1 - phase + side * 1.3;
    return J * z + amp * (cos(psi) * e1 + sin(psi) * e2);
}

// Radio lobe density at X for the jet along J ending at length L: a cocoon of plasma that
// backflows from the hot spot toward the core, broad at the head and tapering behind it.
static float qsrLobe(float3 X, float3 J, float L, float drift, float side) {
    float zl = dot(X, J) - 0.86 * L;
    float q = length(X - J * dot(X, J));
    float rad = L * (0.05 + 0.09 * smoothstep(-0.4 * L, 0.06 * L, zl));
    float shape = exp(-(zl * zl) / (0.03 * L * L) - (q * q) / (rad * rad));
    if (shape < 0.004) return 0.0;
    float3 w = X / L * 4.0 + float3(side * 11.0, drift, -drift * 0.7);
    float3 warp = float3(noise3(w * 0.8 + 5.0), noise3(w * 0.8 - 3.0), noise3(w * 0.8 + 9.0)) - 0.5;
    float tex = fbm(w + warp * 1.6);
    return shape * smoothstep(0.3, 0.85, tex) * (0.3 + 1.2 * tex);
}

fragment float4 quasarFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float3 col = SKY(p, rd, false);

    float3 n = S.a.xyz, e1 = S.b.xyz, e2 = cross(n, e1);
    float L = S.a.w;
    float3 jetCol = S.c.rgb, lobeCol = S.d.rgb;
    float jetB = S.d.w, galB = S.e.z;
    float coreBoost = S.f.x;
    float time = F.time;
    float R = QSR_GALAXY_R;
    float tClose = -dot(ro, rd);
    float dCore = length(ro + rd * tClose);

    // ---- host galaxy ----
    // the bulge, an ellipsoid flattened along the axis, integrated along the ray
    float3 o2 = float3(dot(ro, e1), dot(ro, e2), dot(ro, n) / 0.55);
    float3 d2 = normalize(float3(dot(rd, e1), dot(rd, e2), dot(rd, n) / 0.55));
    float s = length(o2 + d2 * max(-dot(o2, d2), 0.0)) / (0.1 * R);
    float3 oldCol = float3(1.0, 0.68, 0.4) * 0.75;
    float3 youngCol = float3(0.45, 0.62, 1.0) * 0.8;
    float3 hiiCol = float3(1.0, 0.3, 0.45) * 0.9;
    float3 bulge = oldCol * (exp(-3.2 * pow(s, 0.65)) * 2.4 + exp(-s * 0.4) * 0.05) * galB;
    bulge *= mix(float3(1.0), float3(1.08, 0.95, 0.82), exp(-s * 1.5));
    col += oldCol * exp(-dCore / (0.45 * R)) * 0.03 * galB;   // faint stellar halo

    float dn = dot(rd, n);
    float tD = -dot(ro, n) / dn;
    float3 emission = float3(0.0);
    float dustOpacity = 0.0;
    float frontFrac = 1.0;
    float rDisk = 1e4;
    if (tD > 0.0) {
        float3 P = ro + rd * tD;
        float2 pl = float2(dot(P, e1), dot(P, e2));
        rDisk = length(pl);
        float r = rDisk / R;
        frontFrac = smoothstep(-1.0, 1.0, clamp((tD - tClose) / (0.12 * R), -1.0, 1.0));
        if (r < 1.2 && galB > 0.0) {
            float phi = atan2(pl.y, pl.x);
            float path = clamp(0.3 / abs(dn), 1.0, 4.0);
            float fp = F.pixelAngle * tD / (R * max(abs(dn), 0.08));
            // flat rotation curve: an edge star goes round in eight minutes
            float omega = 0.0131 * galaxyVelocity(r, true) / max(r, 0.01);
            float clumps = flowingDisk(r, phi, omega, time, 72.0, 9.0, fp * 9.0);
            float fine = flowingDisk(r, phi, omega, time, 72.0, 26.0, fp * 26.0);
            float smoothDisk = exp(-r / 0.3) * (1.0 - smoothstep(0.7, 1.1, r));
            // two density-wave arms turning at the pattern speed
            float r0 = 0.12;
            float psi = 2.0 * (phi - S.e.w - log(max(r, 0.02) / r0) / 0.62);
            float env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
            float wave = 0.5 + 0.5 * cos(psi);
            float arm = (pow(wave, 3.0) * 0.8 + pow(wave, 12.0) * 0.5) * env * (0.55 + 0.75 * fine);
            // dust lane on the arm's inner edge, star-forming knots just past it
            float lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * smoothstep(r0 * 0.3, r0 * 1.1, r) * (1.0 - smoothstep(0.7, 1.05, r));
            float knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
            dustOpacity = lane * (0.3 + 0.7 * clumps) * (0.35 + 0.9 * fine) * 1.45
                        + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12
                        + exp(-r / 0.35) * (1.0 - smoothstep(0.6, 1.0, r)) * (0.05 + 0.08 * clumps);
            float knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            float3 armCol = mix(youngCol, mix(youngCol, float3(1.0), 0.45), exp(-r / 0.25));
            emission = (oldCol * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                      + armCol * arm * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 0.8
                      + hiiCol * knots * 1.1) * mix(1.0, path, 0.35) * galB;
            dustOpacity = saturate(dustOpacity * clamp(0.3 / abs(dn), 1.0, 7.0)) * saturate(galB * 2.0);
        }
    }
    float3 dusty = mix(float3(1.0), float3(0.12, 0.06, 0.03), dustOpacity);

    // edge-on, the disk has thickness: a soft glow of old stars hugging the midplane
    float edgeOn = (1.0 - smoothstep(0.06, 0.4, abs(dn))) * galB;
    if (edgeOn > 0.0) {
        float3 P0 = ro + rd * tClose;
        float h = abs(dot(P0, n)) / R;
        float rr = length(P0 - n * dot(P0, n)) / R;
        col += oldCol * exp(-rr / 0.32) * (exp(-h / 0.025) * 0.35 + exp(-h / 0.08) * 0.08) * edgeOn;
    }

    // ---- jets, hot spots and lobes ----
    float tJet[2] = {0.0, 0.0};
    float3 jetLight[2] = {float3(0.0), float3(0.0)};
    for (int j = 0; j < 2; j++) {
        float side = j == 0 ? 1.0 : -1.0;
        float3 J = n * side;
        float beam = j == 0 ? S.e.x : S.e.y;
        float travel = j == 0 ? S.b.w : S.c.w;
        // closest approach between the ray and the jet's axis line
        float b = dot(rd, J), e = dot(J, ro), dd = dot(rd, ro);
        float den = max(1.0 - b * b, 1e-4);
        float z = (e - b * dd) / den;
        float3 jl = float3(0.0);
        float tc = 0.0;
        if (z > -0.3 && z < L * 1.15) {
            float zc = max(z, 0.0);
            float3 C = qsrJetPoint(zc, J, e1, e2, S.g.x, side);
            tc = dot(C - ro, rd);
            float dist = length(C - ro - rd * tc);
            float w = 0.022 + 0.02 * zc;
            if (dist < w * 14.0) {
                // knots: shocks in the flow, spaced irregularly, swelling as they travel out
                float u = (zc - travel) / QSR_KNOT_GAP;
                float cell = floor(u);
                float knot = 0.0;
                for (int k = -1; k <= 1; k++) {
                    float ck = cell + float(k);
                    float h = hash13(float3(ck, side * 7.0, 3.0));
                    float c0 = ck + 0.15 + 0.7 * h;
                    float len = (0.1 + 0.025 * zc) / QSR_KNOT_GAP;
                    float g = (u - c0) / len;
                    float strength = 0.3 + 1.3 * hash13(float3(ck, side * 7.0, 9.0));
                    knot += exp(-g * g) * strength * strength;
                }
                // the flare's fresh knot
                float zf = j == 0 ? S.f.y : S.f.w;
                if (S.f.z > 0.0 && zf > 0.0) {
                    float g = (zc - zf) / (0.12 + 0.03 * zf);
                    knot += exp(-g * g) * S.f.z * 6.0;
                }
                float along = (exp(-zc / 1.1) * 2.2 + 0.5 * exp(-zc / (0.55 * L)) + 0.14)
                            * smoothstep(-0.02, 0.25, z) * (1.0 - smoothstep(0.93 * L, 1.03 * L, zc))
                            * (1.0 + coreBoost * 0.4 * exp(-zc / 1.5));
                float ripple = 0.8 + 0.4 * noise3(float3(zc * 2.2 - travel * 2.2, dist / w, side * 5.0));
                float x = dist / w;
                float prof = exp(-x * x) + 0.35 * exp(-x * 1.1) + 0.08 * exp(-x * 0.3);
                // knots sit inside the jet, so they skip its wide halo (the bloom glows them)
                float kprof = exp(-x * x * 0.7) + 0.25 * exp(-x * 1.4);
                float I = along * (0.4 * prof + 1.4 * knot * kprof) * ripple * beam * jetB;
                // whitest at the base, drifting toward the lobe color near the end
                float3 c = mix(mix(jetCol, float3(1.0), 0.55), jetCol, smoothstep(0.0, 3.0, zc));
                c = mix(c, mix(jetCol, lobeCol, 0.6), smoothstep(0.55 * L, L, zc));
                jl += c * I * 2.0;
            }
        }
        // hot spot: where the jet slams into the surrounding gas
        float3 H = qsrJetPoint(L, J, e1, e2, S.g.x, side);
        float th = dot(H - ro, rd);
        float dh = length(H - ro - rd * th);
        float hot = (exp(-(dh * dh) / 0.03) * 2.5 + exp(-dh / 0.45) * 0.35) * (1.0 + (j == 0 ? S.g.z : 0.0));
        jl += mix(jetCol, float3(1.0), 0.4) * hot * jetB * (j == 0 ? 1.0 : 0.8);
        // lobe: a few samples through the cocoon
        float3 Lc = J * (0.86 * L);
        float tl = dot(Lc - ro, rd);
        float dl = length(Lc - ro - rd * tl);
        float span = 0.42 * L;
        if (dl < span) {
            float half_ = sqrt(span * span - dl * dl);
            float acc = 0.0, head = 0.0;
            const int N = 6;
            for (int k = 0; k < N; k++) {
                float tk = tl + half_ * ((float(k) + 0.5) / float(N) * 2.0 - 1.0);
                float3 X = ro + rd * tk;
                float d = qsrLobe(X, J, L, S.g.y, side);
                acc += d;
                head += d * smoothstep(0.55 * L, 0.98 * L, dot(X, J));
            }
            float scale = 2.0 * half_ / float(N);
            acc *= scale; head *= scale;
            // spectral aging: fresh plasma at the head, older and bluer toward the core
            float3 old_ = mix(lobeCol, float3(0.25, 0.4, 1.0), 0.55);
            float fresh = head / max(acc, 1e-4);
            float3 lc = mix(old_, mix(lobeCol, float3(1.0), 0.2), fresh);
            jl += lc * acc * 0.6 * jetB * (j == 0 ? 1.0 : 0.85);
        }
        jetLight[j] = jl;
        tJet[j] = tc;
    }

    // ---- nucleus: accretion glow, scattered light, dusty torus ----
    float flicker = 1.0 + 0.18 * (noise3(float3(time * 0.35, 1.0, 2.0)) - 0.5);
    // the accretion disk, a thin hot ellipse in the plane right around the hole
    float accretion = exp(-(rDisk * rDisk) / 0.012) * 1.6;
    float3 coreCol = float3(0.85, 0.92, 1.1);
    // scattered light reaches us around the torus, so only the compact core is fully hidden
    float coreT = S.g.w;
    float3 coreSeen = coreCol * ((exp(-(dCore * dCore) / 0.0015) * 16.0 + exp(-dCore / 0.07) * 2.5 + accretion) * coreT
                    + (exp(-dCore / 0.4) * 0.35 + exp(-dCore / 2.0) * 0.05) * mix(coreT, 1.0, 0.6))
                    * flicker * (1.0 + coreBoost);

    // torus: march the short stretch of ray near the nucleus, tracking how much dust lies in
    // front of each emitter (the jets' bases and the back of the scene)
    float3 torusGlow = float3(0.0);
    float tauAll = 0.0, tauA = 0.0, tauR = 0.0;
    if (dCore < 1.2) {
        const int M = 28;
        float seg = 1.2;
        float dt = 2.0 * seg / float(M);
        for (int k = 0; k < M; k++) {
            float tk = tClose - seg + (float(k) + 0.5) * dt;
            float3 X = ro + rd * tk;
            float dens = qsrTorus(X, n, e1, e2, time) * dt;
            if (dens <= 0.0) continue;
            float rho = length(X - n * dot(X, n));
            // lit on its inner face by the nucleus, re-radiating as warm dust
            float lit = 0.25 + 1.6 * smoothstep(QSR_TORUS_R + 0.02, QSR_TORUS_R - QSR_TORUS_A, rho);
            torusGlow += float3(1.0, 0.42, 0.18) * dens * lit * 0.22 * exp(-tauAll) * (1.0 + coreBoost * 0.5);
            tauAll += dens;
            if (tk < tJet[0]) tauA += dens;
            if (tk < tJet[1]) tauR += dens;
        }
    }
    float transAll = exp(-tauAll);

    // compose: sky, back of the bulge and the receding jet sit behind the disk's dust
    float3 behind = col + bulge * (1.0 - frontFrac) + jetLight[1] * exp(-tauR);
    col = behind * dusty * transAll + emission * (1.0 - 0.8 * dustOpacity) * mix(1.0, transAll, 0.5)
        + bulge * frontFrac + jetLight[0] * exp(-tauA) + coreSeen + torusGlow;
    return finalize(col, p, F);
}
"""
}
