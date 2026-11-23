// Resources of the bake kernels (the Metal BAKE_OUTPUTS) and the sky pass, group 0.
// Outputs are storage textures; write with textureStore(t, vec2<i32>(gid), value).
// Kernels run in 8x8 workgroups over a grid rounded up to whole groups, so each one must return
// early for gid outside (P.width, P.height).

@group(0) @binding(0) var hitA: texture_storage_2d<rgba32float, write>;
@group(0) @binding(1) var hitB: texture_storage_2d<rgba32float, write>;
@group(0) @binding(3) var shell0P: texture_storage_2d<rgba32float, write>;
@group(0) @binding(4) var shell0D: texture_storage_2d<rgba32float, write>;
@group(0) @binding(5) var shell1P: texture_storage_2d<rgba32float, write>;
@group(0) @binding(6) var shell1D: texture_storage_2d<rgba32float, write>;
@group(0) @binding(7) var dirTex: texture_storage_2d<rg32float, write>;
@group(0) @binding(8) var infoTex: texture_storage_2d<rgba32float, write>;

@group(0) @binding(10) var<uniform> P: BakeParams;
@group(0) @binding(11) var<uniform> T: SceneParams;   // the tidal disruption's bake parameters

// skyPass (a second dispatch that sees the finished ray bake)
@group(0) @binding(20) var skyDirIn: texture_2d<f32>;
@group(0) @binding(21) var skyInfoIn: texture_2d<f32>;
@group(0) @binding(22) var skyOut: texture_storage_2d<rgba16float, write>;
@group(0) @binding(23) var idOut: texture_storage_2d<r32uint, write>;
