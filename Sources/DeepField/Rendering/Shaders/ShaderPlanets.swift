extension ShaderSource {
    static let planets = """
// ---------- per-frame: planets (lensed scenes and star systems) ----------

// Planet surface at normal N, seen along v, lit by every light.
static float3 shadePlanetSurface(Planet pl, float3 N, float3 v, float3 P,
                                 constant Light* lights, int lightCount) {
    float sa = pl.misc.x, cs = cos(sa), sn = sin(sa);
    float3 q = float3(cs * N.x - sn * N.z, N.y, sn * N.x + cs * N.z);
    float seed = pl.colorB.w;
    float bands = fbm(float3(q.x * 1.6, q.y * pl.misc.y, q.z * 1.6) + seed);
    float storms = noise3(q * 5.0 + seed * 2.0);
    float3 surf = mix(pl.colorB.rgb, pl.colorA.rgb, smoothstep(0.3, 0.7, bands + (storms - 0.5) * 0.35));

    float3 lit = float3(0.0);
    float day = 0.0;
    for (int i = 0; i < lightCount; i++) {
        float3 L = normalize(lights[i].pos.xyz - P);
        float nl = dot(N, L);
        lit += lights[i].color.rgb * lights[i].pos.w * saturate(nl);
        day = max(day, saturate(nl * 0.5 + 0.5));
    }
    float3 col = surf * (lit * 1.25 + 0.02);
    col += surf * float3(0.08, 0.14, 0.35) * pow(1.0 - day, 2.0) * 0.25;
    float rim = pow(1.0 - saturate(dot(N, -v)), 3.0);
    col += float3(0.35, 0.60, 1.00) * rim * pl.misc.z * (0.25 + day);
    return col;
}

// A ray crossing a planet's orbit shell at X heading v; treat it as straight near the planet
// and intersect each planet's sphere. Only the half-chord on this side of the shell counts.
static float4 shadePlanetsOnShell(float3 X, float3 v, int shell, constant Planet* planets, int count,
                                  constant Light* lights, int lightCount) {
    float best = 1e9;
    float4 out = float4(0.0);
    float halfChord = abs(dot(X, v));
    bool inbound = dot(X, v) < 0.0;
    for (int i = 0; i < count; i++) {
        Planet pl = planets[i];
        if (int(pl.center.w) != shell) continue;
        float3 C = pl.center.xyz;
        float rp = pl.colorA.w;
        float3 oc = X - C;
        float b = dot(oc, v);
        float c = dot(oc, oc) - rp * rp;
        float disc = b * b - c;
        if (disc <= 0.0) continue;
        float t = -b - sqrt(disc);
        if (inbound ? (t < -rp || t > halfChord + rp) : (t > rp || t < -halfChord - rp)) continue;
        float key = inbound ? t : -t;
        if (key >= best) continue;
        best = key;
        float3 P = X + v * t;
        out = float4(shadePlanetSurface(pl, normalize(P - C), v, P, lights, lightCount), 1.0);
    }
    return out;
}
"""
}
