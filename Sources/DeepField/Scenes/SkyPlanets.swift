import Foundation
import simd

/// The real planets of our solar system as seen from Earth at a date: where they are, how bright,
/// how big, and which way their sun is, for any scene that draws the real sky (Live Earth first).
/// Positions from JPL's approximate Keplerian elements (Standish, valid 1800 to 2050), about
/// 0.1 degree against JPL Horizons; magnitudes from the Astronomical Almanac's formulas (Mallama's
/// for Venus). A scene turns the results into its own frame with `gpu(_:toScene:)` and draws them
/// with the shader's `skyPlanets` (Shaders/ShaderSkyPlanets.swift).
enum SkyPlanets {
    struct Planet {
        let index: Int                 // 0 Mercury ... 6 Neptune (also the label)
        let direction: SIMD3<Double>   // from Earth, J2000 equatorial, unit
        let distance: Double           // AU
        let magnitude: Double
        let radius: Double             // the disk's true angular radius, radians
        let toSun: SIMD3<Double>       // from the planet toward the sun, J2000 equatorial, unit
        let pole: SIMD3<Double>        // north pole, J2000 equatorial, unit
    }

    static let names = ["Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]

    private static let deg = Double.pi / 180
    private static let auKm = 149_597_870.7

    /// a (AU), e, I, L, longitude of perihelion, longitude of the node (degrees), and their rates
    /// per Julian century from J2000 (JPL Table 1). Earth's row is the Earth-Moon barycenter,
    /// about 4,700 km from Earth's center: far under a pixel for the planets.
    private static let elements: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
        (SIMD3(0.38709927, 0.20563593, 7.00497902), SIMD3(252.25032350, 77.45779628, 48.33076593),
         SIMD3(0.00000037, 0.00001906, -0.00594749), SIMD3(149472.67411175, 0.16047689, -0.12534081)),
        (SIMD3(0.72333566, 0.00677672, 3.39467605), SIMD3(181.97909950, 131.60246718, 76.67984255),
         SIMD3(0.00000390, -0.00004107, -0.00078890), SIMD3(58517.81538729, 0.00268329, -0.27769418)),
        (SIMD3(1.52371034, 0.09339410, 1.84969142), SIMD3(-4.55343205, -23.94362959, 49.55953891),
         SIMD3(0.00001847, 0.00007882, -0.00813131), SIMD3(19140.30268499, 0.44441088, -0.29257343)),
        (SIMD3(5.20288700, 0.04838624, 1.30439695), SIMD3(34.39644051, 14.72847983, 100.47390909),
         SIMD3(-0.00011607, -0.00013253, -0.00183714), SIMD3(3034.74612775, 0.21252668, 0.20469106)),
        (SIMD3(9.53667594, 0.05386179, 2.48599187), SIMD3(49.95424423, 92.59887831, 113.66242448),
         SIMD3(-0.00125060, -0.00050991, 0.00193609), SIMD3(1222.49362201, -0.41897216, -0.28867794)),
        (SIMD3(19.18916464, 0.04725744, 0.77263783), SIMD3(313.23810451, 170.95427630, 74.01692503),
         SIMD3(-0.00196176, -0.00004397, -0.00242939), SIMD3(428.48202785, 0.40805281, 0.04240589)),
        (SIMD3(30.06992276, 0.00859048, 1.77004347), SIMD3(-55.12002969, 44.96476227, 131.78422574),
         SIMD3(0.00026291, 0.00005105, 0.00035372), SIMD3(218.45945325, -0.32241464, -0.00508664)),
    ]
    private static let earthElements = (SIMD3(1.00000261, 0.01671123, -0.00001531), SIMD3(100.46457166, 102.93768193, 0.0),
                                        SIMD3(0.00000562, -0.00004392, -0.01294668), SIMD3(35999.37244981, 0.32327364, 0.0))
    /// Equatorial radii, km.
    private static let radiiKm = [2439.7, 6051.8, 3396.2, 71492, 60268, 25559, 24764]
    /// North poles (IAU): right ascension and declination, J2000, degrees.
    private static let poles: [(Double, Double)] = [(281.01, 61.42), (272.76, 67.16), (317.68, 52.89), (268.06, 64.50),
                                                     (40.59, 83.54), (257.31, -15.18), (299.36, 43.46)]

    static func planets(_ date: Date) -> [Planet] {
        let T = Astronomy.days(date) / 36525
        let earth = heliocentric(earthElements, T)
        let eps = 23.43928 * deg
        func equatorial(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(v.x, cos(eps) * v.y - sin(eps) * v.z, sin(eps) * v.y + cos(eps) * v.z)
        }
        return elements.indices.map { i in
            let p = heliocentric(elements[i], T)
            let g = p - earth
            let d = simd_length(g), r = simd_length(p)
            // the phase angle: sun to planet to Earth, degrees
            let phase = acos(min(max(simd_dot(p, g) / (r * d), -1), 1)) / deg
            let (ra, dec) = poles[i]
            let pole = SIMD3(cos(dec * deg) * cos(ra * deg), cos(dec * deg) * sin(ra * deg), sin(dec * deg))
            let dir = simd_normalize(equatorial(g))
            return Planet(index: i, direction: dir, distance: d,
                          magnitude: magnitude(i, r: r, d: d, phase: phase, pole: pole, view: dir),
                          radius: radiiKm[i] / (d * auKm), toSun: simd_normalize(equatorial(-p)), pole: pole)
        }
    }

    /// Visual magnitude: the planet's brightness at 1 AU from both, dimmed by distance, and by
    /// phase (as the lit part we see shrinks); Saturn brightens as its rings open toward us.
    private static func magnitude(_ i: Int, r: Double, d: Double, phase a: Double,
                                  pole: SIMD3<Double>, view: SIMD3<Double>) -> Double {
        let base = 5 * log10(r * d)
        switch i {
        case 0: return -0.42 + base + 0.0380 * a - 0.000273 * a * a + 0.000002 * a * a * a
        case 1: return -4.384 + base - 1.044e-3 * a + 3.687e-4 * a * a - 2.814e-6 * pow(a, 3) + 8.938e-9 * pow(a, 4)
        case 2: return -1.52 + base + 0.016 * a
        case 3: return -9.40 + base + 0.005 * a
        case 4:
            let b = abs(asin(min(max(simd_dot(pole, view), -1), 1)))   // the rings' tilt toward us
            return -8.88 + base - 2.60 * sin(b) + 1.25 * sin(b) * sin(b)
        case 5: return -7.19 + base
        default: return -6.87 + base
        }
    }

    /// Position around the sun, J2000 ecliptic, AU: Kepler's equation on the dated elements.
    private static func heliocentric(_ el: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
                                     _ T: Double) -> SIMD3<Double> {
        let a = el.0.x + el.2.x * T, e = el.0.y + el.2.y * T, inc = (el.0.z + el.2.z * T) * deg
        let L = el.1.x + el.3.x * T, peri = el.1.y + el.3.y * T, node = el.1.z + el.3.z * T
        let w = (peri - node) * deg, O = node * deg
        var M = (L - peri).truncatingRemainder(dividingBy: 360)
        if M > 180 { M -= 360 } else if M < -180 { M += 360 }
        M *= deg
        var E = M + e * sin(M)
        for _ in 0..<8 { E -= (E - e * sin(E) - M) / (1 - e * cos(E)) }
        let xp = a * (cos(E) - e), yp = a * (1 - e * e).squareRoot() * sin(E)
        let x = (cos(w) * cos(O) - sin(w) * sin(O) * cos(inc)) * xp + (-sin(w) * cos(O) - cos(w) * sin(O) * cos(inc)) * yp
        let y = (cos(w) * sin(O) + sin(w) * cos(O) * cos(inc)) * xp + (-sin(w) * sin(O) + cos(w) * cos(O) * cos(inc)) * yp
        let z = sin(w) * sin(inc) * xp + cos(w) * sin(inc) * yp
        return SIMD3(x, y, z)
    }

    /// Colors as they look to the eye, roughly: dusky Mercury, cream Venus, rusty Mars, tan
    /// Jupiter, pale gold Saturn, cyan Uranus, blue Neptune.
    static let colors: [SIMD3<Float>] = [SIMD3(0.78, 0.72, 0.66), SIMD3(1.0, 0.95, 0.82), SIMD3(1.0, 0.55, 0.34),
                                         SIMD3(0.95, 0.84, 0.68), SIMD3(0.95, 0.85, 0.6), SIMD3(0.66, 0.9, 0.95),
                                         SIMD3(0.45, 0.6, 1.0)]

    /// The planets for the shader, in a scene's frame (`toScene` turns a J2000 equatorial vector
    /// into it). `labelVisible` says whether the scene can see each one (not behind its own
    /// bodies), which is when its label shows.
    static func gpu(_ planets: [Planet], toScene: (SIMD3<Double>) -> SIMD3<Double>,
                    labelVisible: (SIMD3<Double>) -> Bool = { _ in true }) -> [SkyPlanetGPU] {
        planets.map { p in
            let dir = simd_normalize(toScene(p.direction))
            // the same magnitude scale as the catalog stars (leSky): flux to the 0.75, x4
            let brightness = 4 * exp2(-0.9966 * p.magnitude)
            return SkyPlanetGPU(dir: SIMD4(SIMD3<Float>(dir), Float(p.radius)),
                                color: SIMD4(colors[p.index], Float(brightness)),
                                light: SIMD4(SIMD3<Float>(simd_normalize(toScene(p.toSun))), labelVisible(dir) ? 1 : 0),
                                pole: SIMD4(SIMD3<Float>(simd_normalize(toScene(p.pole))), Float(p.index)))
        }
    }
}
