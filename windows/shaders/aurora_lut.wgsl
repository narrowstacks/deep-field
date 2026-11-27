// ---------- per-frame: aurora from orbit, the curtains' table ---------- (ShaderAurora.swift)
// The auroraLUT kernel and the edge wiggle it tabulates. A module of its own (common +
// this file), since it writes the table the frame module's auroraFragment then samples; see
// aurora.wgsl for the scene and its SceneParams slots.

@group(0) @binding(0) var<uniform> F: FrameParams;
@group(0) @binding(1) var<uniform> S: SceneParams;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;

// How far the oval's edge is pushed out at angle psi round the pole: a slow meander, folds that
// travel along it, and the surge of a substorm.
fn auWiggle(psi: f32, T: f32, act: f32, sub: f32, storm: f32, seed: f32) -> f32 {
    let slow = (noise3(vec3<f32>(psi * 4.0, T * 0.02 * act, seed)) - 0.5) * 0.06
             + (noise3(vec3<f32>(psi * 11.0, T * 0.05 * act, seed + 3.0)) - 0.5) * 0.025;
    // folds running along the curtain, and tighter curls riding on them
    // A substorm speeds them up through `storm`, worked out on the CPU as the running total of
    // the extra speed, so they gather pace smoothly. Scaling the clock itself by the storm's
    // strength would move them by T times its rate of change, a frantic race hours into a run.
    let clock = T * act + storm;
    let folds = sin(psi * 26.0 - clock * 0.3 + 3.0 * noise3(vec3<f32>(psi * 9.0, T * 0.03 * act, 2.0))) * 0.006
              + sin(psi * 70.0 + clock * 0.6 + 2.0 * noise3(vec3<f32>(psi * 20.0, seed, T * 0.05 * act))) * 0.0018;
    return slow + folds * (1.8 + 1.2 * sub);
}

// The curtains' structure along the oval depends only on the angle round the pole and on time,
// so it is worked out once per frame for every angle instead of at every step of every ray.
// Row 0 holds (edge wiggle, fine rays, broad rays, patches); row 1 holds (red top height, hue
// mix, fine rays to the 2.5, broad rays cubed).
@compute @workgroup_size(64, 1)
fn auroraLUT(@builtin(global_invocation_id) gid3: vec3<u32>) {
    let gid = gid3.xy;
    let width = textureDimensions(dst).x;
    if (gid.x >= width || gid.y > 0u) { return; }
    let psi = ((f32(gid.x) + 0.5) / f32(width) * 2.0 - 1.0) * PI;
    let T = F.time;
    let act = S.c.w;
    let sub = S.d.w;
    let seed = S.g.y;
    let r1 = noise3(vec3<f32>(psi * 220.0 + T * 0.6 * act, T * 0.7 * act, seed));
    let r2 = noise3(vec3<f32>(psi * 70.0 - T * 0.25 * act, T * 0.35 * act, seed + 9.0));
    var patches = 0.6 + 0.9 * smoothstep(0.25, 0.75, noise3(vec3<f32>(psi * 7.0, T * 0.06 * act, seed + 4.0)));
    patches *= 0.8 + 0.6 * smoothstep(0.0, 1.0, sin(psi * 12.0 - T * 0.45 * act + 2.0 * noise3(vec3<f32>(psi * 3.0, T * 0.02, seed))));
    let topH = 0.03 + 0.012 * noise3(vec3<f32>(psi * 16.0, T * 0.03 * act, seed + 6.0));
    let hue = smoothstep(0.25, 0.75, noise3(vec3<f32>(psi * 5.0, T * 0.04 * act, seed + 12.0)));
    textureStore(dst, vec2<i32>(i32(gid.x), 0), vec4<f32>(auWiggle(psi, T, act, sub, S.h.x, seed), r1, r2, patches));
    textureStore(dst, vec2<i32>(i32(gid.x), 1), vec4<f32>(topH, hue, pow(r1, 2.5), pow(r2, 3.0)));
}
