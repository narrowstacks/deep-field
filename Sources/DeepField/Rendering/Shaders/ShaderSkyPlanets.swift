extension ShaderSource {
    static let skyPlanets = """
// ---------- the real planets, for scenes that draw the real sky ----------
// A scene passes SkyPlanets.gpu(...) as fragment buffer 8 (mirrors SkyPlanetGPU), in its own
// frame, and calls skyPlanets() where its sky shows. Their names are drawn afterward, over the
// finished image (labelFragment, Renderer.encodeLabels).

struct SkyPlanet {
    float4 dir;     // direction, w = true angular radius (rad)
    float4 color;   // rgb, w = brightness (the stars' magnitude scale)
    float4 light;   // toward the sun from the planet, w = label shows (0/1)
    float4 pole;    // north pole, w = which planet (0 Mercury ... 6 Neptune)
};

// The planets in direction rd. At true size they're far smaller than a pixel, so each is a point
// of light spread over about a pixel with its real brightness: the peak doesn't depend on the
// pixel size, so a planet reads the same against the stars at any pixel size. Scaled up (`scale`
// times its true size) past about a pixel, it turns into a lit disk showing its phase, with bands
// on the giants and Saturn's rings, kept bright enough to see even for faint Neptune.
static float3 skyPlanets(float3 col, float3 rd, float pixAng, constant SkyPlanet* P, int count, float scale) {
    for (int i = 0; i < count; i++) {
        float3 dir = P[i].dir.xyz;
        float b = dot(rd, dir);
        if (b <= 0.0) continue;
        // the angle from the cross product: acos loses these tiny angles
        float d = asin(min(length(cross(rd, dir)), 1.0));
        float R = P[i].dir.w * scale;
        bool saturn = P[i].pole.w > 3.5 && P[i].pole.w < 4.5;
        float reach = max(R * (saturn ? 2.4 : 1.0), pixAng) * 3.0;
        if (d > reach) continue;
        float3 tint = P[i].color.rgb;
        // At true size, the real brightness: Neptune (magnitude 8) is below what the eye sees and
        // barely shows. Enlarged, the planets are meant to be found, so faint ones get a floor.
        float flux = max(P[i].color.w, 0.35 * smoothstep(1.0, 20.0, scale));
        float disk = smoothstep(0.6, 1.6, R / pixAng);
        // the point of light, fading out as the disk takes over
        float sigma = pixAng * 0.75;
        col += tint * flux * exp(-sq(d / sigma)) * (1.0 - disk);
        if (disk <= 0.0) continue;
        // the disk: a sphere of angular radius R at unit distance along dir
        float h = b * b - (1.0 - R * R);
        float tSphere = 1e9;
        float3 dcol = float3(0.0);
        float cover = 0.0;
        // the surface's brightness: its magnitude where that's bright enough to see, and a floor
        // so a scaled-up Uranus or Neptune still shows its disk
        float surface = clamp(flux * 0.3, 0.3, 0.8);
        if (h > 0.0) {
            tSphere = b - sqrt(h);
            float3 n = normalize(rd * tSphere - dir);
            float lit = max(dot(n, P[i].light.xyz), 0.0);
            float limb = 0.55 + 0.45 * max(dot(n, -rd), 0.0);
            float lat = asin(clamp(dot(n, P[i].pole.xyz), -1.0, 1.0));
            float bands = 1.0;
            if (P[i].pole.w > 2.5 && P[i].pole.w < 4.5) {
                bands = 0.82 + 0.18 * sin(lat * 14.0 + 1.3 * sin(lat * 5.0)) * (P[i].pole.w < 3.5 ? 1.0 : 0.6);
            }
            dcol = tint * bands * limb * lit * surface;
            cover = smoothstep(R + pixAng * 0.5, R - pixAng * 0.5, d);
        }
        if (saturn) {
            // the rings, in the equator's plane, from 1.24 to 2.27 radii with the Cassini gap
            float3 pole = P[i].pole.xyz;
            float denom = dot(rd, pole);
            if (abs(denom) > 1e-5) {
                float t = dot(dir, pole) / denom;
                float rr = length(rd * t - dir) / R;
                if (t > 0.0 && rr > 1.2 && rr < 2.3 && t < tSphere) {
                    float ring = smoothstep(1.2, 1.3, rr) * smoothstep(2.3, 2.2, rr) * (1.0 - 0.8 * exp(-sq((rr - 1.99) / 0.035)))
                               * (0.55 + 0.45 * smoothstep(1.5, 1.6, rr));
                    // we see the lit face when we're on the sun's side of the ring plane
                    float face = sign(dot(P[i].light.xyz, pole)) == sign(-denom) ? 1.0 : 0.3;
                    float3 rc = tint * float3(1.0, 0.97, 0.9) * surface * face * 0.85;
                    float a = ring * smoothstep(0.0, 0.25, abs(denom) * 4.0);
                    dcol = mix(dcol, rc, a);
                    cover = max(cover, a);
                }
            }
        }
        col = mix(col, dcol, cover * disk);
    }
    return col;
}
"""
}
