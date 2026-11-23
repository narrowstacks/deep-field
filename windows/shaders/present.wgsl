// Scales the shaded frame up to the screen with nearest-neighbor filtering, so each cell stays a
// crisp block of pixels (the macOS compositor does this for the Metal layer; DWM would smooth it).

@group(0) @binding(0) var cells: texture_2d<f32>;
@group(0) @binding(1) var<uniform> scale: vec4<f32>;   // screen pixels per cell x, y; cell offset x, y

@fragment
fn presentFragment(in: VOut) -> @location(0) vec4<f32> {
    let size = vec2<i32>(textureDimensions(cells));
    let c = vec2<i32>(floor(in.pos.xy / scale.xy + scale.zw));
    return textureLoad(cells, clamp(c, vec2<i32>(0), size - 1), 0);
}
