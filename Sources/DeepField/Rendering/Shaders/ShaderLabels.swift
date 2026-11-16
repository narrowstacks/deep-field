extension ShaderSource {
    static let labels = """
// ---------- labels: text over the finished frame ----------
// Drawn after tone mapping, dithering and bloom (Renderer.encodeLabels), as solid pixels blended
// over the image, so the letters stay clean instead of breaking up in the dither. The font is
// the brand's 5x7 pixel font (Design/Brand/pixelfont.py, SMALL), just the letters the names use:
// ACEIJMNPRSTUVY. Names for now are the planets'; add rows to LB_NAME for more.

constant uchar LB_GLYPH[14][7] = {
    {14, 17, 17, 31, 17, 17, 17}, {14, 17, 16, 16, 16, 17, 14}, {31, 16, 16, 30, 16, 16, 31},
    {7, 2, 2, 2, 2, 2, 7}, {7, 2, 2, 2, 2, 18, 12}, {17, 27, 21, 21, 17, 17, 17},
    {17, 17, 25, 21, 19, 17, 17}, {30, 17, 17, 30, 16, 16, 16}, {30, 17, 17, 30, 20, 18, 17},
    {15, 16, 16, 14, 1, 1, 30}, {31, 4, 4, 4, 4, 4, 4}, {17, 17, 17, 17, 17, 17, 14},
    {17, 17, 17, 17, 17, 10, 4}, {17, 17, 10, 4, 4, 4, 4} };
constant uchar LB_WIDTH[14] = {5, 5, 5, 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5};
// MERCURY, VENUS, MARS, JUPITER, SATURN, URANUS, NEPTUNE (255 ends a name)
constant uchar LB_NAME[7][8] = {
    {5, 2, 8, 1, 11, 8, 13, 255}, {12, 2, 6, 11, 9, 255, 255, 255}, {5, 0, 8, 9, 255, 255, 255, 255},
    {4, 11, 7, 3, 10, 2, 8, 255}, {9, 0, 10, 11, 8, 6, 255, 255}, {11, 8, 0, 6, 11, 9, 255, 255},
    {6, 2, 7, 10, 11, 6, 2, 255} };

// Whether font pixel (x, y) of name `name` is set (y = 0 at the top).
static bool lbPixel(int name, int x, int y) {
    if (y < 0 || y > 6 || x < 0 || name < 0 || name > 6) return false;
    int cursor = 0;
    for (int k = 0; k < 8; k++) {
        uchar c = LB_NAME[name][k];
        if (c == 255) return false;
        int w = LB_WIDTH[c];
        if (x < cursor + w) return ((LB_GLYPH[c][y] >> (w - 1 - (x - cursor))) & 1) != 0;
        cursor += w + 1;
    }
    return false;
}

// labels[i] = (left edge x, vertical center y, in target pixels; which name; font pixel size).
// info = (count, text brightness, shadow strength, unused).
fragment float4 labelFragment(VOut in [[stage_in]],
                              constant float4* labels [[buffer(0)]],
                              constant float4& info [[buffer(1)]]) {
    float2 p = in.pos.xy;
    float shadow = 0.0;
    for (int i = 0; i < int(info.x); i++) {
        float4 L = labels[i];
        float k = L.w;
        int x = int(floor((p.x - L.x) / k)), y = int(floor((p.y - (L.y - 3.5 * k)) / k));
        if (lbPixel(int(L.z), x, y)) return float4(float3(info.y), 1.0);
        // a one font-pixel shadow down and to the right keeps the letters legible over Earth
        if (lbPixel(int(L.z), x - 1, y - 1)) shadow = info.z;
    }
    if (shadow <= 0.0) discard_fragment();
    return float4(0.0, 0.0, 0.0, shadow);
}
"""
}
