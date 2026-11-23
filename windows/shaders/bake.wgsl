// ---------- bake: shared ---------- (ShaderBake.swift)

fn cameraRay(gid: vec2<u32>, camPos: ptr<function, vec3<f32>>) -> vec3<f32> {
    let aspect = P.width / P.height;
    var uv = (vec2<f32>(gid) + 0.5) / vec2<f32>(P.width, P.height) * 2.0 - 1.0;
    uv.y = -uv.y;
    uv.x *= aspect;
    let cr = cos(P.roll);
    let sr = sin(P.roll);
    uv = vec2<f32>(cr * uv.x - sr * uv.y, sr * uv.x + cr * uv.y);
    let ce = cos(P.camElev);
    let se = sin(P.camElev);
    *camPos = vec3<f32>(0.0, se, -ce) * P.camDist;
    let fwd = normalize(vec3<f32>(P.lookX, P.lookY, 0.0) - *camPos);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    return normalize(fwd + (uv.x * right + uv.y * up) * P.tanHalfFov);
}

// A `var` of this type starts zeroed, like the Metal default member initializers.
struct ShellRec {
    pos: vec4<f32>,
    dir: vec4<f32>,
    n: i32,
}

// Up to two crossings of a sphere of radius R: where (theta, phi) and which way the ray was
// heading. Stored as unorm16 (see decodeShell): theta offset by 4 * eventIndex (so the frame
// shader knows what is in front of what) and mapped to (0, 1], with 0 = no crossing; phi to [0, 1].
fn recordShell(s: ptr<function, ShellRec>, hp: vec3<f32>, hv: vec3<f32>, R: f32, ev: i32) {
    if ((*s).n >= 2) { return; }
    let nrm = hp / R;
    let theta = (acos(clamp(nrm.y, -1.0, 1.0)) + 4.0 * f32(min(ev, 5)) + 0.5) / 25.0;
    let phi = atan2(nrm.z, nrm.x) / 6.2831853 + 0.5;
    let d = octEncode(normalize(hv));
    if ((*s).n == 0) {
        (*s).pos = vec4<f32>(theta, phi, (*s).pos.zw);
        (*s).dir = vec4<f32>(d, (*s).dir.zw);
    } else {
        (*s).pos = vec4<f32>((*s).pos.xy, theta, phi);
        (*s).dir = vec4<f32>((*s).dir.xy, d);
    }
    (*s).n++;
}

fn writeShells(s0: ShellRec, s1: ShellRec, gid: vec2<u32>) {
    if (P.shells < 0.5) { return; }
    textureStore(shell0P, vec2<i32>(gid), s0.pos);
    textureStore(shell0D, vec2<i32>(gid), s0.dir);
    textureStore(shell1P, vec2<i32>(gid), s1.pos);
    textureStore(shell1D, vec2<i32>(gid), s1.dir);
}

// ---------- bake: black hole ----------

// Photon in Schwarzschild spacetime (Schwarzschild radius = 1), written as a
// Newtonian-looking ODE: a = -1.5 h^2 r / |r|^5, with h = |r x v| conserved.
fn accel(p: vec3<f32>, h2: f32) -> vec3<f32> {
    let r2 = dot(p, p);
    return -1.5 * h2 * p / (r2 * r2 * sqrt(r2));
}

// ---------- bake: tidal disruption (star, stream and jets, traced with the black hole) ----------
// T is TDEGeometry.bake: a = (star center, radius), b = (near axis, far axis, stream start
// angle, stream end), c = (stream start radius, merge radius, winding, 0), d = (widths).

// The stream's centerline in the disk plane: radius at s (0 = leaving the star, 1 = merging
// with the disk's outer edge, beyond that it trails round the disk and thins out).
fn tdeStreamRadius(s: f32, drds: ptr<function, f32>) -> f32 {
    let r0 = T.c.x;
    let r1 = T.c.y;
    if (s < 1.0) {
        let k = 1.0 - s;
        *drds = -2.4 * (r0 - r1) * pow(max(k, 1e-4), 1.4);
        return r1 + (r0 - r1) * pow(k, 2.4);
    }
    *drds = -0.07 * r1;
    return r1 * (1.0 - 0.07 * (s - 1.0));
}

// Stream gas density at p (per unit length, normalized by the width), and where along (s) and
// across (u, in widths) the stream that point is.
fn tdeStream(p: vec3<f32>, sOut: ptr<function, f32>, uOut: ptr<function, f32>) -> f32 {
    let rp = length(p.xz);
    var rel = atan2(p.z, p.x) - T.b.z;
    rel -= 6.2831853 * floor(rel / 6.2831853);
    var best = 0.0;
    for (var k = 0; k < 2; k++) {
        let s = (rel + 6.2831853 * f32(k)) / T.c.z;
        if (s > T.b.w) { break; }
        var drds = 0.0;
        let rc = tdeStreamRadius(s, &drds);
        let cosA = inverseSqrt(1.0 + sq(drds / (T.c.z * rc)));
        let w = mix(T.d.x, T.d.y, smoothstep(0.0, 1.0, s)) * (1.0 + 0.6 * max(s - 1.0, 0.0));
        let h = w * 0.55;
        let u = (rp - rc) * cosA / w;
        let q = u * u + sq(p.y / h);
        if (q > 9.0) { continue; }
        let along = smoothstep(0.0, 0.04, s) * (1.0 - smoothstep(T.b.w - 0.5, T.b.w, s));
        let d = exp(-q) * along / w;
        if (d > best) { best = d; *sOut = s; *uOut = u; }
    }
    return best;
}

// Jet density at p: twin narrow cones along the spin axis.
fn tdeJet(p: vec3<f32>, jetLen: f32) -> f32 {
    let ay = abs(p.y);
    let wj = 0.16 + 0.035 * ay;      // bright spine, faint sheath
    let ws = 0.45 + 0.12 * ay;
    let rho2 = dot(p.xz, p.xz);
    let d = exp(-rho2 / (wj * wj)) / wj + 0.35 * exp(-rho2 / (ws * ws)) / ws;
    return d * smoothstep(1.2, 2.6, ay) * exp(-ay / jetLen);
}

// First hit of the straight segment o + d t (t in [0, len]) with the star: two half-ellipsoids
// joined at the middle, the near one stretched toward the hole. Returns t, or -1; nOut = the
// hit on the unit sphere in the star's frame (x toward the hole), mu = cosine to the viewer.
fn tdeStarHit(o: vec3<f32>, d: vec3<f32>, len: f32, nOut: ptr<function, vec3<f32>>, mu: ptr<function, f32>) -> f32 {
    let C = T.a.xyz;
    let ax = normalize(-C);
    let ay = vec3<f32>(0.0, 1.0, 0.0);
    let az = cross(ax, ay);
    let lo = vec3<f32>(dot(o - C, ax), dot(o - C, ay), dot(o - C, az));
    let ld = vec3<f32>(dot(d, ax), dot(d, ay), dot(d, az));
    let b = T.a.w * 0.93;
    var bestT = -1.0;
    for (var side = 0; side < 2; side++) {
        let sc = vec3<f32>(select(T.b.y, T.b.x, side == 0), b, b);
        let so = lo / sc;
        let sd = ld / sc;
        let A = dot(sd, sd);
        let B = dot(so, sd);
        let Cc = dot(so, so) - 1.0;
        let disc = B * B - A * Cc;
        if (disc < 0.0) { continue; }
        let sqD = sqrt(disc);    // `sq` in the Metal, renamed so it doesn't hide sq()
        for (var j = 0; j < 2; j++) {
            let t = (-B + select(sqD, -sqD, j == 0)) / A;
            if (t < 0.0 || t > len) { continue; }
            let hp = lo + ld * t;
            if ((side == 0) != (hp.x >= 0.0)) { continue; }
            if (bestT < 0.0 || t < bestT) {
                bestT = t;
                *nOut = normalize(hp / sc);
                *mu = saturate(-dot(normalize(hp / (sc * sc)), ld));
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
@compute @workgroup_size(8, 8)
fn bakeBlackHole(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    if (gid.x >= u32(P.width) || gid.y >= u32(P.height)) { return; }
    var camPos: vec3<f32>;
    let dir = cameraRay(gid, &camPos);

    var pos = camPos;
    var vel = dir;
    let h2c = cross(pos, vel);
    let h2 = dot(h2c, h2c);

    var A = vec4<f32>(0.0);
    var B = vec4<f32>(0.0);
    var hits = 0;
    var ev = 0;
    var s0: ShellRec;
    var s1: ShellRec;
    var minR = 1e9;
    var captured = false;
    let gCam = sqrt(1.0 - 1.0 / P.camDist);
    let shells = P.shells > 0.5;
    let tde = T.a.w > 0.0;
    var stream = vec2<f32>(0.0);
    var jets = vec2<f32>(0.0);
    var star = vec4<f32>(0.0, 0.0, -1e3, 0.0);
    var streamS = 0.0;
    var streamU = 0.0;
    var jetY = 0.0;
    let starReach = length(T.a.xyz) + T.b.x + 0.5;
    var hitStar = false;

    let maxSteps = select(1500, 2500, tde);
    for (var i = 0; i < maxSteps; i++) {
        let r = length(pos);
        minR = min(minR, r);
        if (r < 1.0) { captured = true; break; }
        if (r > P.camDist * 1.6 && dot(pos, vel) > 0.0) { break; }

        let dt = clamp(0.03 * r, 0.004, select(1.0, 0.4, tde));
        let a0 = accel(pos, h2);
        let np = pos + vel * dt + 0.5 * a0 * dt * dt;
        let a1 = accel(np, h2);
        let nv = vel + 0.5 * (a0 + a1) * dt;
        let nr = length(np);

        if (tde) {
            let seg = length(np - pos);
            let sd = (np - pos) / seg;
            // the star is opaque; straight segments are fine this far from the hole
            let toC = T.a.xyz - pos;
            let dc = length(toC - sd * clamp(dot(toC, sd), 0.0, seg));
            star.z = max(star.z, -dc / T.a.w);
            var len = seg;
            if (dc < T.b.x + 0.05) {
                var n = vec3<f32>(0.0);
                var mu = 0.0;
                let th = tdeStarHit(pos, sd, seg, &n, &mu);
                if (th >= 0.0) {
                    star = vec4<f32>(octEncode(n), mu, f32(min(ev, 5)) + 1.0);   // ev++ in the Metal
                    ev++;
                    hitStar = true;
                    len = th;
                }
            }
            // gas: the stream near the plane, the jets near the axis; 3 midpoint samples per step
            let nearPlane = min(abs(pos.y), abs(np.y)) < 2.0 || pos.y * np.y < 0.0;
            let streamZone = nearPlane && max(r, nr) > T.c.y * 0.75 - 1.0 && min(r, nr) < starReach;
            let jetZone = min(length(pos.xz), length(np.xz)) < 2.5 + 0.06 * max(abs(pos.y), abs(np.y));
            if (streamZone || jetZone) {
                let dl = len / 3.0;
                for (var k = 0; k < 3; k++) {
                    let q = pos + sd * (dl * (f32(k) + 0.5));
                    if (streamZone) {
                        var s = 0.0;
                        var u = 0.0;
                        let dens = tdeStream(q, &s, &u) * dl;
                        if (hits == 0) { stream.x += dens; } else { stream.y += dens; }
                        streamS += dens * s; streamU += dens * u;
                    }
                    if (jetZone) {
                        let dens = tdeJet(q, 6.0) * dl;
                        if (hits == 0) { jets.x += dens; } else { jets.y += dens; }
                        jetY += dens * abs(q.y);
                    }
                }
            }
            if (hitStar) { break; }
        }

        if (shells && (r - P.shellR0) * (nr - P.shellR0) < 0.0) {
            let t = (r - P.shellR0) / (r - nr);
            recordShell(&s0, mix(pos, np, t), mix(vel, nv, t), P.shellR0, ev);
            ev++;
        }
        if (shells && (r - P.shellR1) * (nr - P.shellR1) < 0.0) {
            let t = (r - P.shellR1) / (r - nr);
            recordShell(&s1, mix(pos, np, t), mix(vel, nv, t), P.shellR1, ev);
            ev++;
        }

        if (pos.y * np.y < 0.0 && hits < 2) {
            let t = pos.y / (pos.y - np.y);
            let hp = mix(pos, np, t);
            let rh = length(hp.xz);
            if (rh > P.diskIn * 0.85 && rh < P.diskOut * 1.1) {
                let phi = atan2(hp.z, hp.x);
                // circular orbit speed seen by a static observer
                let beta = min(sqrt(0.5 / max(rh - 1.0, 0.05)), 0.95);
                let gam = inverseSqrt(1.0 - beta * beta);
                let tang = vec3<f32>(-sin(phi), 0.0, cos(phi));
                let k = -normalize(mix(vel, nv, t));
                let dop = 1.0 / (gam * (1.0 - beta * dot(tang, k)));
                let g = dop * sqrt(max(1.0 - 1.0 / rh, 0.0)) / gCam;
                let h = vec4<f32>(rh, phi, g, f32(ev) + 1.0);   // ev++ in the Metal
                ev++;
                if (hits == 0) { A = h; } else { B = h; }
                hits++;
            }
        }
        pos = np;
        vel = nv;
    }

    textureStore(hitA, vec2<i32>(gid), A);
    textureStore(hitB, vec2<i32>(gid), B);
    writeShells(s0, s1, gid);
    textureStore(dirTex, vec2<i32>(gid), vec4<f32>(octEncode(normalize(vel)), 0.0, 0.0));
    if (tde) {
        let sc = stream.x + stream.y;
        let jc = jets.x + jets.y;
        textureStore(shell0P, vec2<i32>(gid), vec4<f32>(stream, select(0.0, streamS / sc, sc > 0.0), select(0.0, streamU / sc, sc > 0.0)));
        textureStore(shell1P, vec2<i32>(gid), star);
        textureStore(infoTex, vec2<i32>(gid), vec4<f32>(select(select(minR, 0.0, captured), 0.5, hitStar), jets, select(0.0, jetY / jc, jc > 0.0)));
    } else {
        textureStore(infoTex, vec2<i32>(gid), vec4<f32>(select(minR, 0.0, captured)));
    }
}

// ---------- bake: wormhole ----------

// Ellis wormhole: ds^2 = -dt^2 + dl^2 + (b0^2 + l^2) dOmega^2. Each ray stays in the plane
// through the camera and the throat, so we integrate (l, phi) in that plane with the
// conserved impact parameter B:  dl/ds = p,  dp/ds = B^2 l / r^4,  dphi/ds = B / r^2.
// Rays with B < b0 pass through the throat into the other universe (l < 0).
// info = side (+1 ours, -1 the other universe) * (impact parameter B / b0 + 0.001);
// B / b0 = 1 marks rays that just graze the throat.
@compute @workgroup_size(8, 8)
fn bakeWormhole(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    if (gid.x >= u32(P.width) || gid.y >= u32(P.height)) { return; }
    var camPos: vec3<f32>;
    let d = cameraRay(gid, &camPos);
    let b0 = P.throat;
    let D = P.camDist;
    let e1 = camPos / D;
    let cosA = dot(d, e1);
    let perp = d - e1 * cosA;
    let sinA = length(perp);
    var e2: vec3<f32>;
    if (sinA > 1e-6) { e2 = perp / sinA; } else { e2 = normalize(cross(e1, vec3<f32>(1.0, 0.0, 0.0))); }
    let B = D * sinA;

    var l = sqrt(max(D * D - b0 * b0, 0.0));
    var p = cosA;
    var phi = 0.0;
    var ev = 0;
    var s0: ShellRec;
    var s1: ShellRec;

    for (var i = 0; i < 2500; i++) {
        let r = sqrt(b0 * b0 + l * l);
        if (abs(l) > D * 3.0 && l * p > 0.0) { break; }
        let ds = clamp(0.02 * r, 0.005, 1.0);
        let a0 = B * B * l / (r * r * r * r);
        let nl = l + p * ds + 0.5 * a0 * ds * ds;
        let nr = sqrt(b0 * b0 + nl * nl);
        let a1 = B * B * nl / (nr * nr * nr * nr);
        let np = p + 0.5 * (a0 + a1) * ds;
        let nphi = phi + 0.5 * (B / (r * r) + B / (nr * nr)) * ds;

        if (P.shells > 0.5 && l > 0.0 && nl > 0.0) {
            for (var k = 0; k < 2; k++) {
                let R = select(P.shellR1, P.shellR0, k == 0);
                if ((r - R) * (nr - R) < 0.0) {
                    let t = (r - R) / (r - nr);
                    let lt = mix(l, nl, t);
                    let pt = mix(p, np, t);
                    let ph = mix(phi, nphi, t);
                    let radial = cos(ph) * e1 + sin(ph) * e2;
                    let tang = -sin(ph) * e1 + cos(ph) * e2;
                    let hv = (lt / R) * pt * radial + (B / R) * tang;
                    if (k == 0) { recordShell(&s0, R * radial, hv, R, ev); }
                    else        { recordShell(&s1, R * radial, hv, R, ev); }
                    ev++;
                }
            }
        }
        l = nl; p = np; phi = nphi;
    }

    let r = sqrt(b0 * b0 + l * l);
    let radial = cos(phi) * e1 + sin(phi) * e2;
    let tang = -sin(phi) * e1 + cos(phi) * e2;
    let outDir = normalize((l / r) * p * radial + (B / r) * tang);
    let far = l < 0.0;
    writeShells(s0, s1, gid);
    textureStore(dirTex, vec2<i32>(gid), vec4<f32>(octEncode(outDir), 0.0, 0.0));
    textureStore(infoTex, vec2<i32>(gid), vec4<f32>(select(1.0, -1.0, far) * (B / b0 + 0.001)));
}

// ---------- bake: flat space (every scene without lensing) ----------

// Only the camera ray direction; no lensing features.
@compute @workgroup_size(8, 8)
fn bakeFlat(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    if (gid.x >= u32(P.width) || gid.y >= u32(P.height)) { return; }
    var camPos: vec3<f32>;
    let d = cameraRay(gid, &camPos);
    textureStore(dirTex, vec2<i32>(gid), vec4<f32>(octEncode(d), 0.0, 0.0));
}
