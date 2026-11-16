import Foundation
import simd

/// Where the sun and Moon are for the Live Earth scene, in Earth-fixed coordinates (x toward
/// 0 N 0 E, y toward 0 N 90 E, z the north pole; lengths in Earth radii). The sun to about 0.01
/// degrees (the almanac's low-precision formula) and the Moon to about 10 arcseconds, close
/// enough that eclipses happen when and where they really do.
enum Astronomy {
    private static let deg = Double.pi / 180

    /// Days since J2000.0 (2000 January 1, 12:00 TT, taken as UT).
    static func days(_ date: Date) -> Double { date.timeIntervalSince1970 / 86400 - 10957.5 }

    /// Greenwich mean sidereal time, radians: how far Earth has turned under the stars.
    static func gmst(_ n: Double) -> Double { (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360) * deg }

    static func obliquity(_ n: Double) -> Double { (23.439 - 0.0000004 * n) * deg }

    /// Unit vector toward the sun.
    static func sun(_ date: Date) -> SIMD3<Double> {
        let n = days(date)
        let L = (280.460 + 0.9856474 * n) * deg
        let g = (357.528 + 0.9856003 * n) * deg
        let lambda = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * deg
        return toEarthFixed(ecliptic(lambda, 0), n)
    }

    /// The Moon's center, Earth radii: the largest terms of Meeus' lunar theory (Astronomical
    /// Algorithms, chapter 47), good to about 10 arcseconds, which puts an eclipse's shadow within
    /// a few tens of kilometers of where it really falls.
    static func moon(_ date: Date) -> SIMD3<Double> {
        // the Moon's theory runs on Terrestrial Time, about 69 s ahead of the clock
        let T = (days(date) + 69 / 86400) / 36525
        let Lp = 218.3164477 + 481267.88123421 * T
        let D = 297.8501921 + 445267.1114034 * T
        let M = 357.5291092 + 35999.0502909 * T
        let Mp = 134.9633964 + 477198.8675055 * T
        let F = 93.2720950 + 483202.0175233 * T
        let E = 1 - 0.002516 * T
        let a1 = 119.75 + 131.849 * T, a2 = 53.09 + 479264.290 * T, a3 = 313.45 + 481266.484 * T
        var sl = 0.0, sr = 0.0, sb = 0.0
        for t in lunarLR {
            let a = (t.d * D + t.m * M + t.mp * Mp + t.f * F) * deg
            let e = pow(E, abs(t.m))
            sl += t.l * e * sin(a)
            sr += t.r * e * cos(a)
        }
        for t in lunarB {
            sb += t.b * pow(E, abs(t.m)) * sin((t.d * D + t.m * M + t.mp * Mp + t.f * F) * deg)
        }
        sl += 3958 * sin(a1 * deg) + 1962 * sin((Lp - F) * deg) + 318 * sin(a2 * deg)
        sb += -2235 * sin(Lp * deg) + 382 * sin(a3 * deg) + 175 * sin((a1 - F) * deg) + 175 * sin((a1 + F) * deg)
            + 127 * sin((Lp - Mp) * deg) - 115 * sin((Lp + Mp) * deg)
        let lambda = (Lp + sl / 1e6) * deg, beta = sb / 1e6 * deg
        let distance = (385000.56 + sr / 1000) / 6371
        return toEarthFixed(ecliptic(lambda, beta), days(date)) * distance
    }

    /// Meeus' tables 47.A and 47.B, terms down to about 7 arcseconds: multiples of the mean
    /// elongation D, the sun's anomaly M, the Moon's anomaly M' and its argument of latitude F;
    /// longitude and latitude in millionths of a degree, distance in meters.
    private static let lunarLR: [(d: Double, m: Double, mp: Double, f: Double, l: Double, r: Double)] = [
        (0, 0, 1, 0, 6288774, -20905355), (2, 0, -1, 0, 1274027, -3699111), (2, 0, 0, 0, 658314, -2955968),
        (0, 0, 2, 0, 213618, -569925), (0, 1, 0, 0, -185116, 48888), (0, 0, 0, 2, -114332, -3149),
        (2, 0, -2, 0, 58793, 246158), (2, -1, -1, 0, 57066, -152138), (2, 0, 1, 0, 53322, -170733),
        (2, -1, 0, 0, 45758, -204586), (0, 1, -1, 0, -40923, -129620), (1, 0, 0, 0, -34720, 108743),
        (0, 1, 1, 0, -30383, 104755), (2, 0, 0, -2, 15327, 10321), (0, 0, 1, 2, -12528, 0),
        (0, 0, 1, -2, 10980, 79661), (4, 0, -1, 0, 10675, -34782), (0, 0, 3, 0, 10034, -23210),
        (4, 0, -2, 0, 8548, -21636), (2, 1, -1, 0, -7888, 24208), (2, 1, 0, 0, -6766, 30824),
        (1, 0, -1, 0, -5163, -8379), (1, 1, 0, 0, 4987, -16675), (2, -1, 1, 0, 4036, -12831),
        (2, 0, 2, 0, 3994, -10445), (4, 0, 0, 0, 3861, -11650), (2, 0, -3, 0, 3665, 14403),
        (0, 1, -2, 0, -2689, -7003), (2, 0, -1, 2, -2602, 0), (2, -1, -2, 0, 2390, 10056),
        (1, 0, 1, 0, -2348, 6322), (2, -2, 0, 0, 2236, -9884),
    ]
    private static let lunarB: [(d: Double, m: Double, mp: Double, f: Double, b: Double)] = [
        (0, 0, 0, 1, 5128122), (0, 0, 1, 1, 280602), (0, 0, 1, -1, 277693), (2, 0, 0, -1, 173237),
        (2, 0, -1, 1, 55413), (2, 0, -1, -1, 46271), (2, 0, 0, 1, 32573), (0, 0, 2, 1, 17198),
        (2, 0, 1, -1, 9266), (0, 0, 2, -1, 8822), (2, -1, 0, -1, 8216), (2, 0, -2, -1, 4324),
        (2, 0, 1, 1, 4200), (2, 1, 0, -1, -3359), (2, -1, -1, 1, 2463), (2, -1, 0, 1, 2211), (2, -1, -1, -1, 2065),
    ]

    /// The fraction of the Moon's disk that is lit, 0 new to 1 full.
    static func moonPhase(_ date: Date) -> Double {
        0.5 * (1 - simd_dot(sun(date), simd_normalize(moon(date))))
    }

    /// The unit vector at a latitude and longitude, degrees.
    static func point(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let la = latitude * deg, lo = longitude * deg
        return SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
    }

    /// Rows of the rotation taking an Earth-fixed direction to the star catalog's frame (the
    /// equator and equinox of J2000): turn the sky by sidereal time, then undo the precession
    /// since 2000, which slides the equinox about 50 arcseconds a year along the ecliptic
    /// (about a third of a degree by now, a few pixels).
    static func earthFixedToJ2000(_ date: Date) -> [SIMD3<Double>] {
        let n = days(date)
        let th = gmst(n), eps = obliquity(n)
        let p = 50.29 / 3600 * deg * n / 365.25
        func rx(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))])
        }
        func rz(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(cos(a), -sin(a), 0), SIMD3(sin(a), cos(a), 0), SIMD3(0, 0, 1)])
        }
        // Earth-fixed to equator of date, to ecliptic of date, back along the ecliptic by the
        // precession, and to the J2000 equator
        let m = rx(eps) * rz(-p) * rx(-eps) * rz(th)
        return [SIMD3(m[0, 0], m[1, 0], m[2, 0]), SIMD3(m[0, 1], m[1, 1], m[2, 1]), SIMD3(m[0, 2], m[1, 2], m[2, 2])]
    }

    /// Ecliptic longitude and latitude to equatorial (celestial) coordinates; the obliquity
    /// is applied in toEarthFixed.
    private static func ecliptic(_ lambda: Double, _ beta: Double) -> SIMD3<Double> {
        SIMD3(cos(beta) * cos(lambda), cos(beta) * sin(lambda), sin(beta))
    }

    private static func toEarthFixed(_ e: SIMD3<Double>, _ n: Double) -> SIMD3<Double> {
        let eps = obliquity(n)
        let eq = SIMD3(e.x, cos(eps) * e.y - sin(eps) * e.z, sin(eps) * e.y + cos(eps) * e.z)
        let th = gmst(n)
        // turn the sky back by the sidereal angle: Earth-fixed longitude = right ascension - GMST
        return SIMD3(cos(th) * eq.x + sin(th) * eq.y, -sin(th) * eq.x + cos(th) * eq.y, eq.z)
    }
}
