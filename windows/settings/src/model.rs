//! The parts of the macOS settings model the Customize window needs that the library doesn't
//! carry: option titles, scene blurbs, per-scene reset (Config/SceneCustomization.swift), color
//! presets (Config/ColorPresets.swift), the black hole merger detections and the eclipse air
//! presets (Config/Options.swift).

use deepfield::config::*;
use deepfield::palette::{rgb, Rgb};
use serde_json::{Map, Value};

// MARK: titles

pub fn star_title(s: StarType) -> &'static str {
    match s {
        StarType::RedDwarf => "Red dwarf",
        StarType::OrangeDwarf => "Orange dwarf",
        StarType::Yellow => "Yellow (Sun-like)",
        StarType::White => "White star",
        StarType::BlueGiant => "Blue giant",
        StarType::RedGiant => "Red giant",
        StarType::WhiteDwarf => "White dwarf",
        StarType::NeutronStar => "Neutron star",
    }
}

pub fn frequency_title(f: Frequency) -> &'static str {
    match f {
        Frequency::Off => "Off",
        Frequency::Rare => "Rare",
        Frequency::Normal => "Normal",
        Frequency::Often => "Often",
    }
}

pub fn galaxy_type_title(g: GalaxyType) -> &'static str {
    match g {
        GalaxyType::Spiral => "Spiral",
        GalaxyType::Barred => "Barred spiral",
        GalaxyType::Elliptical => "Elliptical",
        GalaxyType::Irregular => "Irregular",
        GalaxyType::Ring => "Ring",
    }
}

pub fn ring_style_title(r: RingStyle) -> &'static str {
    match r {
        RingStyle::Classic => "Classic",
        RingStyle::Broad => "Broad",
        RingStyle::Narrow => "Narrow ringlets",
        RingStyle::NoRings => "None",
    }
}

pub fn proto_look_title(l: ProtoDiskLook) -> &'static str {
    match l {
        ProtoDiskLook::Scattered => "Scattered light",
        ProtoDiskLook::Blend => "Both",
        ProtoDiskLook::Alma => "ALMA glow",
    }
}

pub fn eclipse_motion_title(m: EclipseMotion) -> &'static str {
    match m {
        EclipseMotion::Cycle => "Full cycle",
        EclipseMotion::Hold => "Hold at totality",
    }
}

pub fn eclipse_world_title(w: EclipseWorld) -> &'static str {
    match w {
        EclipseWorld::Rock => "Gray rock",
        EclipseWorld::Ice => "Ice",
        EclipseWorld::Desert => "Rust desert",
        EclipseWorld::Basalt => "Volcanic basalt",
    }
}

pub fn eclipse_body_title(b: EclipseSkyBody) -> &'static str {
    match b {
        EclipseSkyBody::TealGiant => "Teal gas giant",
        EclipseSkyBody::BandedGiant => "Banded gas giant",
        EclipseSkyBody::RingedGiant => "Ringed giant",
        EclipseSkyBody::IceGiant => "Ice giant",
        EclipseSkyBody::RockyMoon => "Cratered moon",
        EclipseSkyBody::NoBody => "None",
    }
}

pub fn bbh_model_title(m: BlackHoleMergerModel) -> &'static str {
    match m {
        BlackHoleMergerModel::Stellar => "Stellar",
        BlackHoleMergerModel::AgnDisk => "Stellar, in a quasar's disk",
        BlackHoleMergerModel::Intermediate => "Intermediate, in a cluster",
        BlackHoleMergerModel::Supermassive => "Supermassive, with a gas disk",
    }
}

pub fn tde_colors_title(t: TdeDiskColors) -> &'static str {
    match t {
        TdeDiskColors::Palette => "Custom",
        TdeDiskColors::Fiery => "Fiery",
        TdeDiskColors::BlueWhite => "Blue-white",
    }
}

pub fn pulsar_beams_title(b: PulsarBeams) -> &'static str {
    match b {
        PulsarBeams::Both => "Both poles",
        PulsarBeams::Top => "Top only",
        PulsarBeams::Bottom => "Bottom only",
        PulsarBeams::NoBeams => "None",
    }
}

pub fn pulsar_field_title(s: PulsarFieldStyle) -> &'static str {
    match s {
        PulsarFieldStyle::Lines => "Field lines",
        PulsarFieldStyle::Magnetar => "Magnetar lobes",
    }
}

/// One line under the scene's name (SceneInfo.swift).
pub fn blurb(s: SceneKind) -> &'static str {
    use SceneKind::*;
    match s {
        BlackHole => "A lensed accretion disk and photon ring. Planets bend as they pass behind.",
        TidalDisruption => "A star stretched by tides feeds a stream of gas into the disk.",
        Wormhole => "A wormhole showing another sky through its throat, with ours bent around the rim.",
        Binary => "Two stars in orbit, with eclipses and planets lit by both.",
        Trinary => "A close pair of stars and a distant third.",
        Galaxy => "A rotating galaxy with density-wave arms and a dark matter halo.",
        Pulsar => "A spinning neutron star with lighthouse beams and a wind nebula.",
        Nebula => "Glowing gas and dark dust.",
        GasGiant => "A giant planet close up, its bands flowing and its storms spinning.",
        ProtoplanetaryDisk => "A young star in its dusty disk, ringed with gaps that forming planets have cleared, and jets from its poles.",
        NeutronMerger => "Two neutron stars spiral together, rippling the sky with gravitational waves, and merge in a kilonova.",
        BlackHoleMerger => "Two black holes spiral together, bending the starlight behind them, and merge into one that rings like a bell.",
        DysonSwarm => "A star wrapped in rings of orbiting solar panels, its light leaking out between them.",
        RoguePlanet => "A planet adrift between the stars with no sun, seen by the starlight it blocks, its aurorae glowing.",
        Eclipse => "A total eclipse of the sun over the horizon of another world, its corona and prominences coming out as the light fades.",
        AuroraOrbit => "Aurora curtains over the night side of Earth, seen from orbit, with the real city lights of Europe, Asia and North America turning by below.",
        LiveEarth => "Earth right now, from far above a place you choose: real sunlight and seasons, city lights at night, the Moon in its true phase, and live clouds and aurora forecasts.",
        RingedPlanet => "A banded gas giant and its rings, each shadowing the other, with small moons in orbit.",
        PlanetaryNebula => "A dying star's shed shell, lit from inside by the white dwarf left behind.",
        Comet => "A coma with jets, a blue ion tail and a curved dust tail.",
        StellarSurface => "The limb of a star: granulation, spots, loops and eruptions.",
        Quasar => "An active galaxy whose central black hole fires two jets far out into space.",
    }
}

// MARK: per-scene reset

/// Saved keys that belong to a scene's own settings (`ownKeys` in SceneCustomization.swift): a
/// prefix matches keys that continue with a capital letter, so "pulsar" doesn't take the sky's
/// "pulsars". Camera tilt and the planets are shared, so resetting one scene resets them for all.
fn own_keys(kind: SceneKind) -> (Vec<&'static str>, Vec<&'static str>, Vec<&'static str>) {
    use SceneKind::*;
    let planets = ["planetCount", "planetSize", "planetOrbitMinutes", "planetSeed", "planetRings"];
    let disk = vec!["receding", "approaching", "core", "ring"];
    let with = |mut a: Vec<&'static str>, b: &[&'static str]| {
        a.extend_from_slice(b);
        a
    };
    match kind {
        BlackHole => (vec![], with(vec!["diskSize", "diskSpeed", "photonRing", "tilt"], &planets), disk),
        Wormhole => (vec![], with(vec!["throat", "photonRing", "wormholeEvents", "tilt"], &planets), vec!["ring", "farA", "farB"]),
        Binary => (vec![], with(vec!["binaryStars", "starSeparation", "starOrbitMinutes", "tilt"], &planets), vec![]),
        Trinary => (vec![], with(vec!["trinaryStars", "starSeparation", "starOrbitMinutes", "tilt"], &planets), vec![]),
        Galaxy => (
            vec![],
            vec!["galaxyType", "galaxyArms", "galaxyPitch", "galaxyView", "galaxyRotationMinutes", "darkMatter", "galaxySize"],
            vec!["galaxyCore", "galaxyArms", "galaxyNebula", "galaxyDust"],
        ),
        TidalDisruption => (vec!["tde"], vec!["diskSpeed"], disk),
        Pulsar => (vec!["pulsar"], vec!["tilt"], vec![]),
        Nebula => (vec!["nebula"], vec!["tilt"], vec![]),
        PlanetaryNebula => (vec!["planetary"], vec!["tilt"], vec![]),
        RingedPlanet => (vec!["ringed"], vec!["tilt"], vec![]),
        AuroraOrbit => (vec!["aurora"], vec!["tilt"], vec![]),
        LiveEarth => (vec!["earth"], vec![], vec![]),
        GasGiant => (vec!["gas"], vec!["tilt"], vec![]),
        ProtoplanetaryDisk => (vec!["proto"], vec!["tilt"], vec![]),
        NeutronMerger => (vec!["merger"], vec!["tilt"], vec![]),
        BlackHoleMerger => (vec!["bbh"], vec!["tilt"], vec![]),
        DysonSwarm => (vec!["dyson"], vec!["tilt"], vec![]),
        RoguePlanet => (vec!["rogue"], vec!["tilt"], vec![]),
        Eclipse => (vec!["eclipse"], vec!["tilt"], vec![]),
        Quasar => (vec!["quasar"], vec![], vec![]),
        Comet => (vec!["comet"], vec!["tilt"], vec![]),
        StellarSurface => (
            vec![],
            vec!["closeStar", "starSpots", "starFlares", "starRotation", "starZoom", "starCenterX", "starLimbY", "tilt"],
            vec![],
        ),
    }
}

fn owns(kind: SceneKind, key: &str) -> bool {
    let (prefixes, keys, _) = own_keys(kind);
    keys.contains(&key)
        || prefixes.iter().any(|p| key.strip_prefix(p).and_then(|rest| rest.chars().next()).is_some_and(|c| c.is_uppercase()))
}

fn json(c: &WallpaperConfig) -> Map<String, Value> {
    match serde_json::to_value(c) {
        Ok(Value::Object(m)) => m,
        _ => Map::new(),
    }
}

/// `c` with `kind`'s own settings put back to their defaults; the sky, image, system settings
/// and the other scenes stay as they are.
pub fn resetting_scene(c: &WallpaperConfig, kind: SceneKind) -> WallpaperConfig {
    let mut dict = json(c);
    let defaults = json(&WallpaperConfig::default());
    for (k, v) in &defaults {
        // `tilt` is the active scene's; another scene's is parked
        if owns(kind, k) && (k != "tilt" || kind == c.scene) {
            dict.insert(k.clone(), v.clone());
        }
    }
    let (_, _, palette_keys) = own_keys(kind);
    if !palette_keys.is_empty() {
        if let (Some(Value::Object(p)), Some(Value::Object(dp))) = (dict.get("palette").cloned(), defaults.get("palette")) {
            let mut p = p;
            for k in palette_keys {
                if let Some(v) = dp.get(k) {
                    p.insert(k.to_string(), v.clone());
                }
            }
            dict.insert("palette".into(), Value::Object(p));
        }
    }
    let Ok(mut out) = serde_json::from_value::<WallpaperConfig>(Value::Object(dict)) else { return c.clone() };
    if kind.has_tilt() && kind != c.scene {
        out.scene_tilt.insert(kind.raw().to_string(), deepfield::config::DEFAULT_TILT);
        out.normalize_tilts();
    }
    out
}

pub fn is_customized(c: &WallpaperConfig, kind: SceneKind) -> bool {
    resetting_scene(c, kind) != *c
}

// MARK: color presets (in the library, for the command line too)

pub use deepfield::color_presets::*;

// MARK: eclipse air and black hole merger detections

pub struct AirPreset {
    pub name: &'static str,
    pub color: Rgb,
    pub density: f64,
    pub haze: f64,
    pub clouds: f64,
}

pub const AIR_PRESETS: [AirPreset; 4] = [
    AirPreset { name: "Earth-like", color: rgb(0.36, 0.6, 1.0), density: 1.0, haze: 0.15, clouds: 0.5 },
    AirPreset { name: "Mars-like", color: rgb(0.88, 0.64, 0.42), density: 0.35, haze: 0.8, clouds: 0.1 },
    AirPreset { name: "Titan-like", color: rgb(1.0, 0.58, 0.18), density: 2.2, haze: 1.4, clouds: 0.25 },
    AirPreset { name: "Sulfur", color: rgb(1.0, 0.93, 0.55), density: 1.3, haze: 0.6, clouds: 0.6 },
];

impl AirPreset {
    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        c.eclipse_air_color == self.color && c.eclipse_air_density == self.density
            && c.eclipse_air_haze == self.haze && c.eclipse_clouds == self.clouds
    }
    pub fn apply(&self, c: &mut WallpaperConfig) {
        c.eclipse_air_color = self.color;
        c.eclipse_air_density = self.density;
        c.eclipse_air_haze = self.haze;
        c.eclipse_clouds = self.clouds;
    }
}

pub struct Detection {
    pub name: &'static str,
    pub m1: f64,
    pub m2: f64,
    pub remnant: f64,
    pub spin: f64,
    pub precession: f64,
    pub view: f64,
    pub model: BlackHoleMergerModel,
    pub eccentric: bool,
    pub note: &'static str,
}

pub const DETECTIONS: [Detection; 7] = {
    use BlackHoleMergerModel::*;
    [
        Detection { name: "GW150914", m1: 36.0, m2: 31.0, remnant: 63.0, spin: 0.69, precession: 0.15, view: 30.0, model: Stellar, eccentric: false,
                    note: "The first gravitational waves ever detected, on 14 September 2015." },
        Detection { name: "GW170814", m1: 31.0, m2: 25.0, remnant: 53.0, spin: 0.72, precession: 0.2, view: 50.0, model: Stellar, eccentric: false,
                    note: "The first heard by three detectors, which pinned down the waves' polarization." },
        Detection { name: "GW190412", m1: 30.0, m2: 8.0, remnant: 37.0, spin: 0.67, precession: 0.3, view: 45.0, model: Stellar, eccentric: false,
                    note: "The first clearly unequal pair. Its waves carry a higher harmonic, a third arm in the ripples." },
        Detection { name: "GW190521", m1: 85.0, m2: 66.0, remnant: 142.0, spin: 0.72, precession: 0.7, view: 50.0, model: AgnDisk, eccentric: true,
                    note: "The first intermediate-mass black hole, from holes too heavy for single stars. It may have merged on an eccentric orbit inside a quasar's disk, where a flare was seen a month later." },
        Detection { name: "GW190814", m1: 23.0, m2: 2.6, remnant: 26.0, spin: 0.28, precession: 0.05, view: 45.0, model: Stellar, eccentric: false,
                    note: "A 9 to 1 pair. The light partner is the lightest black hole or the heaviest neutron star known." },
        Detection { name: "GW231123", m1: 137.0, m2: 103.0, remnant: 225.0, spin: 0.85, precession: 0.8, view: 40.0, model: Intermediate, eccentric: false,
                    note: "The most massive merger yet, of two black holes spinning close to the limit." },
        Detection { name: "GW250114", m1: 34.0, m2: 32.0, remnant: 63.0, spin: 0.68, precession: 0.1, view: 30.0, model: Stellar, eccentric: false,
                    note: "The clearest signal yet. Its ringdown confirmed Hawking's area theorem." },
    ]
};

impl Detection {
    pub fn ratio(&self) -> f64 {
        ((self.m2 / self.m1) * 100.0).round() / 100.0
    }
    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        c.bbh_mass_ratio == self.ratio() && c.bbh_spin == self.spin && c.bbh_precession == self.precession
            && c.bbh_view == self.view && c.bbh_model == self.model && c.bbh_eccentric == self.eccentric
    }
    pub fn apply(&self, c: &mut WallpaperConfig) {
        c.bbh_mass_ratio = self.ratio();
        c.bbh_spin = self.spin;
        c.bbh_precession = self.precession;
        c.bbh_view = self.view;
        c.bbh_model = self.model;
        c.bbh_eccentric = self.eccentric;
    }
}

/// A short note under the scene's own controls, where one helps.
pub fn scene_note(c: &WallpaperConfig) -> Option<String> {
    use SceneKind::*;
    let mass = |m: f64| if m < 10.0 { format!("{m:.1}") } else { format!("{m:.0}") };
    match c.scene {
        Binary | Trinary | StellarSurface | DysonSwarm => Some("Star colors follow the star type.".into()),
        Pulsar => Some("Slowed down from hundreds of turns a second so the beams don't strobe.".into()),
        BlackHoleMerger => Some(match DETECTIONS.iter().find(|d| d.matches(c)) {
            Some(d) => format!("{}: {} and {} solar masses made one of {}. {}", d.name, mass(d.m1), mass(d.m2), mass(d.remnant), d.note),
            None => "Real mergers take seconds (stellar) to years (supermassive); every size is paced to the cycle here.".into(),
        }),
        Galaxy => Some(if c.dark_matter {
            "Outer stars orbit as fast as inner ones, as observed in real galaxies.".into()
        } else {
            "Without dark matter the outer disk lags behind. Real galaxies don't do this.".into()
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_covers_scene_keys_only() {
        let mut c = WallpaperConfig::default();
        c.gas_wind = 3.0;
        c.star_density = 2.0;
        c.pulsars = false;
        assert!(is_customized(&c, SceneKind::GasGiant));
        assert!(!is_customized(&c, SceneKind::Pulsar));
        let r = resetting_scene(&c, SceneKind::GasGiant);
        assert_eq!(r.gas_wind, 1.0);
        assert_eq!(r.star_density, 2.0);
    }

    #[test]
    fn reset_puts_back_each_scenes_own_tilt() {
        // the slider and the reset agree about which scenes have a tilt
        for &k in SceneKind::ALL {
            assert_eq!(k.has_tilt(), owns(k, "tilt"), "{k:?}");
        }
        let mut c = WallpaperConfig::default();
        c.set_scene(SceneKind::Comet);
        c.tilt = 20.0;
        c.set_scene(SceneKind::BlackHole);
        c.tilt = 12.0;
        // another scene's parked tilt counts as its customization, and resets alone
        assert!(is_customized(&c, SceneKind::Comet));
        let r = resetting_scene(&c, SceneKind::Comet);
        assert_eq!((r.tilt, r.scene_tilt.get("comet")), (12.0, None));
        // the active scene's
        let r = resetting_scene(&c, SceneKind::BlackHole);
        assert_eq!((r.tilt, r.scene_tilt.get("comet")), (DEFAULT_TILT, Some(&20.0)));
    }
}
