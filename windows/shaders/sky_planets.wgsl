// ---------- the real planets, for scenes that draw the real sky ---------- (ShaderSkyPlanets.swift)
// A scene passes sky_planets::gpu(...) as the skyP buffer (frame binding 34, mirrors
// SkyPlanetGpu), in its own frame, and calls skyPlanets() where its sky shows. Their names are
// drawn afterward, over the finished image (labels.wgsl, Renderer::encode_labels).

struct SkyPlanet {
    dir: vec4<f32>,     // direction, w = true angular radius (rad)
    color: vec4<f32>,   // rgb, w = brightness (the stars' magnitude scale)
    light: vec4<f32>,   // toward the sun from the planet, w = label shows (0/1)
    pole: vec4<f32>,    // north pole, w = which planet (0 Mercury ... 6 Neptune)
}

// The planets in direction rd. At true size they're far smaller than a pixel, so each is a point
// of light spread over about a pixel with its real brightness: the peak doesn't depend on the
// pixel size, so a planet reads the same against the stars at any pixel size. Scaled up (`scale`
// times its true size) past about a pixel, it turns into a lit disk showing its phase, with bands
// on the giants and Saturn's rings, kept bright enough to see even for faint Neptune.
fn skyPlanets(col_in: vec3<f32>, rd: vec3<f32>, pixAng: f32, count: i32, scale: f32) -> vec3<f32> {
    var col = col_in;
    for (var i = 0; i < count; i++) {
        let P = skyP[i];
        let dir = P.dir.xyz;
        let b = dot(rd, dir);
        if (b <= 0.0) { continue; }
        // the angle from the cross product: acos loses these tiny angles
        let d = asin(min(length(cross(rd, dir)), 1.0));
        let R = P.dir.w * scale;
        let saturn = P.pole.w > 3.5 && P.pole.w < 4.5;
        let reach = max(R * select(1.0, 2.4, saturn), pixAng) * 3.0;
        if (d > reach) { continue; }
        let tint = P.color.rgb;
        // At true size, the real brightness: Neptune (magnitude 8) is below what the eye sees and
        // barely shows. Enlarged, the planets are meant to be found, so faint ones get a floor.
        let flux = max(P.color.w, 0.35 * smoothstep(1.0, 20.0, scale));
        let disk = smoothstep(0.6, 1.6, R / pixAng);
        // the point of light, fading out as the disk takes over
        let sigma = pixAng * 0.75;
        col += tint * flux * exp(-sq(d / sigma)) * (1.0 - disk);
        if (disk <= 0.0) { continue; }
        // the disk: a sphere of angular radius R at unit distance along dir
        let h = b * b - (1.0 - R * R);
        var tSphere = 1e9;
        var dcol = vec3<f32>(0.0);
        var cover = 0.0;
        // the surface's brightness: its magnitude where that's bright enough to see, and a floor
        // so a scaled-up Uranus or Neptune still shows its disk
        let surface = clamp(flux * 0.3, 0.3, 0.8);
        if (h > 0.0) {
            tSphere = b - sqrt(h);
            let n = normalize(rd * tSphere - dir);
            let lit = max(dot(n, P.light.xyz), 0.0);
            let limb = 0.55 + 0.45 * max(dot(n, -rd), 0.0);
            let lat = asin(clamp(dot(n, P.pole.xyz), -1.0, 1.0));
            var bands = 1.0;
            if (P.pole.w > 2.5 && P.pole.w < 4.5) {
                bands = 0.82 + 0.18 * sin(lat * 14.0 + 1.3 * sin(lat * 5.0)) * select(0.6, 1.0, P.pole.w < 3.5);
            }
            dcol = tint * bands * limb * lit * surface;
            cover = smoothstep(R + pixAng * 0.5, R - pixAng * 0.5, d);
        }
        if (saturn) {
            // the rings, in the equator's plane, from 1.24 to 2.27 radii with the Cassini gap
            let pole = P.pole.xyz;
            let denom = dot(rd, pole);
            if (abs(denom) > 1e-5) {
                let t = dot(dir, pole) / denom;
                let rr = length(rd * t - dir) / R;
                if (t > 0.0 && rr > 1.2 && rr < 2.3 && t < tSphere) {
                    let ring = smoothstep(1.2, 1.3, rr) * smoothstep(2.3, 2.2, rr) * (1.0 - 0.8 * exp(-sq((rr - 1.99) / 0.035)))
                             * (0.55 + 0.45 * smoothstep(1.5, 1.6, rr));
                    // we see the lit face when we're on the sun's side of the ring plane
                    let face = select(0.3, 1.0, sign(dot(P.light.xyz, pole)) == sign(-denom));
                    let rc = tint * vec3<f32>(1.0, 0.97, 0.9) * surface * face * 0.85;
                    let a = ring * smoothstep(0.0, 0.25, abs(denom) * 4.0);
                    dcol = mix(dcol, rc, a);
                    cover = max(cover, a);
                }
            }
        }
        col = mix(col, dcol, cover * disk);
    }
    return col;
}
