// ---------- scene transitions between two finished frames ---------- (ShaderCommon.swift)
// Its own module (with common.wgsl and output.wgsl, for the dither patterns). T[0] = progress
// (eased, 0..1), seed, style, -; T[1] = levels and dither of the outgoing and incoming looks.
// Positions are in units of the frame's height, x running 0..aspect.

// output.wgsl reads these; only `blueNoise64` is reached from here (through ditherAt), so `F` is
// declared for the module to parse but left out of the pipeline's layout.
@group(0) @binding(10) var<uniform> F: FrameParams;
@group(0) @binding(18) var<storage, read> blueNoise64: array<u32>;
@group(0) @binding(19) var mirrored: sampler;
@group(0) @binding(0) var fromTex: texture_2d<f32>;
@group(0) @binding(1) var toTex: texture_2d<f32>;
@group(0) @binding(2) var<uniform> T: array<vec4<f32>, 2>;

// Dithers a blended color back onto the levels, so a transition stays on the wallpaper's
// palette. A color already on a level comes back unchanged (the 0.02 margin absorbs its 8-bit
// rounding), so the parts of a frame that aren't moving or mixing keep their exact pixels.
fn requantize(c: vec3<f32>, p: vec2<u32>, levels: f32, dither: f32) -> vec3<f32> {
    let L = max(levels - 1.0, 1.0);
    return saturate(floor(c * L + 0.02 + 0.96 * ditherAt(p, dither)) / L);
}

// Bilinear, so a moved or scaled frame is smoothed before it's dithered again; mirrored, so a
// soft edge that reaches past the frame shows something plausible rather than a smear.
fn sampleAt(tex: texture_2d<f32>, pos: vec2<f32>, aspect: f32) -> vec3<f32> {
    return textureSampleLevel(tex, mirrored, pos / vec2<f32>(aspect, 1.0), 0.0).rgb;
}

// A moved or scaled frame, averaged over a disk of `radius` source pixels first. Resampled as it
// is, its dither cells beat against the new dither into blocky checks; averaged, the dither is
// smoothed back toward the light it stood for. Radius 0 is a plain sample, so the end of a
// transition lands on the exact frame.
fn sampleSoft(tex: texture_2d<f32>, pos: vec2<f32>, aspect: f32, radius: f32) -> vec3<f32> {
    var sum = sampleAt(tex, pos, aspect);
    if (radius < 0.05) { return sum; }
    let px = radius / f32(textureDimensions(tex).y);
    for (var i = 0; i < 8; i++) {
        let a = f32(i) * 0.785398 + 0.39;
        sum += sampleAt(tex, pos + vec2<f32>(cos(a), sin(a)) * px * select(0.55, 1.0, i % 2 == 0), aspect);
    }
    return sum / 9.0;
}

@fragment
fn transitionFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    let t = T[0].x;
    let seed = T[0].y;
    let style = T[0].z;
    let size = vec2<f32>(textureDimensions(fromTex));
    let aspect = size.x / size.y;
    let q = (vec2<f32>(p) + 0.5) / size.y;
    let c = vec2<f32>(aspect * 0.5, 0.5);

    if (style < 0.5) {
        // Dissolve: each pixel switches once the progress passes its own threshold, mostly a
        // broad noise field (the new scene grows in from soft patches) plus a Bayer term that
        // turns each patch's edge into a dithered gradient instead of a line.
        let n = smoothstep(0.25, 0.75, fbm(vec3<f32>(q * 2.2, seed)));
        let threshold = 0.65 * n + 0.35 * bayer8(p);
        if (threshold < t * 1.02 - 0.01) { return textureLoad(toTex, p, 0); }
        return textureLoad(fromTex, p, 0);
    }

    var a: vec3<f32>;     // outgoing and incoming light at this pixel
    var b: vec3<f32>;
    var w: f32;           // how much of the incoming look shows
    if (style < 1.5) {
        // Crossfade
        a = textureLoad(fromTex, p, 0).rgb; b = textureLoad(toTex, p, 0).rgb; w = t;
    } else if (style < 2.5) {
        // Pan: the camera slides along a strip with the old frame, a soft band, then the new
        // frame, so the two meet in a wide blend rather than at a seam. The seed picks the side.
        let band = 0.35;
        let dir = select(-1.0, 1.0, fract(seed * 0.37) < 0.5);
        var u = q.x / aspect;
        if (dir < 0.0) { u = 1.0 - u; }
        let X = u + t * (1.0 + band);
        var uo = X;
        var un = X - (1.0 + band);
        if (dir < 0.0) { uo = 1.0 - uo; un = 1.0 - un; }
        let soft = 1.5 * sin(3.14159 * t);
        a = sampleSoft(fromTex, vec2<f32>(uo * aspect, q.y), aspect, soft);
        b = sampleSoft(toTex, vec2<f32>(un * aspect, q.y), aspect, soft);
        // past each frame's edge the mirrored sampling would show a reflection; it fades to the
        // dark of space instead, so the gap between the scenes reads as empty sky
        a *= 1.0 - smoothstep(1.0, 1.0 + 0.6 * band, X);
        b *= smoothstep(1.0 + 0.4 * band, 1.0 + band, X);
        w = smoothstep(1.0, 1.0 + band, X);
    } else if (style < 3.5) {
        // Drift away: the old scene recedes, shrinking toward a far corner, while its dark sky
        // fades out first, so its bright objects float away over the new scene, which settles in
        // from slightly closer as the camera arrives.
        let ang = seed * 2.4;
        let dir = vec2<f32>(cos(ang) * aspect * 0.45, sin(ang) * 0.4);
        let sc = mix(1.0, 0.25, t);
        let P = c + (q - c - dir * t) / sc;
        a = sampleSoft(fromTex, P, aspect, min(t * 8.0, 1.0) * max(1.5, 0.8 / sc));
        let edge = min(min(P.x, aspect - P.x), min(P.y, 1.0 - P.y));
        let luma = dot(a, vec3<f32>(0.2126, 0.7152, 0.0722));
        let keep = max(smoothstep(0.08, 0.35, luma), 1.0 - smoothstep(0.0, 0.45, t));
        // the frame's border softens only once it starts to shrink, so the first frame is exact
        let border = mix(1.0, smoothstep(0.0, 0.08, edge), min(t * 10.0, 1.0));
        let alpha = keep * border * (1.0 - smoothstep(0.6, 1.0, t));
        b = sampleSoft(toTex, c + (q - c) * mix(0.85, 1.0, t), aspect, 2.0 * (1.0 - t));
        w = 1.0 - alpha;
    } else if (style < 4.5) {
        // Warp: flying forward, the old scene streaks outward and a hole opens at the center onto
        // the new one, which settles from a closer view.
        let zoom = 1.0 + 2.5 * t * t;
        a = vec3<f32>(0.0);
        let soft = min(t * 8.0, 1.0) * 1.5;
        for (var i = 0; i < 4; i++) { a += sampleSoft(fromTex, c + (q - c) / (zoom * (1.0 + 0.05 * f32(i) * t)), aspect, soft); }
        a *= 0.25;
        b = sampleSoft(toTex, c + (q - c) * mix(0.7, 1.0, t), aspect, 2.0 * (1.0 - t));
        let R = mix(-0.4, length(c), t);
        w = 1.0 - smoothstep(R, R + 0.4, length(q - c));
    } else {
        // Black hole: a point mass sweeps across, and the new scene lies behind its path. Each
        // pixel sees the source position of the lens equation, beta = theta - thetaE^2 theta/|theta|^2,
        // so the boundary between the scenes bends into an Einstein ring around it.
        let thE = 0.2 * sin(3.14159 * t);
        let L = vec2<f32>(mix(-0.5, aspect + 0.5, t), 0.5 + 0.12 * sin(seed * 1.7));
        let d = q - L;
        let r2 = max(dot(d, d), 1e-6);
        let r = sqrt(r2);
        let src = q - thE * thE * d / r2;
        let soft = 1.5 * sin(3.14159 * t);
        a = sampleSoft(fromTex, src, aspect, soft);
        b = sampleSoft(toTex, src, aspect, soft);
        w = smoothstep(-0.15, 0.15, L.x - src.x);
        var col = mix(a, b, w);
        col *= smoothstep(0.45 * thE, 0.8 * thE, r);                                   // shadow
        col += 0.25 * (thE / 0.2) * exp(-sq((r - thE) / (0.06 * thE + 0.002))) * vec3<f32>(1.0, 0.85, 0.7);   // photon ring
        let late = w > 0.5;
        return vec4<f32>(requantize(col, p, select(T[1].x, T[1].z, late), select(T[1].y, T[1].w, late)), 1.0);
    }
    let late = w > 0.5;
    return vec4<f32>(requantize(mix(a, b, w), p, select(T[1].x, T[1].z, late), select(T[1].y, T[1].w, late)), 1.0);
}
