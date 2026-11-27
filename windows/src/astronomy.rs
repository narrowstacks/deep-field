//! Where the sun and Moon are for the Live Earth scene, in Earth-fixed coordinates (x toward
//! 0 N 0 E, y toward 0 N 90 E, z the north pole; lengths in Earth radii), after
//! Scenes/Astronomy.swift. The sun to about 0.01 degrees (the almanac's low-precision formula)
//! and the Moon to about 10 arcseconds, close enough that eclipses happen when and where they
//! really do. Dates are Unix seconds (Swift's timeIntervalSince1970).

use glam::{DMat3, DVec3};

const DEG: f64 = std::f64::consts::PI / 180.0;

/// Days since J2000.0 (2000 January 1, 12:00 TT, taken as UT).
pub fn days(date: f64) -> f64 {
    date / 86400.0 - 10957.5
}

/// Greenwich mean sidereal time, radians: how far Earth has turned under the stars. Rust's `%`
/// keeps the dividend's sign, like Swift's truncatingRemainder.
pub fn gmst(n: f64) -> f64 {
    ((280.46061837 + 360.98564736629 * n) % 360.0) * DEG
}

pub fn obliquity(n: f64) -> f64 {
    (23.439 - 0.0000004 * n) * DEG
}

/// Unit vector toward the sun.
pub fn sun(date: f64) -> DVec3 {
    let n = days(date);
    let l = (280.460 + 0.9856474 * n) * DEG;
    let g = (357.528 + 0.9856003 * n) * DEG;
    let lambda = l + (1.915 * g.sin() + 0.020 * (2.0 * g).sin()) * DEG;
    to_earth_fixed(ecliptic(lambda, 0.0), n)
}

/// Meeus' tables 47.A and 47.B, terms down to about 7 arcseconds: multiples of the mean
/// elongation D, the sun's anomaly M, the Moon's anomaly M' and its argument of latitude F;
/// longitude and latitude in millionths of a degree, distance in meters.
const LUNAR_LR: [(f64, f64, f64, f64, f64, f64); 32] = [
    (0.0, 0.0, 1.0, 0.0, 6288774.0, -20905355.0), (2.0, 0.0, -1.0, 0.0, 1274027.0, -3699111.0), (2.0, 0.0, 0.0, 0.0, 658314.0, -2955968.0),
    (0.0, 0.0, 2.0, 0.0, 213618.0, -569925.0), (0.0, 1.0, 0.0, 0.0, -185116.0, 48888.0), (0.0, 0.0, 0.0, 2.0, -114332.0, -3149.0),
    (2.0, 0.0, -2.0, 0.0, 58793.0, 246158.0), (2.0, -1.0, -1.0, 0.0, 57066.0, -152138.0), (2.0, 0.0, 1.0, 0.0, 53322.0, -170733.0),
    (2.0, -1.0, 0.0, 0.0, 45758.0, -204586.0), (0.0, 1.0, -1.0, 0.0, -40923.0, -129620.0), (1.0, 0.0, 0.0, 0.0, -34720.0, 108743.0),
    (0.0, 1.0, 1.0, 0.0, -30383.0, 104755.0), (2.0, 0.0, 0.0, -2.0, 15327.0, 10321.0), (0.0, 0.0, 1.0, 2.0, -12528.0, 0.0),
    (0.0, 0.0, 1.0, -2.0, 10980.0, 79661.0), (4.0, 0.0, -1.0, 0.0, 10675.0, -34782.0), (0.0, 0.0, 3.0, 0.0, 10034.0, -23210.0),
    (4.0, 0.0, -2.0, 0.0, 8548.0, -21636.0), (2.0, 1.0, -1.0, 0.0, -7888.0, 24208.0), (2.0, 1.0, 0.0, 0.0, -6766.0, 30824.0),
    (1.0, 0.0, -1.0, 0.0, -5163.0, -8379.0), (1.0, 1.0, 0.0, 0.0, 4987.0, -16675.0), (2.0, -1.0, 1.0, 0.0, 4036.0, -12831.0),
    (2.0, 0.0, 2.0, 0.0, 3994.0, -10445.0), (4.0, 0.0, 0.0, 0.0, 3861.0, -11650.0), (2.0, 0.0, -3.0, 0.0, 3665.0, 14403.0),
    (0.0, 1.0, -2.0, 0.0, -2689.0, -7003.0), (2.0, 0.0, -1.0, 2.0, -2602.0, 0.0), (2.0, -1.0, -2.0, 0.0, 2390.0, 10056.0),
    (1.0, 0.0, 1.0, 0.0, -2348.0, 6322.0), (2.0, -2.0, 0.0, 0.0, 2236.0, -9884.0),
];
const LUNAR_B: [(f64, f64, f64, f64, f64); 17] = [
    (0.0, 0.0, 0.0, 1.0, 5128122.0), (0.0, 0.0, 1.0, 1.0, 280602.0), (0.0, 0.0, 1.0, -1.0, 277693.0), (2.0, 0.0, 0.0, -1.0, 173237.0),
    (2.0, 0.0, -1.0, 1.0, 55413.0), (2.0, 0.0, -1.0, -1.0, 46271.0), (2.0, 0.0, 0.0, 1.0, 32573.0), (0.0, 0.0, 2.0, 1.0, 17198.0),
    (2.0, 0.0, 1.0, -1.0, 9266.0), (0.0, 0.0, 2.0, -1.0, 8822.0), (2.0, -1.0, 0.0, -1.0, 8216.0), (2.0, 0.0, -2.0, -1.0, 4324.0),
    (2.0, 0.0, 1.0, 1.0, 4200.0), (2.0, 1.0, 0.0, -1.0, -3359.0), (2.0, -1.0, -1.0, 1.0, 2463.0), (2.0, -1.0, 0.0, 1.0, 2211.0),
    (2.0, -1.0, -1.0, -1.0, 2065.0),
];

/// The Moon's center, Earth radii: the largest terms of Meeus' lunar theory (Astronomical
/// Algorithms, chapter 47), good to about 10 arcseconds, which puts an eclipse's shadow within
/// a few tens of kilometers of where it really falls.
pub fn moon(date: f64) -> DVec3 {
    // the Moon's theory runs on Terrestrial Time, about 69 s ahead of the clock
    let t = (days(date) + 69.0 / 86400.0) / 36525.0;
    let lp = 218.3164477 + 481267.88123421 * t;
    let d = 297.8501921 + 445267.1114034 * t;
    let m = 357.5291092 + 35999.0502909 * t;
    let mp = 134.9633964 + 477198.8675055 * t;
    let f = 93.2720950 + 483202.0175233 * t;
    let e = 1.0 - 0.002516 * t;
    let a1 = 119.75 + 131.849 * t;
    let a2 = 53.09 + 479264.290 * t;
    let a3 = 313.45 + 481266.484 * t;
    let (mut sl, mut sr, mut sb) = (0.0, 0.0, 0.0);
    for &(td, tm, tmp, tf, tl, tr) in LUNAR_LR.iter() {
        let a = (td * d + tm * m + tmp * mp + tf * f) * DEG;
        let ef = e.powf(tm.abs());
        sl += tl * ef * a.sin();
        sr += tr * ef * a.cos();
    }
    for &(td, tm, tmp, tf, tb) in LUNAR_B.iter() {
        sb += tb * e.powf(tm.abs()) * ((td * d + tm * m + tmp * mp + tf * f) * DEG).sin();
    }
    sl += 3958.0 * (a1 * DEG).sin() + 1962.0 * ((lp - f) * DEG).sin() + 318.0 * (a2 * DEG).sin();
    sb += -2235.0 * (lp * DEG).sin() + 382.0 * (a3 * DEG).sin() + 175.0 * ((a1 - f) * DEG).sin() + 175.0 * ((a1 + f) * DEG).sin()
        + 127.0 * ((lp - mp) * DEG).sin() - 115.0 * ((lp + mp) * DEG).sin();
    let lambda = (lp + sl / 1e6) * DEG;
    let beta = sb / 1e6 * DEG;
    let distance = (385000.56 + sr / 1000.0) / 6371.0;
    to_earth_fixed(ecliptic(lambda, beta), days(date)) * distance
}

/// The fraction of the Moon's disk that is lit, 0 new to 1 full.
pub fn moon_phase(date: f64) -> f64 {
    0.5 * (1.0 - sun(date).dot(crate::math::normalize(moon(date))))
}

/// The unit vector at a latitude and longitude, degrees.
pub fn point(latitude: f64, longitude: f64) -> DVec3 {
    let (la, lo) = (latitude * DEG, longitude * DEG);
    DVec3::new(la.cos() * lo.cos(), la.cos() * lo.sin(), la.sin())
}

/// Rows of the rotation taking an Earth-fixed direction to the star catalog's frame (the
/// equator and equinox of J2000): turn the sky by sidereal time, then undo the precession
/// since 2000, which slides the equinox about 50 arcseconds a year along the ecliptic
/// (about a third of a degree by now, a few pixels).
pub fn earth_fixed_to_j2000(date: f64) -> [DVec3; 3] {
    let n = days(date);
    let th = gmst(n);
    let eps = obliquity(n);
    let p = 50.29 / 3600.0 * DEG * n / 365.25;
    // matrices given by rows, like simd_double3x3(rows:)
    let rx = |a: f64| DMat3::from_cols_array(&[1.0, 0.0, 0.0, 0.0, a.cos(), a.sin(), 0.0, -a.sin(), a.cos()]);
    let rz = |a: f64| DMat3::from_cols_array(&[a.cos(), a.sin(), 0.0, -a.sin(), a.cos(), 0.0, 0.0, 0.0, 1.0]);
    // Earth-fixed to equator of date, to ecliptic of date, back along the ecliptic by the
    // precession, and to the J2000 equator
    let m = rx(eps) * rz(-p) * rx(-eps) * rz(th);
    // Swift's m[i, j] is column i, row j, so these are the matrix's rows
    [m.row(0), m.row(1), m.row(2)]
}

/// Ecliptic longitude and latitude to equatorial (celestial) coordinates; the obliquity
/// is applied in to_earth_fixed.
fn ecliptic(lambda: f64, beta: f64) -> DVec3 {
    DVec3::new(beta.cos() * lambda.cos(), beta.cos() * lambda.sin(), beta.sin())
}

fn to_earth_fixed(e: DVec3, n: f64) -> DVec3 {
    let eps = obliquity(n);
    let eq = DVec3::new(e.x, eps.cos() * e.y - eps.sin() * e.z, eps.sin() * e.y + eps.cos() * e.z);
    let th = gmst(n);
    // turn the sky back by the sidereal angle: Earth-fixed longitude = right ascension - GMST
    DVec3::new(th.cos() * eq.x + th.sin() * eq.y, -th.sin() * eq.x + th.cos() * eq.y, eq.z)
}

/// The UTC calendar date of a Unix time: (year, month 1..12, day 1..31, hour, minute, second),
/// by Howard Hinnant's days-to-civil algorithm.
pub fn civil(t: f64) -> (i64, u32, u32, u32, u32, u32) {
    let secs = t.floor() as i64;
    let z0 = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let z = z0 + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d, (rem / 3600) as u32, (rem / 60 % 60) as u32, (rem % 60) as u32)
}

/// Days from 1970-01-01 to a civil date.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// The day of the year in UTC, 1 on January 1 (Calendar.ordinality(of: .day, in: .year)).
pub fn day_of_year(t: f64) -> f64 {
    let (y, m, d, ..) = civil(t);
    (days_from_civil(y, m, d) - days_from_civil(y, 1, 1) + 1) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendar() {
        assert_eq!(civil(0.0), (1970, 1, 1, 0, 0, 0));
        // 2026-11-16 18:30:00 UTC, the gallery's frozen Live Earth moment
        assert_eq!(civil(1794853800.0), (2026, 11, 16, 18, 30, 0));
        assert_eq!(day_of_year(1794853800.0), 320.0);
        assert_eq!(day_of_year(1_704_067_200.0 + 59.0 * 86400.0), 60.0); // 2024-02-29
    }

    #[test]
    fn sun_at_june_solstice_is_over_the_tropic() {
        // 2024-06-20 20:51 UTC
        let s = sun(1_718_916_660.0);
        let lat = s.z.asin() / DEG;
        assert!((lat - 23.44).abs() < 0.05, "{lat}");
    }

    #[test]
    fn total_eclipse_2024() {
        // 2024-04-08 18:17 UTC, greatest eclipse near 25.3 N 104.1 W: the Moon is in front of the sun
        let t = 1_712_600_220.0;
        let p = point(25.3, -104.1);
        let to_sun = sun(t);
        let to_moon = crate::math::normalize(moon(t) - p);
        let sep = to_sun.cross(to_moon).length().asin() / DEG;
        assert!(sep < 0.1, "{sep}");
    }

    #[test]
    fn j2000_turn_is_a_rotation() {
        let r = earth_fixed_to_j2000(1_794_853_800.0);
        for i in 0..3 {
            assert!((r[i].length() - 1.0).abs() < 1e-12);
        }
        assert!(r[0].dot(r[1]).abs() < 1e-12);
    }
}
