extension ShaderSource {
    static let bake = """
// ---------- bake: shared ----------

static float3 cameraRay(constant BakeParams& P, uint2 gid, thread float3& camPos) {
    float aspect = P.width / P.height;
    float2 uv = (float2(gid) + 0.5) / float2(P.width, P.height) * 2.0 - 1.0;
    uv.y = -uv.y;
    uv.x *= aspect;
    float cr = cos(P.roll), sr = sin(P.roll);
    uv = float2(cr * uv.x - sr * uv.y, sr * uv.x + cr * uv.y);
    float ce = cos(P.camElev), se = sin(P.camElev);
    camPos = float3(0.0, se, -ce) * P.camDist;
    float3 fwd = normalize(float3(P.lookX, P.lookY, 0.0) - camPos);
    float3 right = normalize(cross(float3(0, 1, 0), fwd));
    float3 up = cross(fwd, right);
    return normalize(fwd + (uv.x * right + uv.y * up) * P.tanHalfFov);
}

struct ShellRec {
    float4 pos = float4(0.0);
    float4 dir = float4(0.0);
    int n = 0;
};

// Up to two crossings of a sphere of radius R: where (theta, phi) and which way the ray was
// heading. Stored as unorm16 (see decodeShell): theta offset by 4 * eventIndex (so the frame
// shader knows what is in front of what) and mapped to (0, 1], with 0 = no crossing; phi to [0, 1].
static void recordShell(thread ShellRec& s, float3 hp, float3 hv, float R, int ev) {
    if (s.n >= 2) return;
    float3 nrm = hp / R;
    float theta = (acos(clamp(nrm.y, -1.0, 1.0)) + 4.0 * float(min(ev, 5)) + 0.5) / 25.0;
    float phi = atan2(nrm.z, nrm.x) / 6.2831853 + 0.5;
    float2 d = octEncode(normalize(hv));
    if (s.n == 0) { s.pos.xy = float2(theta, phi); s.dir.xy = d; }
    else          { s.pos.zw = float2(theta, phi); s.dir.zw = d; }
    s.n++;
}

static void writeShells(constant BakeParams& P, ShellRec s0, ShellRec s1,
                        texture2d<float, access::write> shell0P, texture2d<float, access::write> shell0D,
                        texture2d<float, access::write> shell1P, texture2d<float, access::write> shell1D, uint2 gid) {
    if (P.shells < 0.5) return;
    shell0P.write(s0.pos, gid);
    shell0D.write(s0.dir, gid);
    shell1P.write(s1.pos, gid);
    shell1D.write(s1.dir, gid);
}

// ---------- bake: black hole ----------

// Photon in Schwarzschild spacetime (Schwarzschild radius = 1), written as a
// Newtonian-looking ODE: a = -1.5 h^2 r / |r|^5, with h = |r x v| conserved.
static float3 accel(float3 p, float h2) {
    float r2 = dot(p, p);
    return -1.5 * h2 * p / (r2 * r2 * sqrt(r2));
}

// ---------- bake: tidal disruption (star, stream and jets, traced with the black hole) ----------
// T is TDEGeometry.bake: a = (star center, radius), b = (near axis, far axis, stream start
// angle, stream end), c = (stream start radius, merge radius, winding, 0), d = (widths).

// The stream's centerline in the disk plane: radius at s (0 = leaving the star, 1 = merging
// with the disk's outer edge, beyond that it trails round the disk and thins out).
static float tdeStreamRadius(float s, constant SceneParams& T, thread float& drds) {
    float r0 = T.c.x, r1 = T.c.y;
    if (s < 1.0) {
        float k = 1.0 - s;
        drds = -2.4 * (r0 - r1) * pow(max(k, 1e-4), 1.4);
        return r1 + (r0 - r1) * pow(k, 2.4);
    }
    drds = -0.07 * r1;
    return r1 * (1.0 - 0.07 * (s - 1.0));
}

// Stream gas density at p (per unit length, normalized by the width), and where along (s) and
// across (u, in widths) the stream that point is.
static float tdeStream(float3 p, constant SceneParams& T, thread float& sOut, thread float& uOut) {
    float rp = length(p.xz);
    float rel = atan2(p.z, p.x) - T.b.z;
    rel -= 6.2831853 * floor(rel / 6.2831853);
    float best = 0.0;
    for (int k = 0; k < 2; k++) {
        float s = (rel + 6.2831853 * float(k)) / T.c.z;
        if (s > T.b.w) break;
        float drds;
        float rc = tdeStreamRadius(s, T, drds);
        float cosA = rsqrt(1.0 + pow(drds / (T.c.z * rc), 2.0));
        float w = mix(T.d.x, T.d.y, smoothstep(0.0, 1.0, s)) * (1.0 + 0.6 * max(s - 1.0, 0.0));
        float h = w * 0.55;
        float u = (rp - rc) * cosA / w;
        float q = u * u + pow(p.y / h, 2.0);
        if (q > 9.0) continue;
        float along = smoothstep(0.0, 0.04, s) * (1.0 - smoothstep(T.b.w - 0.5, T.b.w, s));
        float d = exp(-q) * along / w;
        if (d > best) { best = d; sOut = s; uOut = u; }
    }
    return best;
}

// Jet density at p: twin narrow cones along the spin axis.
static float tdeJet(float3 p, float jetLen) {
    float ay = abs(p.y);
    float wj = 0.16 + 0.035 * ay, ws = 0.45 + 0.12 * ay;      // bright spine, faint sheath
    float rho2 = length_squared(p.xz);
    float d = exp(-rho2 / (wj * wj)) / wj + 0.35 * exp(-rho2 / (ws * ws)) / ws;
    return d * smoothstep(1.2, 2.6, ay) * exp(-ay / jetLen);
}

// First hit of the straight segment o + d t (t in [0, len]) with the star: two half-ellipsoids
// joined at the middle, the near one stretched toward the hole. Returns t, or -1; nOut = the
// hit on the unit sphere in the star's frame (x toward the hole), mu = cosine to the viewer.
static float tdeStarHit(float3 o, float3 d, float len, constant SceneParams& T, thread float3& nOut, thread float& mu) {
    float3 C = T.a.xyz;
    float3 ax = normalize(-C);
    float3 ay = float3(0.0, 1.0, 0.0);
    float3 az = cross(ax, ay);
    float3 lo = float3(dot(o - C, ax), dot(o - C, ay), dot(o - C, az));
    float3 ld = float3(dot(d, ax), dot(d, ay), dot(d, az));
    float b = T.a.w * 0.93;
    float bestT = -1.0;
    for (int side = 0; side < 2; side++) {
        float3 sc = float3(side == 0 ? T.b.x : T.b.y, b, b);
        float3 so = lo / sc, sd = ld / sc;
        float A = dot(sd, sd), B = dot(so, sd), Cc = dot(so, so) - 1.0;
        float disc = B * B - A * Cc;
        if (disc < 0.0) continue;
        float sq = sqrt(disc);
        for (int j = 0; j < 2; j++) {
            float t = (-B + (j == 0 ? -sq : sq)) / A;
            if (t < 0.0 || t > len) continue;
            float3 hp = lo + ld * t;
            if ((side == 0) != (hp.x >= 0.0)) continue;
            if (bestT < 0.0 || t < bestT) {
                bestT = t;
                nOut = normalize(hp / sc);
                mu = saturate(-dot(normalize(hp / (sc * sc)), ld));
            }
        }
    }
    return bestT;
}

// info = closest approach radius (0 = fell into the hole, 0.5 = hit the tidal disruption's star).
// The tidal disruption (T.a.w > 0) also writes: info.yzw = jet column in front of / behind the
// first disk crossing and its column-weighted height; shell0P = stream column in front / behind
// and its weighted along / across coordinates; shell1P = star surface point (octahedral), cosine
// to the viewer (or minus the closest approach in star radii, for a miss), event index + 1.
kernel void bakeBlackHole(BAKE_OUTPUTS, constant SceneParams& T [[buffer(1)]])
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 dir = cameraRay(P, gid, camPos);

    float3 pos = camPos;
    float3 vel = dir;
    float h2 = length_squared(cross(pos, vel));

    float4 A = float4(0.0), B = float4(0.0);
    int hits = 0;
    int ev = 0;
    ShellRec s0, s1;
    float minR = 1e9;
    bool captured = false;
    float gCam = sqrt(1.0 - 1.0 / P.camDist);
    bool shells = P.shells > 0.5;
    bool tde = T.a.w > 0.0;
    float2 stream = float2(0.0), jets = float2(0.0);
    float4 star = float4(0.0, 0.0, -1e3, 0.0);
    float streamS = 0.0, streamU = 0.0, jetY = 0.0;
    float starReach = length(T.a.xyz) + T.b.x + 0.5;
    bool hitStar = false;

    int maxSteps = tde ? 2500 : 1500;
    for (int i = 0; i < maxSteps; i++) {
        float r = length(pos);
        minR = min(minR, r);
        if (r < 1.0) { captured = true; break; }
        if (r > P.camDist * 1.6 && dot(pos, vel) > 0.0) break;

        float dt = clamp(0.03 * r, 0.004, tde ? 0.4 : 1.0);
        float3 a0 = accel(pos, h2);
        float3 np = pos + vel * dt + 0.5 * a0 * dt * dt;
        float3 a1 = accel(np, h2);
        float3 nv = vel + 0.5 * (a0 + a1) * dt;
        float nr = length(np);

        if (tde) {
            float seg = length(np - pos);
            float3 sd = (np - pos) / seg;
            // the star is opaque; straight segments are fine this far from the hole
            float3 toC = T.a.xyz - pos;
            float dc = length(toC - sd * clamp(dot(toC, sd), 0.0, seg));
            star.z = max(star.z, -dc / T.a.w);
            float len = seg;
            if (dc < T.b.x + 0.05) {
                float3 n; float mu;
                float th = tdeStarHit(pos, sd, seg, T, n, mu);
                if (th >= 0.0) {
                    star = float4(octEncode(n), mu, float(min(ev++, 5)) + 1.0);
                    hitStar = true;
                    len = th;
                }
            }
            // gas: the stream near the plane, the jets near the axis; 3 midpoint samples per step
            bool nearPlane = min(abs(pos.y), abs(np.y)) < 2.0 || pos.y * np.y < 0.0;
            bool streamZone = nearPlane && max(r, nr) > T.c.y * 0.75 - 1.0 && min(r, nr) < starReach;
            bool jetZone = min(length(pos.xz), length(np.xz)) < 2.5 + 0.06 * max(abs(pos.y), abs(np.y));
            if (streamZone || jetZone) {
                float dl = len / 3.0;
                for (int k = 0; k < 3; k++) {
                    float3 q = pos + sd * (dl * (float(k) + 0.5));
                    if (streamZone) {
                        float s = 0.0, u = 0.0;
                        float dens = tdeStream(q, T, s, u) * dl;
                        if (hits == 0) stream.x += dens; else stream.y += dens;
                        streamS += dens * s; streamU += dens * u;
                    }
                    if (jetZone) {
                        float dens = tdeJet(q, 6.0) * dl;
                        if (hits == 0) jets.x += dens; else jets.y += dens;
                        jetY += dens * abs(q.y);
                    }
                }
            }
            if (hitStar) break;
        }

        if (shells && (r - P.shellR0) * (nr - P.shellR0) < 0.0) {
            float t = (r - P.shellR0) / (r - nr);
            recordShell(s0, mix(pos, np, t), mix(vel, nv, t), P.shellR0, ev++);
        }
        if (shells && (r - P.shellR1) * (nr - P.shellR1) < 0.0) {
            float t = (r - P.shellR1) / (r - nr);
            recordShell(s1, mix(pos, np, t), mix(vel, nv, t), P.shellR1, ev++);
        }

        if (pos.y * np.y < 0.0 && hits < 2) {
            float t = pos.y / (pos.y - np.y);
            float3 hp = mix(pos, np, t);
            float rh = length(hp.xz);
            if (rh > P.diskIn * 0.85 && rh < P.diskOut * 1.1) {
                float phi = atan2(hp.z, hp.x);
                // circular orbit speed seen by a static observer
                float beta = min(sqrt(0.5 / max(rh - 1.0, 0.05)), 0.95);
                float gam = rsqrt(1.0 - beta * beta);
                float3 tang = float3(-sin(phi), 0.0, cos(phi));
                float3 k = -normalize(mix(vel, nv, t));
                float dop = 1.0 / (gam * (1.0 - beta * dot(tang, k)));
                float g = dop * sqrt(max(1.0 - 1.0 / rh, 0.0)) / gCam;
                float4 h = float4(rh, phi, g, float(ev++) + 1.0);
                if (hits == 0) A = h; else B = h;
                hits++;
            }
        }
        pos = np;
        vel = nv;
    }

    hitA.write(A, gid);
    hitB.write(B, gid);
    writeShells(P, s0, s1, shell0P, shell0D, shell1P, shell1D, gid);
    dirTex.write(float4(octEncode(normalize(vel)), 0.0, 0.0), gid);
    if (tde) {
        float sc = stream.x + stream.y, jc = jets.x + jets.y;
        shell0P.write(float4(stream, sc > 0.0 ? streamS / sc : 0.0, sc > 0.0 ? streamU / sc : 0.0), gid);
        shell1P.write(star, gid);
        infoTex.write(float4(hitStar ? 0.5 : (captured ? 0.0 : minR), jets, jc > 0.0 ? jetY / jc : 0.0), gid);
    } else {
        infoTex.write(float4(captured ? 0.0 : minR), gid);
    }
}

// ---------- bake: wormhole ----------

// Ellis wormhole: ds^2 = -dt^2 + dl^2 + (b0^2 + l^2) dOmega^2. Each ray stays in the plane
// through the camera and the throat, so we integrate (l, phi) in that plane with the
// conserved impact parameter B:  dl/ds = p,  dp/ds = B^2 l / r^4,  dphi/ds = B / r^2.
// Rays with B < b0 pass through the throat into the other universe (l < 0).
// info = side (+1 ours, -1 the other universe) * (impact parameter B / b0 + 0.001);
// B / b0 = 1 marks rays that just graze the throat.
kernel void bakeWormhole(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 d = cameraRay(P, gid, camPos);
    float b0 = P.throat;
    float D = P.camDist;
    float3 e1 = camPos / D;
    float cosA = dot(d, e1);
    float3 perp = d - e1 * cosA;
    float sinA = length(perp);
    float3 e2 = sinA > 1e-6 ? perp / sinA : normalize(cross(e1, float3(1, 0, 0)));
    float B = D * sinA;

    float l = sqrt(max(D * D - b0 * b0, 0.0));
    float p = cosA;
    float phi = 0.0;
    int ev = 0;
    ShellRec s0, s1;

    for (int i = 0; i < 2500; i++) {
        float r = sqrt(b0 * b0 + l * l);
        if (abs(l) > D * 3.0 && l * p > 0.0) break;
        float ds = clamp(0.02 * r, 0.005, 1.0);
        float a0 = B * B * l / (r * r * r * r);
        float nl = l + p * ds + 0.5 * a0 * ds * ds;
        float nr = sqrt(b0 * b0 + nl * nl);
        float a1 = B * B * nl / (nr * nr * nr * nr);
        float np = p + 0.5 * (a0 + a1) * ds;
        float nphi = phi + 0.5 * (B / (r * r) + B / (nr * nr)) * ds;

        if (P.shells > 0.5 && l > 0.0 && nl > 0.0) {
            for (int k = 0; k < 2; k++) {
                float R = k == 0 ? P.shellR0 : P.shellR1;
                if ((r - R) * (nr - R) < 0.0) {
                    float t = (r - R) / (r - nr);
                    float lt = mix(l, nl, t), pt = mix(p, np, t), ph = mix(phi, nphi, t);
                    float3 radial = cos(ph) * e1 + sin(ph) * e2;
                    float3 tang = -sin(ph) * e1 + cos(ph) * e2;
                    float3 hv = (lt / R) * pt * radial + (B / R) * tang;
                    if (k == 0) recordShell(s0, R * radial, hv, R, ev++);
                    else        recordShell(s1, R * radial, hv, R, ev++);
                }
            }
        }
        l = nl; p = np; phi = nphi;
    }

    float r = sqrt(b0 * b0 + l * l);
    float3 radial = cos(phi) * e1 + sin(phi) * e2;
    float3 tang = -sin(phi) * e1 + cos(phi) * e2;
    float3 outDir = normalize((l / r) * p * radial + (B / r) * tang);
    bool far = l < 0.0;
    writeShells(P, s0, s1, shell0P, shell0D, shell1P, shell1D, gid);
    dirTex.write(float4(octEncode(outDir), 0.0, 0.0), gid);
    infoTex.write(float4((far ? -1.0 : 1.0) * (B / b0 + 0.001)), gid);
}

// ---------- bake: flat space (every scene without lensing) ----------

// Only the camera ray direction; no lensing features.
kernel void bakeFlat(BAKE_OUTPUTS)
{
    if (gid.x >= uint(P.width) || gid.y >= uint(P.height)) return;
    float3 camPos;
    float3 d = cameraRay(P, gid, camPos);
    dirTex.write(float4(octEncode(d), 0.0, 0.0), gid);
}
"""
}
