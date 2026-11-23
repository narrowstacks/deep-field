// Per-frame output: tone map, saturate, posterize with ordered dither (ShaderCommon.swift).
// Reads the globals `F` (FrameParams) and `blueNoise64`, which every module that includes this
// file declares.

// Void-and-cluster blue noise: no grid and no clumps, so gradients read as fine, even grain.
fn blueNoise(p: vec2<u32>) -> f32 {
    return (f32(blueNoise64[(p.y & 63u) * 64u + (p.x & 63u)]) + 0.5) / 256.0;
}

// The threshold for each DitherPattern shader index; 2 (none) is a flat 0.5, plain rounding.
fn ditherAt(p: vec2<u32>, kind: f32) -> f32 {
    switch (i32(kind + 0.5)) {
        case 0: { return bayer8(p); }
        case 1: { return bayer4(p); }
        case 3: { return bayer2(p); }
        case 4: { return blueNoise(p); }
        case 5: { return halftone(p); }
        case 6: { return diagonalLines(p); }
        case 7: { return whiteNoise(p); }
        default: { return 0.5; }
    }
}

// The image controls, on light already scaled by the exposure: contrast around a mid gray,
// highlight rolloff and vignette, then the tone map and black point. Each is skipped at its
// neutral value, so the defaults leave the output exactly as it was.
fn toneMapped(x_in: vec3<f32>, p: vec2<u32>) -> vec3<f32> {
    var x = x_in;
    let im = F.image;
    if (im.x != 1.0) { x = 0.18 * pow(x / 0.18, vec3<f32>(im.x)); }
    if (im.z > 0.0) { x = x / (1.0 + im.z * x); }
    if (im.w > 0.0) {
        let uv = (vec2<f32>(p) + 0.5) / vec2<f32>(F.camRight.w, F.camUp.w) * 2.0 - 1.0;
        x *= 1.0 - im.w * smoothstep(0.2, 1.6, dot(uv, uv));
    }
    var col = 1.0 - exp(-x);
    if (im.y > 0.0) {
        let b = pow(im.y, 2.2);      // the black point is set in display (gamma) terms
        col = max(col - b, vec3<f32>(0.0)) / (1.0 - b);
    }
    return col;
}

// Saturate, gamma encode, and posterize with the chosen dither pattern.
fn quantized(col_in: vec3<f32>, p: vec2<u32>) -> vec4<f32> {
    let luma = dot(col_in, vec3<f32>(0.2126, 0.7152, 0.0722));
    var col = max(mix(vec3<f32>(luma), col_in, F.saturation), vec3<f32>(0.0));
    col = pow(col, vec3<f32>(1.0 / 2.2));
    let L = F.levels - 1.0;
    col = floor(col * L + ditherAt(p, F.dither)) / L;
    return vec4<f32>(saturate(col), 1.0);
}

// Every scene ends here. With bloom on, the scene pass instead writes its linear light to a
// float target, and imageFragment finishes it (with the glow added) after the bloom passes.
fn finalize(col: vec3<f32>, p: vec2<u32>) -> vec4<f32> {
    if (F.bloom.z > 0.5) { return vec4<f32>(col, 1.0); }
    return quantized(toneMapped(max(col, vec3<f32>(0.0)) * F.exposure, p), p);
}
