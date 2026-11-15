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

// info = closest approach radius (0 = fell into the hole)
kernel void bakeBlackHole(BAKE_OUTPUTS)
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

    for (int i = 0; i < 1500; i++) {
        float r = length(pos);
        minR = min(minR, r);
        if (r < 1.0) { captured = true; break; }
        if (r > P.camDist * 1.6 && dot(pos, vel) > 0.0) break;

        float dt = clamp(0.03 * r, 0.004, 1.0);
        float3 a0 = accel(pos, h2);
        float3 np = pos + vel * dt + 0.5 * a0 * dt * dt;
        float3 a1 = accel(np, h2);
        float3 nv = vel + 0.5 * (a0 + a1) * dt;
        float nr = length(np);

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
    infoTex.write(float4(captured ? 0.0 : minR), gid);
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
