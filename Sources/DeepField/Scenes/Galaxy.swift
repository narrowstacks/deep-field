import Foundation
import simd

/// Galaxy rotation, following observed rotation curves.
///
/// With a dark matter halo the circular speed rises and then stays flat out to the edge,
/// which is what real galaxies do. Without one, the speed follows the visible mass alone:
/// it peaks near the center and then falls off like a Kepler orbit (v ~ 1/sqrt(r)), so the
/// outskirts lag far behind.
///
/// Stars orbit at their own angular speed omega(r) = v(r) / r. Spiral arms and bars are
/// density waves: patterns that turn rigidly at a single "pattern speed" while stars drift
/// through them, which is why the arms don't wind up. The shader mirrors these formulas.
enum GalaxyModel {
    /// Circular speed at radius r (fraction of the visible radius), peak normalized to about 1.
    static func velocity(_ r: Double, darkMatter: Bool) -> Double {
        if darkMatter { return 1 - exp(-r / 0.12) }
        let a = 0.08                                        // Plummer scale of the visible mass
        return r / pow(r * r + a * a, 0.75) * a.squareRoot() / 0.6204
    }

    static func omega(_ r: Double, darkMatter: Bool, scale: Double) -> Double {
        scale * velocity(r, darkMatter: darkMatter) / max(r, 0.01)
    }

    static func gpu(_ c: WallpaperConfig, elapsed t: Double) -> GalaxyGPU {
        // velocity scale: with a halo, an edge star completes an orbit in galaxyRotationMinutes
        let scale = 2 * .pi / (c.galaxyRotationMinutes * 60) / velocity(1, darkMatter: true)
        let barLength = 0.28
        // corotation: arms at mid-disk, bars just beyond their ends
        let corotation = c.galaxyType == .barred ? barLength * 1.2 : 0.55
        let patternSpeed = omega(corotation, darkMatter: c.darkMatter, scale: scale)
        let solidBody = omega(0.5, darkMatter: c.darkMatter, scale: scale)  // dwarf irregulars rotate nearly rigidly
        let flowPeriod = c.galaxyRotationMinutes * 60 * 0.15
        // satellite galaxies orbit out in the halo, at the speed the rotation curve gives there
        // (radii match the shader's `satellite` calls); without dark matter they crawl
        func satelliteAngle(_ r: Double, _ phase: Double) -> Float {
            Float((phase + omega(r, darkMatter: c.darkMatter, scale: scale) * t).truncatingRemainder(dividingBy: 2 * .pi))
        }
        let p = c.palette
        return GalaxyGPU(
            shape: SIMD4(c.galaxyType.shaderIndex, Float(c.galaxyArms), Float(tan(c.galaxyPitch / 180 * .pi)), Float(barLength)),
            motion: SIMD4(Float((patternSpeed * t).truncatingRemainder(dividingBy: 2 * .pi)), Float(scale),
                          c.darkMatter ? 1 : 0, Float(flowPeriod)),
            core: p.galaxyCore.simd, arms: p.galaxyArms.simd, nebula: p.galaxyNebula.simd, dust: p.galaxyDust.simd,
            misc: SIMD4(Float(8.5 * c.galaxySize), Float((solidBody * t).truncatingRemainder(dividingBy: 2 * .pi)),
                        satelliteAngle(1.15, 2.2), satelliteAngle(1.6, 4.0)))
    }
}
