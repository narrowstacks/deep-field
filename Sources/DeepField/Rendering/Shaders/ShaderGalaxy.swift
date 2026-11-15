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
    if (type == 2) {
        // faint shells left over from swallowed companions
        float shells = 0.0;
        for (int k = 0; k < 3; k++) {
            float rs = 2.2 + 1.3 * float(k);
            shells += exp(-pow((s - rs) / 0.15, 2.0)) * pow(0.5 + 0.5 * cos(atan2(d2.y, d2.x) + float(k) * 2.3), 4.0);
        }
        bulge += G.core.rgb * shells * 0.02;
    }

    // stellar halo and globular clusters, scattered in 3D around the galaxy
    float tClose = -dot(ro, rd);
    float dPerp = length(ro + rd * tClose) / R;
    col += G.core.rgb * exp(-dPerp / 0.45) * 0.025;
    {
        float3 cell = floor(rd / F.pixelAngle * 0.7);
        float h = hash13(cell + 41.0);
        float halo = exp(-dPerp / 0.5);
        if (h > 1.0 - 0.006 * halo) col += mix(G.core.rgb, float3(1.0), 0.4) * (0.5 + 2.0 * fract(h * 97.0));
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
        float fp = F.pixelAngle * t / (R * max(abs(rd.y), 0.08));
        // every disk term is exactly zero beyond r = 1.2 (1.3 for the irregular's envelope)
        if (r < (type == 3 ? 1.3 : 1.2)) {
            float omega = G.motion.y * galaxyVelocity(r, dm) / max(r, 0.01);
            float a = phi - G.motion.x;                 // angle in the pattern's rotating frame
            float tanp = G.shape.z, m = G.shape.y;
            float clumps = flowingDisk(r, phi, omega, F.time, G.motion.w, 9.0, fp * 9.0);
            float fine = flowingDisk(r, phi, omega, F.time, G.motion.w, 26.0, fp * 26.0);
            float smoothDisk = exp(-r / 0.24) * (1.0 - smoothstep(0.7, 1.1, r));

            float arm = 0.0, ring = 0.0, bar = 0.0, knotsBand = 0.0;
            if (type == 0 || type == 1) {
                float r0 = type == 1 ? G.shape.w : 0.12;
                float psi = m * (a - log(max(r, 0.02) / r0) / tanp);
                float env = smoothstep(r0 * 0.8, r0 * 1.4, r) * (1.0 - smoothstep(0.75, 1.2, r));
                // feathery spurs along the arms
                float spurs = 0.55 + 0.75 * fine;
                arm = pow(0.5 + 0.5 * cos(psi), 3.0) * env * spurs;
                // density-wave order across an arm: dust lane on the inside, then star-forming knots, then young stars
                float lane = pow(0.5 + 0.5 * cos(psi + 0.6), 10.0) * smoothstep(r0, r0 * 1.8, r) * (1.0 - smoothstep(0.7, 1.05, r));
                knotsBand = pow(0.5 + 0.5 * cos(psi + 0.25), 6.0) * env;
                float filaments = 0.35 + 0.9 * fine;
                dustOpacity = lane * (0.4 + 0.6 * clumps) * filaments * 0.95
                            + smoothDisk * smoothstep(0.55, 0.8, fine) * 0.12;      // flocculent inter-arm dust
                if (type == 1) {
                    float bx = r * cos(a), by = r * sin(a);
                    bar = exp(-pow(abs(bx) / G.shape.w, 4.0)) * exp(-pow(by / 0.05, 2.0));
                    // dust lanes along the bar's leading edges
                    dustOpacity += exp(-pow(abs(bx) / (G.shape.w * 1.1), 6.0)) * exp(-pow((abs(by) - 0.045) / 0.012, 2.0)) * 0.5;
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
                dustOpacity = smoothDisk * smoothstep(0.62, 0.8, fine) * 0.35;
            }

            float young = arm + ring;
            float knots = smoothstep(0.6, 0.8, clumps * 0.6 + fine * 0.4) * knotsBand;
            float3 diskLight = G.core.rgb * smoothDisk * (0.5 + 0.35 * clumps + 0.15 * fine) * 0.9
                             + G.core.rgb * bar * 1.3
                             + G.arms.rgb * young * (0.3 + 0.8 * clumps) * exp(-r / 0.5) * 1.1
                             + G.nebula.rgb * knots * 1.3;
            emission = diskLight * mix(1.0, path, 0.35);

            // resolved bright stars, each ring of cells orbiting at its own omega
            float ri = floor(r * 160.0);
            float rc = (ri + 0.5) / 160.0;
            float om = G.motion.y * galaxyVelocity(rc, dm) / max(rc, 0.01);
            float cellAng = (phi - om * F.time) * rc * 160.0;
            float h = hash13(float3(ri, floor(cellAng), 5.0));
            if (h > 0.985 - 0.05 * young) emission += mix(G.core.rgb, G.arms.rgb, saturate(young * 2.0)) * (0.5 + young) * smoothDisk * 3.0;

            dustOpacity = saturate(dustOpacity * path);
        }
    }
    // The back half of the bulge (and the sky) is seen through the disk's dust; the front half isn't.
    float3 dusty = mix(float3(1.0), G.dust.rgb, dustOpacity);
    col = (col + bulge * (1.0 - frontFrac)) * dusty + emission * (1.0 - 0.8 * dustOpacity) + bulge * frontFrac;
    return finalize(col, p, F);
}
"""
}
