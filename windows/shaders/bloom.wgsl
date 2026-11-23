// ---------- bloom: bright pass at quarter size, separable blur, composite ---------- (ShaderCommon.swift)
// Its own module (with common.wgsl and output.wgsl), so these bindings don't meet the frame's.

@group(0) @binding(10) var<uniform> F: FrameParams;
@group(0) @binding(18) var<storage, read> blueNoise64: array<u32>;
@group(0) @binding(19) var linearClamp: sampler;
@group(0) @binding(30) var hdr: texture_2d<f32>;
@group(0) @binding(31) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(32) var src: texture_2d<f32>;
@group(0) @binding(33) var glow: texture_2d<f32>;
@group(0) @binding(34) var<uniform> B: vec4<f32>;      // blur direction xy, sigma

// Metal's coord::pixel sampling: `pos` in texels.
fn samplePx(t: texture_2d<f32>, pos: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(t, linearClamp, pos / vec2<f32>(textureDimensions(t)), 0.0).rgb;
}

// Linear light above the threshold (on the tone-mapped luminance), soft-kneed, in exposed units.
// Each pixel's light is capped first: a star (and more so a twinkling one) is a pixel or two far
// brighter than anything around it, and uncapped it would spread into a wide square halo.
fn brightPart(col: vec3<f32>) -> vec3<f32> {
    var x = max(col, vec3<f32>(0.0)) * F.exposure;
    let l = dot(x, vec3<f32>(0.2126, 0.7152, 0.0722));
    if (l > 2.5) { x *= 2.5 / l; }
    let lum = 1.0 - exp(-min(l, 2.5));
    return x * smoothstep(F.bloom.y, F.bloom.y + 0.3, lum);
}

// Each output texel covers 4x4 scene pixels. They're averaged with weights that fall with
// brightness (a Karis average): an even bright region keeps its plain mean, while a lone hot
// pixel among dark ones counts for much less, so it can't light up a halo on its own.
@compute @workgroup_size(8, 8)
fn bloomBright(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    let ds = textureDimensions(dst);
    if (gid.x >= ds.x || gid.y >= ds.y) { return; }
    let size = textureDimensions(hdr);
    var sum = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var y = 0u; y < 4u; y++) {
        for (var x = 0u; x < 4u; x++) {
            let q = min(gid * 4u + vec2<u32>(x, y), size - 1u);
            let b = brightPart(textureLoad(hdr, vec2<i32>(q), 0).rgb);
            let w = 1.0 / (1.0 + dot(b, vec3<f32>(0.2126, 0.7152, 0.0722)));
            sum += b * w;
            wsum += w;
        }
    }
    textureStore(dst, vec2<i32>(gid), vec4<f32>(sum / wsum, 1.0));
}

// Halves the bright pass for wide glows: each output texel is the mean of the 4x4 texels round
// its center, read as four bilinear taps. Blurring a smaller copy keeps the blur's taps about a
// texel apart; spread wider, they copy a sharp edge (Earth's limb) into rings and streaks.
@compute @workgroup_size(8, 8)
fn bloomDown(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    let ds = textureDimensions(dst);
    if (gid.x >= ds.x || gid.y >= ds.y) { return; }
    let c = vec2<f32>(gid) * 2.0 + 1.0;
    let sum = samplePx(src, c + vec2<f32>(-1.0, -1.0)) + samplePx(src, c + vec2<f32>(1.0, -1.0))
            + samplePx(src, c + vec2<f32>(-1.0, 1.0)) + samplePx(src, c + vec2<f32>(1.0, 1.0));
    textureStore(dst, vec2<i32>(gid), vec4<f32>(sum * 0.25, 1.0));
}

// A 17-tap Gaussian along `dir`, sigma in texels; taps spread to cover about 2.7 sigma. The
// renderer keeps sigma at 3 texels or less (see bloomDown), so the taps stay a texel apart.
@compute @workgroup_size(8, 8)
fn bloomBlur(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    let ds = textureDimensions(dst);
    if (gid.x >= ds.x || gid.y >= ds.y) { return; }
    let sigma = max(B.z, 0.5);
    let step_ = sigma / 3.0;
    let c = vec2<f32>(gid) + 0.5;
    var sum = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var i = -8; i <= 8; i++) {
        let o = f32(i) * step_;
        let w = exp(-0.5 * o * o / (sigma * sigma));
        sum += samplePx(src, c + B.xy * o) * w;
        wsum += w;
    }
    textureStore(dst, vec2<i32>(gid), vec4<f32>(sum / wsum, 1.0));
}

// The glow read with a cubic B-spline (four bilinear taps) instead of plain bilinear, so a glow
// blurred on a small texture comes back smooth instead of in visible diamonds and patches.
// `pos` is in the texture's pixels.
fn smoothGlow(pos: vec2<f32>) -> vec3<f32> {
    let tc = pos - 0.5;
    let i = floor(tc);
    let f = tc - i;
    let w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    let w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    let w3 = f * f * f / 6.0;
    let w2 = 1.0 - w0 - w1 - w3;
    let g0 = w0 + w1;
    let g1 = w2 + w3;
    let p0 = i - 0.5 + w1 / g0;
    let p1 = i + 1.5 + w3 / g1;
    return g0.y * (g0.x * samplePx(glow, vec2<f32>(p0.x, p0.y)) + g1.x * samplePx(glow, vec2<f32>(p1.x, p0.y)))
         + g1.y * (g0.x * samplePx(glow, vec2<f32>(p0.x, p1.y)) + g1.x * samplePx(glow, vec2<f32>(p1.x, p1.y)));
}

@fragment
fn imageFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<u32>(in.pos.xy);
    // F.bloom.w here is the glow texture's size relative to the frame (the renderer sets it)
    let x = max(textureLoad(hdr, vec2<i32>(p), 0).rgb, vec3<f32>(0.0)) * F.exposure
          + smoothGlow((vec2<f32>(p) + 0.5) * F.bloom.w) * F.bloom.x;
    return quantized(toneMapped(x, p), p);
}
