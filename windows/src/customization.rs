//! Which saved settings belong to which scene (Config/SceneCustomization.swift): the per-scene
//! reset, and the settings a look depends on, for telling two looks apart.

use serde_json::{Map, Value};

use crate::config::*;

/// Saved keys that belong to a scene's own settings (`ownKeys` in SceneCustomization.swift): a
/// prefix matches keys that continue with a capital letter, so "pulsar" doesn't take the sky's
/// "pulsars". A few belong to two scenes (see `SceneKind::shared_note`) and reset for both; `tilt`
/// is each scene's own.
pub fn own_keys(kind: SceneKind) -> (Vec<&'static str>, Vec<&'static str>, Vec<&'static str>) {
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

pub fn owns(kind: SceneKind, key: &str) -> bool {
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
        out.scene_tilt.insert(kind.raw().to_string(), DEFAULT_TILT);
        out.normalize_tilts();
    }
    out
}

pub fn is_customized(c: &WallpaperConfig, kind: SceneKind) -> bool {
    resetting_scene(c, kind) != *c
}

/// The Sky section's settings, which a scene that draws the real sky doesn't show.
const SKY_KEYS: [&str; 11] = ["starDensity", "nebula", "galaxies", "milkyWay", "skySeed", "twinkles", "twinkleBrightness",
                              "twinkleSpeed", "pulsars", "supernovae", "comets"];
const SKY_PALETTE: [&str; 5] = ["nebulaA", "nebulaB", "galaxy", "starWarm", "starCool"];

/// Saved keys a scene draws with that its reset leaves alone.
fn also_draws(kind: SceneKind) -> &'static [&'static str] {
    match kind {
        SceneKind::TidalDisruption => &["photonRing"],
        SceneKind::LiveEarth => &["homeLatitude", "homeLongitude"],
        _ => &[],
    }
}

/// The saved settings the active scene's look depends on, for comparing two looks. It leaves out
/// what can differ without the look being changed: the computer's own settings, Live Earth's
/// place (which can follow the device) and other scenes' settings. Going through the saved format
/// first gives a live config and a saved one the same clamping and color migration.
pub fn visible_settings(c: &WallpaperConfig) -> Value {
    let saved = serde_json::to_string(c).ok().and_then(|t| WallpaperConfig::decode(&t)).unwrap_or_else(|| c.clone());
    let scene = saved.scene;
    let mut dict = json(&saved);
    for key in ["fps", "lockScreenStill", "lockScreenSmooth", "homeLatitude", "homeLongitude", "homeFromDevice",
                "sceneImage", "sharedImage", "sceneTilt", "sharedTilt", "phoneFraming"] {
        dict.remove(key);
    }
    let others: Vec<SceneKind> = SceneKind::ALL.iter().copied().filter(|&k| k != scene).collect();
    let draws = also_draws(scene);
    let keys: Vec<String> = dict.keys().cloned().collect();
    for key in keys {
        if !owns(scene, &key) && !draws.contains(&key.as_str()) && others.iter().any(|&k| owns(k, &key)) {
            dict.remove(&key);
        }
    }
    if scene.draws_real_sky() {
        for key in SKY_KEYS {
            dict.remove(key);
        }
    }
    if let Some(Value::Object(palette)) = dict.get_mut("palette") {
        let own = own_keys(scene).2;
        for key in others.iter().flat_map(|&k| own_keys(k).2) {
            if !own.contains(&key) {
                palette.remove(key);
            }
        }
        if scene.draws_real_sky() {
            for key in SKY_PALETTE {
                palette.remove(key);
            }
        }
    }
    Value::Object(dict)
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
