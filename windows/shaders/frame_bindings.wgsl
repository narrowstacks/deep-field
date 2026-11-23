// Resources of the per-frame scene pass (the Metal FRAME_INPUTS), group 0. Binding numbers
// match Renderer.Slot for the textures; see src/renderer.rs for the layout. Slots a scene
// doesn't use hold a 1x1 placeholder.
//
// Bake texture contents (formats differ from the Metal build, values are the same):
//   0 hitA, 1 hitB  black hole: disk crossings (radius, angle, redshift, event index + 1)
//   2 skyTex        star brightness, star tint (>1 = distant galaxy), nebula A, nebula B
//   3,4 / 5,6       planet shell 0 / 1 crossings (position, direction), lensed scenes with planets
//                   tidal disruption (no planets): 3 = stream, 5 = star
//   7 dirTex        octahedral sky direction (the camera ray in flat scenes), in .xy
//   8 infoTex       lensed scenes: closest approach (black hole) or side and impact parameter (wormhole)
//   9 idTex         star id for twinkles and pulsars, 1..4095 (0 = none), in .x

@group(0) @binding(0) var hitA: texture_2d<f32>;
@group(0) @binding(1) var hitB: texture_2d<f32>;
@group(0) @binding(2) var skyTex: texture_2d<f32>;
@group(0) @binding(3) var shell0P: texture_2d<f32>;
@group(0) @binding(4) var shell0D: texture_2d<f32>;
@group(0) @binding(5) var shell1P: texture_2d<f32>;
@group(0) @binding(6) var shell1D: texture_2d<f32>;
@group(0) @binding(7) var dirTex: texture_2d<f32>;
@group(0) @binding(8) var infoTex: texture_2d<f32>;
@group(0) @binding(9) var idTex: texture_2d<u32>;

@group(0) @binding(10) var<uniform> F: FrameParams;
@group(0) @binding(11) var<storage, read> planets: array<Planet>;
@group(0) @binding(12) var<uniform> E: Events;
@group(0) @binding(13) var<uniform> Pal: Palette;
@group(0) @binding(14) var<storage, read> stars: array<Star>;
@group(0) @binding(15) var<storage, read> lights: array<Light>;
@group(0) @binding(16) var<uniform> G: Galaxy;
@group(0) @binding(17) var<uniform> S: SceneParams;
@group(0) @binding(18) var<storage, read> blueNoise64: array<u32>;
@group(0) @binding(19) var linearClamp: sampler;

// Texel read with Metal's tex.read(uint2) semantics.
fn readTex(t: texture_2d<f32>, p: vec2<u32>) -> vec4<f32> { return textureLoad(t, vec2<i32>(p), 0); }
fn readId(p: vec2<u32>) -> u32 { return textureLoad(idTex, vec2<i32>(p), 0).x; }
