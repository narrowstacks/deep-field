// Metal source compiled at runtime (`MTLDevice.makeLibrary(source:)`), so the build needs no
// Metal toolchain. Each Shader*.swift file holds one area as a string; `full` joins them in
// dependency order (Metal needs declarations before use).
//
// Two stages:
//  1. Bake kernels (once per resize or bake-affecting setting) trace one light ray per pixel.
//     The camera never moves, so ray paths never change. They store where each ray crosses
//     the disk and the planet orbit shells, and which piece of sky it ends up seeing (as
//     scalars, so colors can be changed live without re-tracing). Then `skyPass` evaluates
//     the sky with detail filtered to each pixel's footprint.
//       bakeBlackHole: Schwarzschild geodesics (black hole, tidal disruption)
//       bakeWormhole:  Ellis wormhole geodesics (rays through the throat reach another universe)
//       bakeFlat:      straight rays (star systems, galaxy, pulsar, comet, star close-up)
//       bakeNebula:    ray-marched nebula volume (hidden nebula scene)
//  2. A fragment shader per frame reads those lookups, animates on top of them, applies the
//     palette, tone maps, and dithers: lensedFragment (black hole, tidal disruption, wormhole),
//     systemFragment, galaxyFragment, pulsarFragment, cometFragment, stellarFragment,
//     nebulaFragment, planetaryFragment, ringedFragment, auroraFragment,
//     gasGiantFragment, protoDiskFragment, neutronMergerFragment, dysonFragment, rogueFragment.
//
// Texture slots (Renderer.Slot). A scene allocates only the ones it uses (Renderer.formats);
// the rest are bound to a 1x1 placeholder and never read or written.
//   0 hitA, 1 hitB  black hole: disk crossings (radius, angle, redshift, event index + 1), float32
//                   nebula: two baked slices (Ha, OIII, SII, transmittance), half
//   2 sky           star brightness, star tint (>1 = distant galaxy), nebula A, nebula B; half
//   3,4 / 5,6       planet shell 0 / 1 crossings (position, direction), lensed scenes with
//                   planets only; unorm16 / snorm16 (see recordShell)
//                   tidal disruption (no planets): 3 = stream, 5 = star, half (see bakeBlackHole)
//   7 dir           octahedral sky direction (the camera ray in flat scenes), snorm16
//   8 info          lensed scenes: closest approach (black hole) or side and impact parameter
//                   (wormhole), see the bake kernels; float32 (rgba for the tidal disruption's jets)
//   9 starId        star id for twinkles and pulsars, 1..4095 (0 = none), uint16

enum ShaderSource {
    static var full: String {
        [common, bake, sky, planets, lensed, stars, galaxy, pulsar, comet, nebula, planetary, ringed, aurora, gasGiant, protoDisk, neutronMerger, dyson, roguePlanet, eclipse].joined(separator: "\n\n")
    }
}
