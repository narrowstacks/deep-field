//! Each scene's named color looks (Config/ColorPresets.swift), shared by the Customize window's
//! Colors section and `--preset` on the command line.

use crate::config::*;
use crate::palette::{rgb, PaletteConfig, Rgb};

pub type ColorField = fn(&mut WallpaperConfig) -> &mut Rgb;

/// A named color look for one scene: a value for each of its own colors (as picks).
pub struct ColorPreset {
    pub name: &'static str,
    pub colors: Vec<(ColorField, Rgb)>,
    pub look: Option<ProtoDiskLook>,
}

impl ColorPreset {
    pub fn swatches(&self) -> Vec<Rgb> {
        self.colors.iter().take(4).map(|(_, c)| *c).collect()
    }
    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        let mut c = c.clone();
        self.colors.iter().all(|(f, v)| *f(&mut c) == *v)
    }
    pub fn apply(&self, c: &mut WallpaperConfig) {
        for (f, v) in &self.colors {
            *f(c) = *v;
        }
        if let Some(l) = self.look {
            c.proto_look = l;
        }
    }
}

fn list(fields: &[ColorField], entries: &[(&'static str, &[Rgb])], default_name: &'static str,
        looks: Option<&[ProtoDiskLook]>) -> Vec<ColorPreset> {
    let mut d = WallpaperConfig::default();
    let defaults: Vec<Rgb> = fields.iter().map(|f| *f(&mut d)).collect();
    let mut all: Vec<(&'static str, Vec<Rgb>)> = vec![(default_name, defaults)];
    all.extend(entries.iter().map(|(n, c)| (*n, c.to_vec())));
    all.into_iter()
        .enumerate()
        .map(|(i, (name, colors))| ColorPreset {
            name,
            colors: fields.iter().copied().zip(colors).collect(),
            look: looks.map(|l| l[i]),
        })
        .collect()
}

const fn c(r: f32, g: f32, b: f32) -> Rgb {
    rgb(r, g, b)
}

/// The scene's presets, its default look first; empty for scenes that use the palette presets or
/// have no colors of their own.
pub fn color_presets(scene: SceneKind) -> Vec<ColorPreset> {
    use SceneKind::*;
    match scene {
        Galaxy => list(
            &[|c| &mut c.palette.galaxy_core, |c| &mut c.palette.galaxy_arms, |c| &mut c.palette.galaxy_nebula, |c| &mut c.palette.galaxy_dust],
            &[
                ("Starburst", &[c(1.0, 0.85, 0.6), c(0.45, 0.75, 1.0), c(1.0, 0.2, 0.55), c(0.15, 0.04, 0.02)]),
                ("Infrared", &[c(0.4, 0.62, 1.0), c(1.0, 0.45, 0.18), c(1.0, 0.18, 0.12), c(0.06, 0.02, 0.08)]),
                ("Ultraviolet", &[c(0.85, 0.7, 1.0), c(0.5, 0.5, 1.0), c(0.85, 0.35, 1.0), c(0.04, 0.02, 0.1)]),
                ("Golden", &[c(1.0, 0.75, 0.35), c(1.0, 0.88, 0.6), c(1.0, 0.45, 0.2), c(0.18, 0.07, 0.02)]),
                ("Teal", &[c(0.75, 1.0, 0.9), c(0.25, 0.85, 0.9), c(0.9, 0.35, 1.0), c(0.02, 0.08, 0.1)]),
            ],
            "Default",
            None,
        ),
        Pulsar => list(
            &[|c| &mut c.pulsar_beam_color, |c| &mut c.pulsar_field_color, |c| &mut c.pulsar_ring_color, |c| &mut c.pulsar_nebula_color],
            &[
                ("X-ray", &[c(0.6, 0.85, 1.0), c(0.4, 0.6, 1.0), c(0.7, 0.8, 1.0), c(0.35, 0.5, 1.0)]),
                ("Crab", &[c(1.0, 0.9, 0.8), c(1.0, 0.55, 0.35), c(1.0, 0.35, 0.15), c(0.45, 0.7, 1.0)]),
                ("Magnetar", &[c(1.0, 0.4, 0.85), c(1.0, 0.25, 0.45), c(1.0, 0.6, 0.3), c(0.7, 0.2, 1.0)]),
                ("Emerald", &[c(0.4, 1.0, 0.7), c(0.2, 0.85, 0.75), c(1.0, 0.8, 0.35), c(0.2, 0.6, 1.0)]),
                ("Solar", &[c(1.0, 0.85, 0.5), c(1.0, 0.55, 0.2), c(1.0, 0.4, 0.2), c(1.0, 0.3, 0.5)]),
            ],
            "Default",
            None,
        ),
        GasGiant => list(
            &[|c| &mut c.gas_zone, |c| &mut c.gas_belt, |c| &mut c.gas_storm],
            &[
                ("Saturn", &[c(1.0, 0.9, 0.68), c(0.78, 0.6, 0.38), c(1.0, 0.95, 0.85)]),
                ("Neptune", &[c(0.5, 0.75, 1.0), c(0.12, 0.25, 0.75), c(0.08, 0.1, 0.4)]),
                ("Uranus", &[c(0.7, 1.0, 0.95), c(0.35, 0.75, 0.8), c(0.9, 1.0, 1.0)]),
                ("Hot Jupiter", &[c(1.0, 0.5, 0.25), c(0.4, 0.08, 0.06), c(1.0, 0.85, 0.4)]),
                ("Violet", &[c(0.85, 0.7, 1.0), c(0.35, 0.15, 0.6), c(1.0, 0.35, 0.6)]),
            ],
            "Default",
            None,
        ),
        AuroraOrbit => list(
            &[|c| &mut c.aurora_green, |c| &mut c.aurora_red, |c| &mut c.aurora_fringe, |c| &mut c.aurora_city_color],
            &[
                ("Red storm", &[c(1.0, 0.3, 0.3), c(1.0, 0.1, 0.45), c(1.0, 0.4, 0.8), c(1.0, 0.62, 0.3)]),
                ("Jovian", &[c(0.55, 0.4, 1.0), c(1.0, 0.3, 0.8), c(0.3, 0.6, 1.0), c(1.0, 0.7, 0.4)]),
                ("Teal", &[c(0.1, 1.0, 0.8), c(0.3, 0.5, 1.0), c(0.75, 0.3, 1.0), c(0.85, 0.9, 1.0)]),
                ("LED cities", &[c(0.35, 1.0, 0.4), c(1.0, 0.2, 0.35), c(1.0, 0.3, 0.9), c(0.85, 0.9, 1.0)]),
                ("Gold", &[c(1.0, 0.85, 0.3), c(1.0, 0.4, 0.2), c(1.0, 0.3, 0.6), c(1.0, 0.62, 0.3)]),
            ],
            "Default",
            None,
        ),
        PlanetaryNebula => list(
            &[|c| &mut c.planetary_inner_color, |c| &mut c.planetary_rim_color, |c| &mut c.planetary_halo_color],
            &[
                ("Ring", &[c(0.3, 0.6, 1.0), c(1.0, 0.45, 0.2), c(1.0, 0.25, 0.3)]),
                ("Cat's Eye", &[c(0.35, 1.0, 0.6), c(1.0, 0.3, 0.6), c(0.6, 0.3, 1.0)]),
                ("Helix", &[c(0.2, 0.85, 1.0), c(1.0, 0.2, 0.15), c(1.0, 0.5, 0.2)]),
                ("Violet", &[c(0.75, 0.5, 1.0), c(1.0, 0.3, 0.75), c(0.4, 0.3, 1.0)]),
                ("Gold", &[c(1.0, 0.85, 0.45), c(1.0, 0.4, 0.15), c(0.9, 0.25, 0.2)]),
            ],
            "Default",
            None,
        ),
        Comet => list(
            &[|c| &mut c.comet_ion_color, |c| &mut c.comet_dust_color],
            &[
                ("Emerald", &[c(0.3, 1.0, 0.6), c(1.0, 0.9, 0.7)]),
                ("Sungrazer", &[c(0.5, 0.75, 1.0), c(1.0, 0.7, 0.35)]),
                ("Violet", &[c(0.7, 0.45, 1.0), c(1.0, 0.75, 0.85)]),
                ("Teal", &[c(0.2, 0.9, 1.0), c(1.0, 0.8, 0.45)]),
                ("Rose", &[c(1.0, 0.4, 0.7), c(1.0, 0.85, 0.6)]),
            ],
            "Default",
            None,
        ),
        DysonSwarm => list(
            &[|c| &mut c.dyson_panel_a, |c| &mut c.dyson_panel_b, |c| &mut c.dyson_heat],
            &[
                ("Gold foil", &[c(1.0, 0.78, 0.3), c(1.0, 0.55, 0.15), c(1.0, 0.25, 0.1)]),
                ("Silicon", &[c(0.15, 0.3, 1.0), c(0.2, 0.9, 1.0), c(1.0, 0.3, 0.2)]),
                ("Chrome", &[c(0.9, 0.95, 1.0), c(0.7, 0.8, 1.0), c(1.0, 0.45, 0.15)]),
                ("Copper", &[c(1.0, 0.5, 0.2), c(0.1, 1.0, 0.7), c(1.0, 0.2, 0.3)]),
                ("Violet", &[c(0.7, 0.4, 1.0), c(1.0, 0.4, 0.7), c(1.0, 0.15, 0.4)]),
            ],
            "Default",
            None,
        ),
        RoguePlanet => list(
            &[|c| &mut c.rogue_aurora_low, |c| &mut c.rogue_aurora_high, |c| &mut c.rogue_rift_color],
            &[
                ("Classic", &[c(0.2, 1.0, 0.4), c(1.0, 0.2, 0.35), c(1.0, 0.55, 0.15)]),
                ("Ice", &[c(0.3, 0.8, 1.0), c(0.6, 0.4, 1.0), c(0.4, 0.9, 1.0)]),
                ("Magma", &[c(1.0, 0.5, 0.2), c(1.0, 0.15, 0.4), c(1.0, 0.3, 0.05)]),
                ("Toxic", &[c(0.7, 1.0, 0.2), c(0.2, 1.0, 0.8), c(0.9, 1.0, 0.3)]),
                ("Rose", &[c(1.0, 0.45, 0.75), c(1.0, 0.8, 0.4), c(0.4, 0.9, 1.0)]),
            ],
            "Default",
            None,
        ),
        Eclipse => list(
            &[|c| &mut c.eclipse_corona_color, |c| &mut c.eclipse_prominence_color],
            &[
                ("Violet", &[c(0.8, 0.5, 1.0), c(1.0, 0.3, 0.6)]),
                ("Golden", &[c(1.0, 0.85, 0.55), c(1.0, 0.35, 0.15)]),
                ("Red dwarf", &[c(1.0, 0.55, 0.35), c(1.0, 0.2, 0.2)]),
                ("Blue giant", &[c(0.3, 0.7, 1.0), c(0.6, 0.35, 1.0)]),
                ("Emerald", &[c(0.6, 1.0, 0.85), c(1.0, 0.4, 0.6)]),
            ],
            "Default",
            None,
        ),
        Quasar => list(
            &[|c| &mut c.quasar_jet_color, |c| &mut c.quasar_lobe_color],
            &[
                ("X-ray", &[c(0.62, 0.88, 1.0), c(0.3, 0.45, 1.0)]),
                ("Optical", &[c(1.0, 0.85, 0.6), c(1.0, 0.42, 0.25)]),
                ("Infrared", &[c(1.0, 0.55, 0.3), c(1.0, 0.2, 0.25)]),
                ("Teal", &[c(0.3, 1.0, 0.85), c(0.4, 0.4, 1.0)]),
                ("Violet", &[c(0.8, 0.6, 1.0), c(0.55, 0.2, 1.0)]),
            ],
            "Radio",
            None,
        ),
        RingedPlanet => list(
            &[|c| &mut c.ringed_band_light, |c| &mut c.ringed_band_dark, |c| &mut c.ringed_ring_color],
            &[
                ("Ice", &[c(0.72, 0.9, 1.0), c(0.2, 0.42, 0.72), c(0.82, 0.9, 1.0)]),
                ("Rust", &[c(1.0, 0.58, 0.34), c(0.48, 0.13, 0.06), c(0.92, 0.68, 0.5)]),
                ("Violet", &[c(0.86, 0.68, 1.0), c(0.32, 0.16, 0.6), c(0.9, 0.82, 1.0)]),
                ("Jade", &[c(0.62, 1.0, 0.82), c(0.08, 0.42, 0.36), c(0.86, 0.96, 0.88)]),
                ("Rose", &[c(1.0, 0.75, 0.8), c(0.55, 0.15, 0.3), c(1.0, 0.88, 0.9)]),
            ],
            "Golden",
            None,
        ),
        BlackHoleMerger => list(
            &[|c| &mut c.bbh_ring_color, |c| &mut c.bbh_hot, |c| &mut c.bbh_cool],
            &[
                ("Gold", &[c(1.0, 0.85, 0.55), c(1.0, 0.9, 0.6), c(1.0, 0.4, 0.12)]),
                ("Violet", &[c(0.78, 0.62, 1.0), c(0.6, 0.55, 1.0), c(1.0, 0.25, 0.6)]),
                ("Teal", &[c(0.45, 1.0, 0.9), c(0.4, 0.95, 1.0), c(1.0, 0.5, 0.3)]),
                ("Ember", &[c(1.0, 0.55, 0.35), c(1.0, 0.75, 0.45), c(0.8, 0.12, 0.1)]),
                ("EHT", &[c(1.0, 0.62, 0.2), c(1.0, 0.8, 0.35), c(0.78, 0.15, 0.04)]),
            ],
            "Ice",
            None,
        ),
        NeutronMerger => list(
            &[|c| &mut c.merger_star_color, |c| &mut c.merger_hot, |c| &mut c.merger_cool],
            &[
                ("Gold", &[c(1.0, 0.9, 0.7), c(1.0, 0.86, 0.45), c(0.85, 0.2, 0.08)]),
                ("Violet", &[c(0.78, 0.74, 1.0), c(0.62, 0.55, 1.0), c(0.95, 0.15, 0.55)]),
                ("Teal", &[c(0.7, 1.0, 0.95), c(0.35, 0.95, 0.9), c(0.95, 0.42, 0.2)]),
                ("Ember", &[c(1.0, 0.75, 0.5), c(1.0, 0.6, 0.3), c(0.7, 0.05, 0.1)]),
            ],
            "Kilonova",
            None,
        ),
        ProtoplanetaryDisk => list(
            &[|c| &mut c.proto_dust_color, |c| &mut c.proto_gas_color, |c| &mut c.proto_star_color, |c| &mut c.proto_jet_color],
            &[
                ("HL Tau", &[c(1.0, 0.55, 0.12), c(0.9, 0.4, 0.2), c(1.0, 0.92, 0.75), c(1.0, 0.45, 0.3)]),
                ("Scattered", &[c(0.95, 0.6, 0.35), c(0.78, 0.84, 1.0), c(1.0, 0.95, 0.85), c(1.0, 0.3, 0.4)]),
                ("Infrared", &[c(1.0, 0.3, 0.2), c(1.0, 0.62, 0.3), c(1.0, 0.8, 0.6), c(0.4, 0.7, 1.0)]),
                ("Teal", &[c(0.12, 0.78, 0.7), c(0.5, 0.38, 1.0), c(0.9, 0.95, 1.0), c(1.0, 0.35, 0.75)]),
                ("Violet", &[c(0.75, 0.35, 1.0), c(0.35, 0.75, 1.0), c(1.0, 0.95, 0.9), c(1.0, 0.5, 0.3)]),
            ],
            "Default",
            Some(&[ProtoDiskLook::Blend, ProtoDiskLook::Alma, ProtoDiskLook::Scattered, ProtoDiskLook::Scattered,
                   ProtoDiskLook::Blend, ProtoDiskLook::Blend]),
        ),
        Nebula => list(
            &[|c| &mut c.nebula_ha, |c| &mut c.nebula_oiii, |c| &mut c.nebula_sii],
            &[("Hubble", &[c(0.35, 1.0, 0.4), c(0.2, 0.45, 1.0), c(1.0, 0.35, 0.12)])],
            "Natural",
            None,
        ),
        BlackHole | Wormhole | TidalDisruption | Binary | Trinary | StellarSurface | LiveEarth => vec![],
    }
}

/// The palette presets, leaving the galaxy scene's colors as they are (they have their own).
pub fn palette_presets(current: &PaletteConfig) -> Vec<(&'static str, PaletteConfig, Vec<Rgb>)> {
    PaletteConfig::presets()
        .into_iter()
        .map(|(name, preset)| {
            let mut p = preset;
            p.galaxy_core = current.galaxy_core;
            p.galaxy_arms = current.galaxy_arms;
            p.galaxy_nebula = current.galaxy_nebula;
            p.galaxy_dust = current.galaxy_dust;
            (name, p, vec![preset.receding, preset.core, preset.approaching, preset.nebula_a])
        })
        .collect()
}

