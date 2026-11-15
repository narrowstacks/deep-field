extension ShaderSource {
    static let galaxy = """
// ---------- per-frame: galaxy ----------

// Mirrors GalaxyModel in Galaxy.swift: flat rotation curve with a dark matter halo,
// falling (Keplerian) curve from visible mass alone.
static float galaxyVelocity(float r, bool darkMatter) {
    if (darkMatter) return 1.0 - exp(-r / 0.12);
    float a = 0.08;
    return r / pow(r * r + a * a, 0.75) * sqrt(a) / 0.6204;
}

// Stellar texture of the disk, carried around at each radius's own angular speed.
// Two phases cross-fade so differential rotation never shears it into streaks.
static float flowingDisk(float r, float phi, float omega, float time, float T, float scale, float fp) {
    float ph = fract(time / T);
    float w0 = 1.0 - abs(2.0 * ph - 1.0);
    float a0 = phi - omega * ph * T;
    float a1 = phi - omega * fract(ph + 0.5) * T;
    float n0 = fbmLOD(float3(cos(a0) * r * scale, sin(a0) * r * scale, 1.0), fp);
    float n1 = fbmLOD(float3(cos(a1) * r * scale, sin(a1) * r * scale, 9.0), fp);
    return n0 * w0 + n1 * (1.0 - w0);
}

// Star-forming regions: glowing H II clouds around young clusters, on rings of cells that each
// orbit at their own omega (the rotation curve, or the irregular's rising one). The gas only
// lights up where something compresses it (`gate`: the arm's density wave, the ring, a clump),
// so a region flares as it drifts into an arm and fades as it leaves. Each also has its own slow
// clock, as clouds collapse, glow, and blow themselves apart. Returns (cloud, cluster core).
static float2 starFormingRegions(float r, float phi, float time, float gate, constant Galaxy& G, bool dm, bool irregular) {
    const float N = 30.0;
    float ri = floor(r * N);
    float rc = (ri + 0.5) / N;
    float om = irregular ? G.motion.y * min(rc / 0.45, 1.0) * 0.8 / max(rc, 0.05)
                         : G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
    float n = max(floor(6.2831853 * rc * N + 0.5), 3.0);      // whole cells per ring: no seam
    float ca = fract((phi - om * time) / 6.2831853) * n;
    float ci = floor(ca);
    float h = hash13(float3(ri, ci, 23.0));
    if (h < 0.6) return float2(0.0);
    float2 c = (float2(hash13(float3(ri, ci, 24.0)), hash13(float3(ri, ci, 25.0))) - 0.5) * 0.4;
    float2 d = float2(fract(ca) - 0.5, r * N - ri - 0.5) - c;
    d.x *= 6.2831853 * rc * N / n;                           // cells are square in the disk plane
    float big = hash13(float3(ri, ci, 26.0));
    float size = 0.06 + 0.2 * big * big;                     // mostly small, a few giant complexes
    float life = 0.5 + 0.5 * sin(time * 0.015 * (0.5 + h) + h * 40.0);
    float g = gate * (0.2 + 0.8 * life) * (0.5 + 0.5 * (h - 0.6) / 0.4) * (0.6 + 1.2 * big);
    float q = dot(d, d) / (size * size);
    return float2(exp(-q) + 0.25 * exp(-q * 0.15), exp(-q * 6.0)) * g;
}

// A small satellite galaxy on an inclined orbit (radius in units of the galaxy radius R),
// seen as a soft spheroid. `compact`: a dense dwarf elliptical (bright cuspy core), else a
// diffuse dwarf spheroidal. Returns its light, and how far along the ray it sits.
static float satellite(float3 ro, float3 rd, float R, float orbit, float incl, float node, float ang,
                       float size, bool compact, thread float& tSat) {
    float3 o = orbit * R * float3(cos(ang), sin(ang) * sin(incl), sin(ang) * cos(incl));
    o = float3(o.x * cos(node) - o.z * sin(node), o.y, o.x * sin(node) + o.z * cos(node));
    tSat = dot(o - ro, rd);
    float3 w = ro + rd * tSat - o;
    w.y /= 0.7;
    float s = length(w) / (size * R);
    return compact ? exp(-5.0 * sqrt(s)) * 6.0 + exp(-s * s) * 0.05
                   : exp(-s * s * 0.7) * 0.07 + exp(-s * 2.5) * 0.12;
}

fragment float4 galaxyFragment(FRAME_INPUTS)
{
    uint2 p = uint2(in.pos.xy);
    float3 rd = octDecode(dirTex.read(p).xy);
    float3 ro = F.camPos.xyz;
    float3 col = SKY(p, rd, false);

    int type = int(G.shape.x);
    float R = G.misc.x;
    bool dm = G.motion.z > 0.5;

    // Bulge (or the whole body of an elliptical): an ellipsoid glow integrated along the ray.
    float flat_ = type == 2 ? 0.72 : 0.5;
    float re = (type == 2 ? 0.2 : 0.09) * R;
    float3 o2 = ro / float3(1.0, flat_, 1.0);
    float3 d2 = normalize(rd / float3(1.0, flat_, 1.0));
    float s = length(o2 + d2 * max(-dot(o2, d2), 0.0)) / re;
    float bulgeAmt = type == 3 ? 0.15 : (type == 2 ? 1.6 : 1.0);
    float3 bulge = G.core.rgb * (exp(-3.2 * pow(s, 0.65)) * 1.8 + exp(-s * 0.35) * 0.04) * bulgeAmt;
    // the old stars of the inner bulge are a touch warmer than its outskirts
    bulge *= mix(float3(1.0), float3(1.08, 0.97, 0.85), exp(-s * 1.5));
    if (type == 2) {
        // faint shells left over from swallowed companions: arcs with sharp outer edges,
        // alternating sides, as stars from a radial merger pile up at their turning points
        float shells = 0.0;
        float sa = atan2(d2.y, d2.x);
        for (int k = 0; k < 3; k++) {
            float rs = 2.4 + 1.25 * float(k);
            float edge = smoothstep(rs - 0.7, rs, s) * (1.0 - smoothstep(rs, rs + 0.06, s));
            float side = pow(0.5 + 0.5 * cos(sa + float(k) * 3.14159 + 0.4), 3.0);
            shells += edge * side / (1.0 + float(k));
        }
        bulge += G.core.rgb * shells * 0.018;
    }
    // the bright nucleus and the glow scattered around it (optics, so dust doesn't touch it)
    float3 bloom = G.core.rgb * (exp(-s * s * 60.0) * 2.5 + exp(-s * 1.2) * 0.10) * (type == 3 ? 0.0 : 1.0);
    bloom = mix(bloom, float3(dot(bloom, float3(0.33))), 0.3);

    // stellar halo and globular clusters, scattered in 3D around the galaxy
    float tClose = -dot(ro, rd);
    float dPerp = length(ro + rd * tClose) / R;
    col += G.core.rgb * exp(-dPerp / 0.45) * 0.025;
    {
        float3 cell = floor(rd / F.pixelAngle * 0.7);
        float h = hash13(cell + 41.0);
        float halo = exp(-dPerp / 0.5) * (type == 2 ? 2.5 : 1.0);    // ellipticals are rich in clusters
        if (h > 1.0 - 0.006 * halo) col += mix(G.core.rgb, float3(1.0), 0.4) * (0.5 + 2.0 * fract(h * 97.0));
    }

    // satellites: a compact dwarf elliptical close in and a diffuse dwarf further out, each on its
    // own orbit at the speed the rotation curve gives there (see GalaxyModel)
    float3 satFront = float3(0.0), satBack = float3(0.0);
    float tSat0 = 0.0, tSat1 = 0.0;
    if (type != 3) {
        float3 satCol = mix(G.core.rgb, float3(1.0), 0.15);
        float l0 = satellite(ro, rd, R, 1.15, 1.05, 0.5, G.misc.z, 0.035, true, tSat0);
        float l1 = satellite(ro, rd, R, 1.6, -0.75, -0.9, G.misc.w, 0.13, false, tSat1);
        satFront = satCol * l0;
        satBack = satCol * l1;                         // sorted against the disk below
    }

    float3 emission = float3(0.0);
    float dustOpacity = 0.0;
    float frontFrac = 1.0;          // share of the bulge's light that sits in front of the disk here
    float t = -ro.y / rd.y;
    if (type != 2 && t > 0.0) {
        float3 P = ro + rd * t;
        float r = length(P.xz) / R;
        float phi = atan2(P.z, P.x);
        frontFrac = smoothstep(-1.0, 1.0, clamp((t - tClose) / (1.2 * re), -1.0, 1.0));   // (tanh overflows to NaN under fast math)
        // light and dust pile up along longer paths through a tilted disk
        float path = clamp(0.3 / abs(rd.y), 1.0, 4.0);
        float dustPath = clamp(0.3 / abs(rd.y), 1.0, 7.0);
        float fp = F.pixelAngle * t / (R * max(abs(rd.y), 0.08));
        // every disk term is exactly zero beyond r = 1.2 (1.3 for the irregular's envelope)
        if (r < (type == 3 ? 1.3 : 1.2)) {
            float omega = G.motion.y * galaxyVelocity(r, dm) / max(r, 0.01);
            float a = phi - G.motion.x;                 // angle in the pattern's rotating frame
            float tanp = G.shape.z, m = G.shape.y;
            float clumps = flowingDisk(r, phi, omega, F.time, G.motion.w, 9.0, fp * 9.0);
            float fine = flowingDisk(r, phi, omega, F.time, G.motion.w, 26.0, fp * 26.0);
            float smoothDisk = exp(-r / 0.24) * (1.0 - smoothstep(0.7, 1.1, r));

            float arm = 0.0, ring = 0.0, bar = 0.0, knotsBand = 0.0, irrGate = 0.0;
            if (type == 0 || type == 1) {
                float r0 = type == 1 ? G.shape.w : 0.12;
                float psi = m * (a - log(max(r, 0.02) / r0) / tanp);
                float env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
                // feathery spurs along the arms
                float spurs = 0.55 + 0.75 * fine;
                float wave = 0.5 + 0.5 * cos(psi);
                arm = (pow(wave, 3.0) * 0.8 + pow(wave, 12.0) * 0.5) * env * spurs;   // bright crest on a broad arm
                // density-wave order across an arm: dust lane on the inside, then star-forming knots, then young stars
                // (in a plain spiral the lanes wind on into the bulge, silhouetted against it)
                float laneIn = type == 0 ? smoothstep(r0 * 0.3, r0 * 1.1, r) : smoothstep(r0, r0 * 1.8, r);
                float lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * laneIn * (1.0 - smoothstep(0.7, 1.05, r));
                knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
                float filaments = 0.35 + 0.9 * fine;
                // dust feathers: thin spurs that leave the lane and shear out across the inter-arm gap
                float feather = smoothstep(0.62, 0.85, fine) * pow(0.5 + 0.5 * cos(psi + 1.3), 3.0) * env;
                dustOpacity = lane * (0.3 + 0.7 * clumps) * filaments * 1.45
                            + feather * 0.35
                            + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12;      // flocculent inter-arm dust
                if (type == 1) {
                    float bx = r * cos(a), by = r * sin(a);
                    bar = exp(-pow(abs(bx) / G.shape.w, 4.0)) * exp(-pow(by / 0.05, 2.0));
                    // dust lanes along the bar's leading edges
                    dustOpacity += exp(-pow(abs(bx) / (G.shape.w * 1.1), 6.0)) * exp(-pow((abs(by) - 0.045) / 0.012, 2.0)) * 0.5;
                    // star formation where the bar's gas flows pile up at its ends
                    knotsBand += exp(-pow((abs(bx) - G.shape.w * 0.95) / 0.05, 2.0)) * exp(-pow(by / 0.06, 2.0)) * 0.8;
                }
            } else if (type == 4) {
                ring = exp(-pow((r - 0.62) / 0.07, 2.0)) * (0.6 + 0.6 * fine);
                knotsBand = ring;
                dustOpacity = exp(-pow((r - 0.55) / 0.03, 2.0)) * 0.5 * (0.4 + 0.8 * fine);
                smoothDisk *= 0.25;
            } else if (type == 3) {
                // Dwarf irregular. The lopsided envelope turns slowly, but the gas inside flows:
                // a rising rotation curve (inner parts turn faster than solid-body at the edge),
                // a turbulent warp that keeps changing, and clumps that form and dissolve.
                float env_a = phi - G.misc.y * 0.25;
                float2 e = float2(cos(env_a), sin(env_a)) * r;
                float envelope = exp(-length(e / float2(0.75, 0.45)) * 2.2)
                               * (0.7 + 0.6 * fbmLOD(float3(e * 1.8, 2.0 + F.time * 0.003), fp * 2.0))
                               * (1.0 - smoothstep(0.85, 1.3, r));
                float omIrr = G.motion.y * min(r / 0.45, 1.0) * 0.8 / max(r, 0.05);
                float T = G.motion.w;
                float ph = fract(F.time / T);
                float w0 = 1.0 - abs(2.0 * ph - 1.0);
                float lumps = 0.0;
                for (int k = 0; k < 2; k++) {
                    float tk = (k == 0 ? ph : fract(ph + 0.5)) * T;
                    float ak = phi - omIrr * tk;
                    float3 qk = float3(cos(ak) * r, sin(ak) * r, 0.0) * 3.2 + float3(0.0, 0.0, F.time * 0.006 + float(k) * 7.0);
                    float3 warp = float3(fbm(qk * 0.7 + 3.0), fbm(qk * 0.7 - 5.0), 0.0) - 0.5;
                    float v = fbmLOD(qk + warp * 1.6, fp * 3.2);
                    lumps += v * (k == 0 ? w0 : 1.0 - w0);
                }
                smoothDisk = envelope * smoothstep(0.3, 0.7, lumps) * 1.2;
                arm = smoothstep(0.55, 0.8, lumps) * envelope * 3.0;
                // star-forming bursts: knots brighten and fade on their own clocks
                float burst = 0.5 + 0.5 * sin(F.time * 0.15 + hash13(floor(float3(e * 14.0, 1.0))) * 6.283);
                knotsBand = arm * (0.3 + 1.2 * burst * burst);
                irrGate = smoothstep(0.42, 0.7, lumps) * saturate(envelope * 4.0) * (0.5 + burst);
                dustOpacity = smoothDisk * smoothstep(0.62, 0.8, fine) * 0.35;
            }
            // a thin, smooth dust layer through the whole disk: barely there face-on, but it
            // darkens and reddens the far half of the bulge as the disk turns edge-on
            if (type != 3) dustOpacity += exp(-r / 0.35) * (1.0 - smoothstep(0.6, 1.0, r)) * (0.05 + 0.08 * clumps);

            float young = (arm + ring) * (type == 3 ? 1.5 : 1.0);    // dwarf irregulars are young and blue
            float knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            // young arms: whiter where they're crowded near the middle, bluer out in the disk
            float3 armCol = mix(G.arms.rgb, mix(G.arms.rgb, float3(1.0), 0.45), exp(-r / 0.25));
            float3 oldCol = type == 3 ? mix(G.core.rgb, G.arms.rgb, 0.35) : G.core.rgb;
            float3 diskLight = oldCol * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                             + G.core.rgb * bar * 1.3
                             + armCol * young * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 1.15
                             + G.nebula.rgb * knots * 1.1;
            emission = diskLight * mix(1.0, path, 0.35);

            // discrete star-forming regions in the arms (or the ring, or the irregular's clumps)
            float gate = type == 3 ? irrGate : smoothstep(0.2, 0.75, knotsBand);
            if (gate > 0.01 && r > 0.1) {
                float2 sf = starFormingRegions(r, phi, F.time, gate, G, dm, type == 3);
                emission += (G.nebula.rgb * sf.x * (0.55 + 0.6 * fine) * 1.1
                           + mix(G.arms.rgb, float3(1.0), 0.6) * sf.y * 2.0) * mix(1.0, path, 0.35);
            }

            // resolved bright stars, each ring of cells orbiting at its own omega
            float ri = floor(r * 160.0);
            float rc = (ri + 0.5) / 160.0;
            float om = G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
            float cellAng = (phi - om * F.time) * rc * 160.0;
            float h = hash13(float3(ri, floor(cellAng), 5.0));
            if (h > 0.985 - 0.05 * young) emission += mix(G.core.rgb, G.arms.rgb, saturate(young * 2.0)) * (0.5 + young) * smoothDisk * 3.0;

            dustOpacity = saturate(dustOpacity * dustPath);
        }
    }
    // Edge-on, a real disk has thickness: a soft glow of old stars hugging the midplane.
    if (type != 2) {
        float edgeOn = 1.0 - smoothstep(0.08, 0.45, abs(rd.y));
        if (edgeOn > 0.0) {
            float3 P0 = ro + rd * tClose;
            float rr = length(P0.xz) / R, z = abs(P0.y) / R;
            col += G.core.rgb * exp(-rr / 0.3) * exp(-z / 0.03) * 0.25 * edgeOn * (1.0 - 0.8 * dustOpacity);
        }
    }
    // The back half of the bulge (and the sky, and anything behind the disk) is seen through the
    // disk's dust; the front half isn't.
    float3 dusty = mix(float3(1.0), G.dust.rgb, dustOpacity);
    float3 behind = col + bulge * (1.0 - frontFrac);
    float3 inFront = bulge * frontFrac + bloom;
    bool diskHit = type != 2 && t > 0.0;
    if (diskHit && tSat0 > t) behind += satFront; else inFront += satFront;
    if (diskHit && tSat1 > t) behind += satBack; else inFront += satBack;
    col = behind * dusty + emission * (1.0 - 0.8 * dustOpacity) + inFront;
    return finalize(col, p, F);
}
"""
}
