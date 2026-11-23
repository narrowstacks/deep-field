// ---------- labels: text over the finished frame ---------- (ShaderLabels.swift)
// Drawn after tone mapping, dithering and bloom (Renderer::encode_labels), as solid pixels
// blended over the image, so the letters stay clean instead of breaking up in the dither. The
// font is the brand's 5x7 pixel font (Design/Brand/pixelfont.py, SMALL), just the letters the
// names use: ACEIJMNPRSTUVY. Names for now are the planets'; add rows to LB_NAME for more.
// A module of its own (common + this file), with its own bindings and a blending pipeline.

@group(0) @binding(0) var<storage, read> labels: array<vec4<f32>>;
@group(0) @binding(1) var<uniform> info: vec4<f32>;

// private, not const: the glyph tables are indexed with values only known at run time
var<private> LB_GLYPH: array<array<u32, 7>, 14> = array<array<u32, 7>, 14>(
    array<u32, 7>(14u, 17u, 17u, 31u, 17u, 17u, 17u), array<u32, 7>(14u, 17u, 16u, 16u, 16u, 17u, 14u), array<u32, 7>(31u, 16u, 16u, 30u, 16u, 16u, 31u),
    array<u32, 7>(7u, 2u, 2u, 2u, 2u, 2u, 7u), array<u32, 7>(7u, 2u, 2u, 2u, 2u, 18u, 12u), array<u32, 7>(17u, 27u, 21u, 21u, 17u, 17u, 17u),
    array<u32, 7>(17u, 17u, 25u, 21u, 19u, 17u, 17u), array<u32, 7>(30u, 17u, 17u, 30u, 16u, 16u, 16u), array<u32, 7>(30u, 17u, 17u, 30u, 20u, 18u, 17u),
    array<u32, 7>(15u, 16u, 16u, 14u, 1u, 1u, 30u), array<u32, 7>(31u, 4u, 4u, 4u, 4u, 4u, 4u), array<u32, 7>(17u, 17u, 17u, 17u, 17u, 17u, 14u),
    array<u32, 7>(17u, 17u, 17u, 17u, 17u, 10u, 4u), array<u32, 7>(17u, 17u, 10u, 4u, 4u, 4u, 4u));
var<private> LB_WIDTH: array<i32, 14> = array<i32, 14>(5, 5, 5, 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5);
// MERCURY, VENUS, MARS, JUPITER, SATURN, URANUS, NEPTUNE (255 ends a name)
var<private> LB_NAME: array<array<u32, 8>, 7> = array<array<u32, 8>, 7>(
    array<u32, 8>(5u, 2u, 8u, 1u, 11u, 8u, 13u, 255u), array<u32, 8>(12u, 2u, 6u, 11u, 9u, 255u, 255u, 255u), array<u32, 8>(5u, 0u, 8u, 9u, 255u, 255u, 255u, 255u),
    array<u32, 8>(4u, 11u, 7u, 3u, 10u, 2u, 8u, 255u), array<u32, 8>(9u, 0u, 10u, 11u, 8u, 6u, 255u, 255u), array<u32, 8>(11u, 8u, 0u, 6u, 11u, 9u, 255u, 255u),
    array<u32, 8>(6u, 2u, 7u, 10u, 11u, 6u, 2u, 255u));

// Whether font pixel (x, y) of name `name` is set (y = 0 at the top).
fn lbPixel(name: i32, x: i32, y: i32) -> bool {
    if (y < 0 || y > 6 || x < 0 || name < 0 || name > 6) { return false; }
    var cursor = 0;
    for (var k = 0; k < 8; k++) {
        let c = LB_NAME[name][k];
        if (c == 255u) { return false; }
        let w = LB_WIDTH[c];
        if (x < cursor + w) { return ((LB_GLYPH[c][y] >> u32(w - 1 - (x - cursor))) & 1u) != 0u; }
        cursor += w + 1;
    }
    return false;
}

// labels[i] = (left edge x, vertical center y, in target pixels; which name; font pixel size).
// info = (count, text brightness, shadow strength, unused).
@fragment
fn labelFragment(in: VOut) -> @location(0) vec4<f32> {
    let p = in.pos.xy;
    var shadow = 0.0;
    for (var i = 0; i < i32(info.x); i++) {
        let L = labels[i];
        let k = L.w;
        let x = i32(floor((p.x - L.x) / k));
        let y = i32(floor((p.y - (L.y - 3.5 * k)) / k));
        if (lbPixel(i32(L.z), x, y)) { return vec4<f32>(vec3<f32>(info.y), 1.0); }
        // a one font-pixel shadow down and to the right keeps the letters legible over Earth
        if (lbPixel(i32(L.z), x - 1, y - 1)) { shadow = info.z; }
    }
    if (shadow <= 0.0) { discard; }
    return vec4<f32>(0.0, 0.0, 0.0, shadow);
}
