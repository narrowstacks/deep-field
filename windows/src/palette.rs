//! Colors: picks, shader light, the shared disk palette and the per-scene tuned colors
//! (Config/Palette.swift, Config/PickedColor.swift and GPUTypes' PaletteGPU in the macOS app).
#![allow(dead_code)]

use serde::{Deserialize, Serialize};

use crate::config::WallpaperConfig;
use crate::gpu_types::PaletteGpu;

/// A color as saved (Float components, like the Swift `RGB`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize, Default)]
pub struct Rgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

pub const fn rgb(r: f32, g: f32, b: f32) -> Rgb {
    Rgb { r, g, b }
}

impl Rgb {
    /// `RGB.simd`: the color as is, w = 1.
    pub fn simd(self) -> [f32; 4] {
        [self.r, self.g, self.b, 1.0]
    }
    /// The shader light for this picked color at an element's typical brightness, w = 0.
    pub fn light(self, level: f32) -> [f32; 4] {
        let l = self.light3(level);
        [l[0], l[1], l[2], 0.0]
    }
    pub fn light3(self, level: f32) -> [f32; 3] {
        picked_light(self, level)
    }
    /// A tuned shader light value, expressed as the pick that reproduces it.
    pub fn as_pick(self, level: f32) -> Rgb {
        pick_for_light(self, level)
    }
    pub fn arr(self) -> [f32; 3] {
        [self.r, self.g, self.b]
    }
}

// PickedColor: a pick is the sRGB color the element should show where it's typically lit. The
// shaders work in linear light that is exposed, tone mapped (1 - e^-x), saturated and gamma
// encoded, so `light` runs that chain backwards at the default exposure and saturation. All of it
// is Float math, as in Swift.

/// The default look the compensation aims at (WallpaperConfig's brightness and saturation).
pub const PICK_EXPOSURE: f32 = 1.15;
pub const PICK_SATURATION: f32 = 1.35;
/// The brightest tone-mapped value a pick asks for; 1 would need infinite light.
pub const PICK_MAX_TONE: f32 = 0.985;
const LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];

fn dot3(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn clampf(v: f32, lo: f32, hi: f32) -> f32 {
    v.max(lo).min(hi)
}

pub fn picked_light(pick: Rgb, level: f32) -> [f32; 3] {
    let srgb = [clampf(pick.r, 0.0, 1.0), clampf(pick.g, 0.0, 1.0), clampf(pick.b, 0.0, 1.0)];
    let t = [srgb[0].powf(2.2), srgb[1].powf(2.2), srgb[2].powf(2.2)];
    let luma = dot3(t, LUMA);
    let c = t.map(|v| clampf(luma + (v - luma) / PICK_SATURATION, 0.0, PICK_MAX_TONE));
    let x = c.map(|v| -(1.0 - v).ln() / PICK_EXPOSURE);
    x.map(|v| v / level)
}

pub fn pick_for_light(v: Rgb, level: f32) -> Rgb {
    let x = [v.r, v.g, v.b].map(|c| c * level * PICK_EXPOSURE);
    let c = x.map(|v| 1.0 - (-v).exp());
    let luma = dot3(c, LUMA);
    let s = c.map(|v| clampf(luma + (v - luma) * PICK_SATURATION, 0.0, 1.0));
    fn enc(v: f32) -> f32 {
        (v.powf(1.0 / 2.2) * 1000.0).round() / 1000.0
    }
    rgb(enc(s[0]), enc(s[1]), enc(s[2]))
}

/// Typical brightness of each element in its shader, per unit of color (PickedColor.Level).
pub mod level {
    pub const DISK_RECEDING: f32 = 0.52;
    pub const DISK_APPROACHING: f32 = 0.8;
    pub const DISK_CORE: f32 = 0.85;
    pub const RING: f32 = 1.0;
    pub const GALAXY_CORE: f32 = 0.36;
    pub const GALAXY_ARMS: f32 = 0.47;
    pub const GALAXY_NEBULA: f32 = 0.61;
    pub const PULSAR_BEAM: f32 = 0.79;
    pub const PULSAR_FIELD: f32 = 0.44;
    pub const PULSAR_RING: f32 = 0.64;
    pub const PULSAR_NEBULA: f32 = 0.34;
    pub const COMET_ION: f32 = 0.36;
    pub const COMET_DUST: f32 = 0.29;
    pub const TDE_JET: f32 = 0.45;
    pub const PLANETARY_INNER: f32 = 0.5;
    pub const PLANETARY_RIM: f32 = 0.6;
    pub const PLANETARY_HALO: f32 = 0.25;
    pub const RINGED_BAND: f32 = 0.75;
    pub const RINGED_RING: f32 = 0.6;
    pub const AURORA: f32 = 0.6;
    pub const AURORA_CITY: f32 = 0.5;
    pub const GAS_CLOUD: f32 = 0.75;
    pub const PROTO_DUST: f32 = 0.6;
    pub const PROTO_GAS: f32 = 0.5;
    pub const PROTO_STAR: f32 = 1.0;
    pub const PROTO_JET: f32 = 0.5;
    pub const MERGER_STAR: f32 = 0.8;
    pub const MERGER_KILONOVA: f32 = 0.6;
    pub const BBH_RING: f32 = 1.0;
    pub const BBH_GAS: f32 = 0.6;
    pub const DYSON_PANEL: f32 = 0.3;
    pub const DYSON_HEAT: f32 = 0.1;
    pub const ROGUE_AURORA: f32 = 0.5;
    pub const ROGUE_RIFT: f32 = 0.5;
    pub const ECLIPSE_CORONA: f32 = 1.0;
    pub const ECLIPSE_PROMINENCE: f32 = 1.0;
    pub const ECLIPSE_GROUND: f32 = 1.0;
    pub const ECLIPSE_PLANET: f32 = 1.0;
    pub const QUASAR_JET: f32 = 0.6;
    pub const QUASAR_LOBE: f32 = 0.5;
}

/// The per-scene colors as they were tuned, in shader light; the config defaults are their picks
/// (WallpaperConfig.Tuned). `key()` is the saved config key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tuned {
    TdeJet, PulsarBeam, PulsarNebula, PulsarField, PulsarRing, CometIon, CometDust,
    PlanetaryInner, PlanetaryRim, PlanetaryHalo, RingedBandLight, RingedBandDark, RingedRing,
    AuroraGreen, AuroraRed, AuroraFringe, AuroraCity, GasZone, GasBelt, GasStorm,
    ProtoDust, ProtoGas, ProtoStar, ProtoJet, MergerStar, MergerHot, MergerCool,
    BbhRing, BbhHot, BbhCool, DysonPanelA, DysonPanelB, DysonHeat,
    RogueAuroraLow, RogueAuroraHigh, RogueRift,
    EclipseCorona, EclipseProminence, EclipseGround, EclipsePlanet, QuasarJet, QuasarLobe,
}

impl Tuned {
    pub const ALL: [Tuned; 42] = {
        use Tuned::*;
        [
            TdeJet, PulsarBeam, PulsarNebula, PulsarField, PulsarRing, CometIon, CometDust,
            PlanetaryInner, PlanetaryRim, PlanetaryHalo, RingedBandLight, RingedBandDark, RingedRing,
            AuroraGreen, AuroraRed, AuroraFringe, AuroraCity, GasZone, GasBelt, GasStorm,
            ProtoDust, ProtoGas, ProtoStar, ProtoJet, MergerStar, MergerHot, MergerCool,
            BbhRing, BbhHot, BbhCool, DysonPanelA, DysonPanelB, DysonHeat,
            RogueAuroraLow, RogueAuroraHigh, RogueRift,
            EclipseCorona, EclipseProminence, EclipseGround, EclipsePlanet, QuasarJet, QuasarLobe,
        ]
    };

    pub fn key(self) -> &'static str {
        use Tuned::*;
        match self {
            TdeJet => "tdeJetColor", PulsarBeam => "pulsarBeamColor", PulsarNebula => "pulsarNebulaColor",
            PulsarField => "pulsarFieldColor", PulsarRing => "pulsarRingColor",
            CometIon => "cometIonColor", CometDust => "cometDustColor",
            PlanetaryInner => "planetaryInnerColor", PlanetaryRim => "planetaryRimColor",
            PlanetaryHalo => "planetaryHaloColor",
            RingedBandLight => "ringedBandLight", RingedBandDark => "ringedBandDark", RingedRing => "ringedRingColor",
            AuroraGreen => "auroraGreen", AuroraRed => "auroraRed", AuroraFringe => "auroraFringe",
            AuroraCity => "auroraCityColor",
            GasZone => "gasZone", GasBelt => "gasBelt", GasStorm => "gasStorm",
            ProtoDust => "protoDustColor", ProtoGas => "protoGasColor", ProtoStar => "protoStarColor",
            ProtoJet => "protoJetColor",
            MergerStar => "mergerStarColor", MergerHot => "mergerHot", MergerCool => "mergerCool",
            BbhRing => "bbhRingColor", BbhHot => "bbhHot", BbhCool => "bbhCool",
            DysonPanelA => "dysonPanelA", DysonPanelB => "dysonPanelB", DysonHeat => "dysonHeat",
            RogueAuroraLow => "rogueAuroraLow", RogueAuroraHigh => "rogueAuroraHigh", RogueRift => "rogueRiftColor",
            EclipseCorona => "eclipseCorona", EclipseProminence => "eclipseProminence",
            EclipseGround => "eclipseGround", EclipsePlanet => "eclipsePlanet",
            QuasarJet => "quasarJetColor", QuasarLobe => "quasarLobeColor",
        }
    }

    pub fn light(self) -> Rgb {
        use Tuned::*;
        match self {
            TdeJet => rgb(0.6, 0.5, 1.0),
            PulsarBeam => rgb(0.55, 0.75, 1.0),
            PulsarNebula => rgb(0.7, 0.4, 1.0),
            PulsarField => rgb(0.45, 0.68, 1.0),
            PulsarRing => rgb(1.0, 0.6, 0.36),
            CometIon => rgb(0.3, 0.6, 1.0),
            CometDust => rgb(1.0, 0.85, 0.6),
            PlanetaryInner => rgb(0.25, 0.8, 1.0),
            PlanetaryRim => rgb(1.0, 0.3, 0.24),
            PlanetaryHalo => rgb(1.0, 0.35, 0.45),
            RingedBandLight => rgb(1.0, 0.76, 0.38),
            RingedBandDark => rgb(0.6, 0.26, 0.07),
            RingedRing => rgb(1.0, 0.82, 0.55),
            AuroraGreen => rgb(0.1, 1.0, 0.35),
            AuroraRed => rgb(1.0, 0.08, 0.4),
            AuroraFringe => rgb(1.0, 0.2, 0.85),
            AuroraCity => rgb(1.0, 0.62, 0.28),
            GasZone => rgb(1.0, 0.82, 0.58),
            GasBelt => rgb(0.62, 0.24, 0.08),
            GasStorm => rgb(0.9, 0.24, 0.08),
            ProtoDust => rgb(1.0, 0.45, 0.12),
            ProtoGas => rgb(0.55, 0.62, 1.0),
            ProtoStar => rgb(1.0, 0.85, 0.65),
            ProtoJet => rgb(1.0, 0.25, 0.45),
            MergerStar => rgb(0.42, 0.68, 1.0),
            MergerHot => rgb(0.3, 0.58, 1.0),
            MergerCool => rgb(1.0, 0.2, 0.06),
            BbhRing => rgb(0.5, 0.62, 1.0),
            BbhHot => rgb(0.55, 0.75, 1.0),
            BbhCool => rgb(1.0, 0.45, 0.15),
            DysonPanelA => rgb(1.0, 0.62, 0.18),
            DysonPanelB => rgb(0.3, 0.38, 1.0),
            DysonHeat => rgb(1.0, 0.16, 0.1),
            RogueAuroraLow => rgb(0.1, 1.0, 0.55),
            RogueAuroraHigh => rgb(0.75, 0.15, 1.0),
            RogueRift => rgb(1.0, 0.32, 0.06),
            EclipseCorona => rgb(0.5, 0.62, 1.0),
            EclipseProminence => rgb(1.0, 0.16, 0.42),
            EclipseGround => rgb(0.62, 0.58, 0.54),
            EclipsePlanet => rgb(0.3, 0.7, 0.85),
            QuasarJet => rgb(0.45, 0.7, 1.0),
            QuasarLobe => rgb(1.0, 0.22, 0.8),
        }
    }

    pub fn level(self) -> f32 {
        use level as L;
        use Tuned::*;
        match self {
            TdeJet => L::TDE_JET,
            PulsarBeam => L::PULSAR_BEAM,
            PulsarNebula => L::PULSAR_NEBULA,
            PulsarField => L::PULSAR_FIELD,
            PulsarRing => L::PULSAR_RING,
            CometIon => L::COMET_ION,
            CometDust => L::COMET_DUST,
            PlanetaryInner => L::PLANETARY_INNER,
            PlanetaryRim => L::PLANETARY_RIM,
            PlanetaryHalo => L::PLANETARY_HALO,
            RingedBandLight | RingedBandDark => L::RINGED_BAND,
            RingedRing => L::RINGED_RING,
            AuroraGreen | AuroraRed | AuroraFringe => L::AURORA,
            AuroraCity => L::AURORA_CITY,
            GasZone | GasBelt | GasStorm => L::GAS_CLOUD,
            ProtoDust => L::PROTO_DUST,
            ProtoGas => L::PROTO_GAS,
            ProtoStar => L::PROTO_STAR,
            ProtoJet => L::PROTO_JET,
            MergerStar => L::MERGER_STAR,
            MergerHot | MergerCool => L::MERGER_KILONOVA,
            BbhRing => L::BBH_RING,
            BbhHot | BbhCool => L::BBH_GAS,
            DysonPanelA | DysonPanelB => L::DYSON_PANEL,
            DysonHeat => L::DYSON_HEAT,
            RogueAuroraLow | RogueAuroraHigh => L::ROGUE_AURORA,
            RogueRift => L::ROGUE_RIFT,
            EclipseCorona => L::ECLIPSE_CORONA,
            EclipseProminence => L::ECLIPSE_PROMINENCE,
            EclipseGround => L::ECLIPSE_GROUND,
            EclipsePlanet => L::ECLIPSE_PLANET,
            QuasarJet => L::QUASAR_JET,
            QuasarLobe => L::QUASAR_LOBE,
        }
    }

    /// The default pick: the tuned light run forwards through the display chain.
    pub fn color(self) -> Rgb {
        self.light().as_pick(self.level())
    }
}

fn default_galaxy_core() -> Rgb { rgb(1.0, 0.80, 0.52) }
fn default_galaxy_arms() -> Rgb { rgb(0.55, 0.72, 1.0) }
fn default_galaxy_nebula() -> Rgb { rgb(1.0, 0.35, 0.6) }
fn default_galaxy_dust() -> Rgb { rgb(0.12, 0.05, 0.02) }

/// The shared palette (black hole disk, wormhole, sky tints, galaxy scene).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PaletteConfig {
    /// disk side moving away (redshifted)
    pub receding: Rgb,
    /// disk side moving toward you (blueshifted)
    pub approaching: Rgb,
    /// hottest inner disk
    pub core: Rgb,
    /// photon ring / wormhole rim
    pub ring: Rgb,
    pub nebula_a: Rgb,
    pub nebula_b: Rgb,
    /// the wormhole's other universe
    pub far_a: Rgb,
    pub far_b: Rgb,
    pub star_warm: Rgb,
    pub star_cool: Rgb,
    pub galaxy: Rgb,
    pub galaxy_core: Rgb,
    pub galaxy_arms: Rgb,
    pub galaxy_nebula: Rgb,
    pub galaxy_dust: Rgb,
}

impl Default for PaletteConfig {
    fn default() -> Self {
        PaletteConfig::gargantua()
    }
}

#[allow(clippy::too_many_arguments)]
fn tuned_palette(receding: Rgb, approaching: Rgb, core: Rgb, ring: Rgb, nebula_a: Rgb, nebula_b: Rgb,
                 far_a: Rgb, far_b: Rgb, star_warm: Rgb, star_cool: Rgb, galaxy: Rgb) -> PaletteConfig {
    PaletteConfig {
        receding, approaching, core, ring, nebula_a, nebula_b, far_a, far_b, star_warm, star_cool, galaxy,
        galaxy_core: default_galaxy_core(), galaxy_arms: default_galaxy_arms(),
        galaxy_nebula: default_galaxy_nebula(), galaxy_dust: default_galaxy_dust(),
    }
}

/// Which palette colors are picks, by saved key, with each one's typical brightness. The rest
/// (the faint background sky, galaxy dust) are tints, used as is.
pub const PALETTE_PICKED: [(&str, f32); 7] = [
    ("receding", level::DISK_RECEDING), ("approaching", level::DISK_APPROACHING),
    ("core", level::DISK_CORE), ("ring", level::RING),
    ("galaxyCore", level::GALAXY_CORE), ("galaxyArms", level::GALAXY_ARMS),
    ("galaxyNebula", level::GALAXY_NEBULA),
];

impl PaletteConfig {
    pub fn picked_mut(&mut self, key: &str) -> Option<&mut Rgb> {
        Some(match key {
            "receding" => &mut self.receding,
            "approaching" => &mut self.approaching,
            "core" => &mut self.core,
            "ring" => &mut self.ring,
            "galaxyCore" => &mut self.galaxy_core,
            "galaxyArms" => &mut self.galaxy_arms,
            "galaxyNebula" => &mut self.galaxy_nebula,
            _ => return None,
        })
    }

    pub fn picked(&self, key: &str) -> Option<Rgb> {
        let mut p = *self;
        p.picked_mut(key).map(|c| *c)
    }

    /// A palette written as shader light, with its picked colors converted to picks.
    pub fn from_light(&self) -> PaletteConfig {
        let mut p = *self;
        for (key, lvl) in PALETTE_PICKED {
            let v = self.picked(key).unwrap();
            *p.picked_mut(key).unwrap() = v.as_pick(lvl);
        }
        p
    }

    /// The presets as tuned, in shader light.
    pub fn tuned_presets() -> Vec<(&'static str, PaletteConfig)> {
        vec![
            ("Gargantua", tuned_palette(
                rgb(1.0, 0.36, 0.02), rgb(0.25, 0.5, 1.0), rgb(1.0, 0.78, 0.45),
                rgb(0.6, 0.75, 1.0), rgb(0.1, 0.3, 1.0), rgb(1.0, 0.33, 0.17),
                rgb(0.85, 0.35, 1.0), rgb(0.15, 0.85, 0.85),
                rgb(1.0, 0.72, 0.45), rgb(0.55, 0.72, 1.0), rgb(1.0, 0.85, 0.7))),
            ("Ember", tuned_palette(
                rgb(1.0, 0.12, 0.02), rgb(1.0, 0.7, 0.15), rgb(1.0, 0.92, 0.65),
                rgb(1.0, 0.55, 0.25), rgb(0.7, 0.1, 0.05), rgb(1.0, 0.5, 0.1),
                rgb(1.0, 0.3, 0.1), rgb(1.0, 0.8, 0.3),
                rgb(1.0, 0.6, 0.35), rgb(1.0, 0.85, 0.6), rgb(1.0, 0.7, 0.4))),
            ("Glacier", tuned_palette(
                rgb(0.15, 0.45, 1.0), rgb(0.6, 1.0, 1.0), rgb(0.92, 0.98, 1.0),
                rgb(0.8, 0.95, 1.0), rgb(0.1, 0.4, 1.0), rgb(0.4, 0.9, 1.0),
                rgb(0.3, 0.6, 1.0), rgb(0.7, 1.0, 0.9),
                rgb(0.8, 0.9, 1.0), rgb(0.5, 0.75, 1.0), rgb(0.8, 0.9, 1.0))),
            ("Synthwave", tuned_palette(
                rgb(1.0, 0.1, 0.55), rgb(0.1, 0.85, 1.0), rgb(1.0, 0.85, 1.0),
                rgb(1.0, 0.45, 1.0), rgb(0.55, 0.1, 1.0), rgb(1.0, 0.2, 0.6),
                rgb(1.0, 0.2, 0.7), rgb(0.2, 1.0, 0.9),
                rgb(1.0, 0.55, 0.9), rgb(0.5, 0.9, 1.0), rgb(1.0, 0.6, 1.0))),
            ("Amber CRT", tuned_palette(
                rgb(1.0, 0.45, 0.0), rgb(1.0, 0.7, 0.15), rgb(1.0, 0.85, 0.5),
                rgb(1.0, 0.7, 0.3), rgb(1.0, 0.5, 0.0), rgb(1.0, 0.6, 0.1),
                rgb(1.0, 0.55, 0.05), rgb(1.0, 0.75, 0.3),
                rgb(1.0, 0.65, 0.2), rgb(1.0, 0.8, 0.45), rgb(1.0, 0.7, 0.3))),
            ("Emerald", tuned_palette(
                rgb(0.05, 0.8, 0.3), rgb(0.4, 0.6, 1.0), rgb(0.85, 1.0, 0.8),
                rgb(0.6, 1.0, 0.8), rgb(0.05, 0.6, 0.4), rgb(0.3, 0.3, 1.0),
                rgb(0.9, 0.9, 0.2), rgb(0.2, 0.9, 0.5),
                rgb(0.85, 1.0, 0.7), rgb(0.6, 0.8, 1.0), rgb(0.8, 1.0, 0.8))),
        ]
    }

    /// The presets as picks (what the config stores).
    pub fn presets() -> Vec<(&'static str, PaletteConfig)> {
        Self::tuned_presets().into_iter().map(|(n, p)| (n, p.from_light())).collect()
    }

    pub fn preset(name: &str) -> Option<PaletteConfig> {
        Self::presets().into_iter().find(|(n, _)| *n == name).map(|(_, p)| p)
    }

    pub fn gargantua() -> PaletteConfig {
        Self::tuned_presets()[0].1.from_light()
    }
}

/// `PaletteGPU.init`: picks become shader light, tints go through as is (w = 1).
pub fn palette_gpu(c: &WallpaperConfig) -> PaletteGpu {
    let p = &c.palette;
    PaletteGpu {
        receding: p.receding.light(level::DISK_RECEDING),
        approaching: p.approaching.light(level::DISK_APPROACHING),
        core: p.core.light(level::DISK_CORE),
        ring: p.ring.light(level::RING),
        nebula_a: p.nebula_a.simd(),
        nebula_b: p.nebula_b.simd(),
        far_a: p.far_a.simd(),
        far_b: p.far_b.simd(),
        star_warm: p.star_warm.simd(),
        star_cool: p.star_cool.simd(),
        galaxy: p.galaxy.simd(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_round_trip_close_to_light() {
        // A tuned light value turned into a pick and back lands near where it started (the pick
        // is rounded to three decimals, so not exactly).
        let t = Tuned::GasZone;
        let back = t.color().light3(t.level());
        let l = t.light();
        assert!((back[0] - l.r).abs() < 0.03 && (back[1] - l.g).abs() < 0.03 && (back[2] - l.b).abs() < 0.03);
    }

    #[test]
    fn gargantua_picks_are_rounded() {
        let g = PaletteConfig::gargantua();
        let r = g.receding.r * 1000.0;
        assert!((r - r.round()).abs() < 1e-3);
        // tints are kept as written
        assert_eq!(g.nebula_a, rgb(0.1, 0.3, 1.0));
    }
}
