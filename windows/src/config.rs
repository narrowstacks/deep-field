//! The saved settings and their option types (Config/WallpaperConfig.swift, Options.swift,
//! SceneKind.swift, StarType.swift, PulsarOptions.swift in the macOS app). The JSON keys and enum
//! raw values match the Swift Codable output, so a config saved by one app reads in the other.
#![allow(dead_code)]

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::palette::{rgb, PaletteConfig, Rgb, Tuned, PALETTE_PICKED};

/// A string-backed enum whose serde names are the Swift raw values.
macro_rules! raw_enum {
    ($(#[$m:meta])* $name:ident { $($var:ident = $raw:literal),* $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        pub enum $name { $( #[serde(rename = $raw)] $var ),* }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$var),*];
            pub fn all() -> &'static [$name] { Self::ALL }
            pub fn raw(self) -> &'static str { match self { $($name::$var => $raw),* } }
            pub fn from_raw(s: &str) -> Option<Self> { match s { $($raw => Some($name::$var),)* _ => None } }
        }
    };
}

raw_enum!(SceneKind {
    BlackHole = "blackHole", TidalDisruption = "tidalDisruption", Wormhole = "wormhole",
    Binary = "binary", Trinary = "trinary", Galaxy = "galaxy", Pulsar = "pulsar", Nebula = "nebula",
    PlanetaryNebula = "planetaryNebula", RingedPlanet = "ringedPlanet", AuroraOrbit = "auroraOrbit",
    LiveEarth = "liveEarth", GasGiant = "gasGiant", ProtoplanetaryDisk = "protoplanetaryDisk",
    NeutronMerger = "neutronMerger", BlackHoleMerger = "blackHoleMerger", DysonSwarm = "dysonSwarm",
    RoguePlanet = "roguePlanet", Eclipse = "eclipse", Quasar = "quasar", Comet = "comet",
    StellarSurface = "stellarSurface",
});

impl SceneKind {
    pub fn title(self) -> &'static str {
        use SceneKind::*;
        match self {
            BlackHole => "Black Hole",
            Wormhole => "Wormhole",
            Binary => "Binary Stars",
            Trinary => "Trinary Stars",
            Galaxy => "Galaxy",
            TidalDisruption => "Star Meets Black Hole",
            Pulsar => "Pulsar",
            Nebula => "Nebula",
            PlanetaryNebula => "Planetary Nebula",
            RingedPlanet => "Ringed Planet",
            AuroraOrbit => "Aurora from Orbit",
            LiveEarth => "Live Earth",
            GasGiant => "Gas Giant Storms",
            ProtoplanetaryDisk => "Protoplanetary Disk",
            NeutronMerger => "Neutron Star Merger",
            BlackHoleMerger => "Black Hole Merger",
            DysonSwarm => "Dyson Swarm",
            RoguePlanet => "Rogue Planet",
            Eclipse => "Eclipse",
            Comet => "Comet",
            StellarSurface => "Star Close-up",
            Quasar => "Quasar",
        }
    }

    /// The scene's case in the shaders. Fixed per scene, not the declaration order.
    pub fn shader_index(self) -> f32 {
        use SceneKind::*;
        match self {
            BlackHole => 0.0,
            Wormhole => 1.0,
            Binary => 2.0,
            Trinary => 3.0,
            Galaxy => 4.0,
            TidalDisruption => 5.0,
            Pulsar => 6.0,
            Nebula => 7.0,
            Comet => 8.0,
            StellarSurface => 9.0,
            PlanetaryNebula => 10.0,
            RingedPlanet => 11.0,
            AuroraOrbit => 12.0,
            LiveEarth => 21.0,
            GasGiant => 13.0,
            ProtoplanetaryDisk => 14.0,
            NeutronMerger => 15.0,
            BlackHoleMerger => 20.0,
            DysonSwarm => 17.0,
            RoguePlanet => 18.0,
            Eclipse => 19.0,
            Quasar => 16.0,
        }
    }

    /// Scenes offered in the Customize window; the nebula scene is parked.
    pub fn is_listed(self) -> bool {
        self != SceneKind::Nebula
    }

    pub fn listed() -> Vec<SceneKind> {
        Self::ALL.iter().copied().filter(|s| s.is_listed()).collect()
    }

    /// Glow added to the global bloom setting for scenes whose look leans on it. The eclipse
    /// takes most of it back so its bright inner corona doesn't glow across the moon's disk.
    pub fn extra_bloom(self) -> f64 {
        use SceneKind::*;
        match self {
            AuroraOrbit => 0.4,
            ProtoplanetaryDisk | DysonSwarm => 0.2,
            Eclipse => -0.22,
            _ => 0.0,
        }
    }

    /// Draws the real sky, from a camera held over a place on Earth, so the Sky section, the
    /// shared sky events and the camera tilt have nothing to act on.
    pub fn draws_real_sky(self) -> bool {
        self == SceneKind::LiveEarth
    }

    /// Scenes with a Tilt slider, which keep their own tilt. The galaxy, tidal disruption and
    /// quasar have viewing angles instead.
    pub fn has_tilt(self) -> bool {
        !self.draws_real_sky() && !matches!(self, SceneKind::Galaxy | SceneKind::TidalDisruption | SceneKind::Quasar)
    }

    /// The settings a per-scene reset puts back for other scenes too, for its help.
    pub fn shared_note(self) -> Option<&'static str> {
        use SceneKind::*;
        Some(match self {
            BlackHole => "Planets are shared with Wormhole, Binary Stars and Trinary Stars, disk colors and speed with Star Meets Black Hole, and the photon ring with Wormhole and Star Meets Black Hole. They reset there too.",
            TidalDisruption => "Disk colors and speed and the photon ring's color are shared with Black Hole, and that color with Wormhole. They reset there too.",
            Wormhole => "Planets are shared with Black Hole, Binary Stars and Trinary Stars, and the rim's glow and color are the photon ring's in Black Hole and Star Meets Black Hole. They reset there too.",
            Binary => "Planets are shared with Black Hole, Wormhole and Trinary Stars, and the separation and orbit period with Trinary Stars. They reset there too.",
            Trinary => "Planets are shared with Black Hole, Wormhole and Binary Stars, and the separation and orbit period with Binary Stars. They reset there too.",
            _ => return None,
        })
    }

    /// Scenes that show the orbiting planets.
    pub fn has_planets(self) -> bool {
        use SceneKind::*;
        matches!(self, BlackHole | Wormhole | Binary | Trinary)
    }

    /// Scenes the Windows port draws so far.
    pub fn is_ported(self) -> bool {
        use SceneKind::*;
        matches!(self, BlackHole | Wormhole | Binary | Trinary | GasGiant | PlanetaryNebula | RingedPlanet | Galaxy | Quasar
            | TidalDisruption | StellarSurface | Comet | Pulsar | NeutronMerger | BlackHoleMerger | Eclipse
            | ProtoplanetaryDisk | DysonSwarm | RoguePlanet | AuroraOrbit | LiveEarth)
    }

    /// How a scene bends light: 0 not at all, 1 black hole (with a shadow), 2 wormhole
    /// (Renderer.lensing).
    pub fn lensing(self) -> f32 {
        use SceneKind::*;
        match self {
            BlackHole | TidalDisruption => 1.0,
            Wormhole => 2.0,
            _ => 0.0,
        }
    }
}

raw_enum!(GalaxyType { Spiral = "spiral", Barred = "barred", Elliptical = "elliptical", Irregular = "irregular", Ring = "ring" });
impl GalaxyType {
    pub fn shader_index(self) -> f32 {
        match self {
            GalaxyType::Spiral => 0.0,
            GalaxyType::Barred => 1.0,
            GalaxyType::Elliptical => 2.0,
            GalaxyType::Irregular => 3.0,
            GalaxyType::Ring => 4.0,
        }
    }
}

raw_enum!(NebulaType { Pillars = "pillars", Dark = "dark", Emission = "emission", Planetary = "planetary", Remnant = "remnant" });
impl NebulaType {
    pub fn shader_index(self) -> f32 {
        match self {
            NebulaType::Emission => 0.0,
            NebulaType::Planetary => 1.0,
            NebulaType::Remnant => 2.0,
            NebulaType::Pillars => 3.0,
            NebulaType::Dark => 4.0,
        }
    }
}

raw_enum!(RingStyle { Classic = "classic", Broad = "broad", Narrow = "narrow", NoRings = "none" });
impl RingStyle {
    pub fn shader_index(self) -> f32 {
        match self {
            RingStyle::Classic => 0.0,
            RingStyle::Broad => 1.0,
            RingStyle::Narrow => 2.0,
            RingStyle::NoRings => 3.0,
        }
    }
}

raw_enum!(DitherPattern {
    Bayer8 = "bayer8", Bayer4 = "bayer4", Bayer2 = "bayer2", BlueNoise = "blueNoise",
    Halftone = "halftone", Lines = "lines", Noise = "noise", NoDither = "none",
});
impl DitherPattern {
    pub fn title(self) -> &'static str {
        match self {
            DitherPattern::Bayer8 => "Bayer 8\u{d7}8 (fine)",
            DitherPattern::Bayer4 => "Bayer 4\u{d7}4 (chunky)",
            DitherPattern::Bayer2 => "Bayer 2\u{d7}2 (coarse)",
            DitherPattern::BlueNoise => "Blue noise (organic)",
            DitherPattern::Halftone => "Halftone dots (print)",
            DitherPattern::Lines => "Diagonal lines (engraved)",
            DitherPattern::Noise => "White noise (grainy)",
            DitherPattern::NoDither => "None (posterized)",
        }
    }
    /// The pattern's case in the shader's `ditherAt`; fixed per pattern, not declaration order.
    pub fn shader_index(self) -> f32 {
        match self {
            DitherPattern::Bayer8 => 0.0,
            DitherPattern::Bayer4 => 1.0,
            DitherPattern::NoDither => 2.0,
            DitherPattern::Bayer2 => 3.0,
            DitherPattern::BlueNoise => 4.0,
            DitherPattern::Halftone => 5.0,
            DitherPattern::Lines => 6.0,
            DitherPattern::Noise => 7.0,
        }
    }
}

raw_enum!(Frequency { Off = "off", Rare = "rare", Normal = "normal", Often = "often" });
impl Frequency {
    /// Events per unit time relative to normal.
    pub fn rate(self) -> f64 {
        match self {
            Frequency::Off => 0.0,
            Frequency::Rare => 0.4,
            Frequency::Normal => 1.0,
            Frequency::Often => 2.5,
        }
    }
}

raw_enum!(ProtoDiskLook { Scattered = "scattered", Blend = "blend", Alma = "alma" });
impl ProtoDiskLook {
    pub fn weights(self) -> [f32; 3] {
        match self {
            ProtoDiskLook::Scattered => [1.0, 1.0, 0.1],
            ProtoDiskLook::Blend => [0.015, 0.5, 0.8],
            ProtoDiskLook::Alma => [0.02, 0.06, 1.2],
        }
    }
}

raw_enum!(EclipseMotion { Cycle = "cycle", Hold = "hold" });
raw_enum!(EclipseWorld { Rock = "rock", Ice = "ice", Desert = "desert", Basalt = "basalt" });
raw_enum!(EclipseSkyBody {
    TealGiant = "tealGiant", BandedGiant = "bandedGiant", RingedGiant = "ringedGiant",
    IceGiant = "iceGiant", RockyMoon = "rockyMoon", NoBody = "none",
});
raw_enum!(BlackHoleMergerModel { Stellar = "stellar", AgnDisk = "agnDisk", Intermediate = "intermediate", Supermassive = "supermassive" });
raw_enum!(TdeDiskColors { Palette = "palette", Fiery = "fiery", BlueWhite = "blueWhite" });
raw_enum!(PulsarBeams { Both = "both", Top = "top", Bottom = "bottom", NoBeams = "none" });
raw_enum!(PulsarFieldStyle { Lines = "lines", Magnetar = "magnetar" });

raw_enum!(StarType {
    RedDwarf = "redDwarf", OrangeDwarf = "orangeDwarf", Yellow = "yellow", White = "white",
    BlueGiant = "blueGiant", RedGiant = "redGiant", WhiteDwarf = "whiteDwarf", NeutronStar = "neutronStar",
});

impl StarType {
    pub fn temperature(self) -> f64 {
        use StarType::*;
        match self {
            RedDwarf => 3100.0,
            OrangeDwarf => 4400.0,
            Yellow => 5800.0,
            White => 8500.0,
            BlueGiant => 18000.0,
            RedGiant => 3500.0,
            WhiteDwarf => 14000.0,
            NeutronStar => 40000.0,
        }
    }
    /// Radius in scene units (Schwarzschild radii of the black hole scene).
    pub fn radius(self) -> f64 {
        use StarType::*;
        match self {
            RedDwarf => 0.55,
            OrangeDwarf => 0.8,
            Yellow => 1.0,
            White => 1.2,
            BlueGiant => 1.8,
            RedGiant => 2.5,
            WhiteDwarf => 0.28,
            NeutronStar => 0.14,
        }
    }
    pub fn mass(self) -> f64 {
        use StarType::*;
        match self {
            RedDwarf => 0.3,
            OrangeDwarf => 0.7,
            Yellow => 1.0,
            White => 1.8,
            BlueGiant => 8.0,
            RedGiant => 1.2,
            WhiteDwarf => 0.9,
            NeutronStar => 1.4,
        }
    }
    /// Corona size relative to radius; compact stars glow far beyond their tiny disks.
    pub fn glow(self) -> f64 {
        match self {
            StarType::WhiteDwarf => 3.0,
            StarType::NeutronStar => 5.0,
            StarType::BlueGiant => 1.4,
            _ => 1.0,
        }
    }
    /// Sunspot coverage.
    pub fn activity(self) -> f64 {
        match self {
            StarType::RedDwarf | StarType::OrangeDwarf | StarType::RedGiant => 0.8,
            StarType::Yellow => 0.4,
            _ => 0.0,
        }
    }

    /// Approximate blackbody color (Tanner Helland's fit), pushed toward saturation for the art
    /// style. Double math, rounded to Float at the end, as in Swift.
    pub fn color(self) -> Rgb {
        let t = self.temperature() / 100.0;
        let (r, g, b);
        if t <= 66.0 {
            r = 255.0;
            g = 99.4708025861 * t.ln() - 161.1195681661;
            b = if t <= 19.0 { 0.0 } else { 138.5177312231 * (t - 10.0).ln() - 305.0447927307 };
        } else {
            r = 329.698727446 * (t - 60.0).powf(-0.1332047592);
            g = 288.1221695283 * (t - 60.0).powf(-0.0755148492);
            b = 255.0;
        }
        fn c(v: f64) -> f64 {
            v.max(0.0).min(255.0) / 255.0
        }
        let mut v = [c(r), c(g), c(b)];
        let luma = v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722;
        v = v.map(|x| (luma + (x - luma) * 2.2).max(0.0).min(1.0));
        rgb(v[0] as f32, v[1] as f32, v[2] as f32)
    }
}

/// Portrait framing for phone wallpapers (mobile export only; never set on the saved config).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PhoneFraming {
    /// > 1 moves in closer
    pub zoom: f64,
    /// moves the subject up (+) or down (-), as a fraction of the screen height
    pub shift: f64,
}

impl Default for PhoneFraming {
    fn default() -> Self {
        PhoneFraming { zoom: 1.0, shift: 0.0 }
    }
}

impl PhoneFraming {
    /// What Reset Framing sets in `scene`. The shift is hidden where the real sky is drawn, so it's
    /// kept there for the scenes that use it.
    pub fn reset(&self, scene: SceneKind) -> PhoneFraming {
        PhoneFraming { zoom: 1.0, shift: if scene.draws_real_sky() { self.shift } else { 0.0 } }
    }

    /// Per scene: the frame's horizontal half extent, where the subject's center sits (v in
    /// [-1, 1], up positive), and the horizontal aim.
    pub fn layout(scene: SceneKind) -> (f64, f64, f64) {
        use SceneKind::*;
        match scene {
            BlackHole => (0.36, -0.2, 0.0),
            TidalDisruption => (0.68, -0.18, -9.0),
            Wormhole => (0.38, -0.2, -2.0),
            Binary => (0.24, -0.2, 0.0),
            Trinary => (0.3, -0.2, 0.0),
            Galaxy => (0.37, -0.22, 0.0),
            Pulsar => (0.3, -0.18, 0.0),
            Nebula => (0.5, -0.1, 0.0),
            PlanetaryNebula => (0.3, -0.15, 0.0),
            RingedPlanet => (0.32, -0.15, 0.0),
            AuroraOrbit => (0.35, -0.1, 0.0),
            LiveEarth => (0.3, 0.0, 0.0),
            GasGiant => (0.3, -0.1, 0.0),
            ProtoplanetaryDisk => (0.42, -0.1, 0.0),
            NeutronMerger => (0.3, -0.12, 0.0),
            BlackHoleMerger => (0.32, -0.1, 0.0),
            DysonSwarm => (0.3, -0.1, 0.0),
            RoguePlanet => (0.3, -0.12, 0.0),
            Eclipse => (0.62, 0.0, 0.0),
            Comet => (0.8, -0.45, 0.0),
            StellarSurface => (1.3, -0.5, 0.0),
            Quasar => (0.34, -0.05, 0.0),
        }
    }
}

/// One scene's own image settings (Config/SceneCustomization.swift).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ImageSettings {
    pub saturation: f64,
    pub brightness: f64,
    pub contrast: f64,
    pub black_point: f64,
    pub highlights: f64,
    pub vignette: f64,
    pub bloom: f64,
    pub bloom_radius: f64,
    pub bloom_threshold: f64,
    pub pixel_size: i64,
    pub levels: i64,
    pub dither: DitherPattern,
}

impl Default for ImageSettings {
    fn default() -> Self {
        ImageSettings::of(&WallpaperConfig::default())
    }
}

impl ImageSettings {
    pub fn of(c: &WallpaperConfig) -> Self {
        ImageSettings {
            saturation: c.saturation, brightness: c.brightness, contrast: c.contrast,
            black_point: c.black_point, highlights: c.highlights, vignette: c.vignette,
            bloom: c.bloom, bloom_radius: c.bloom_radius, bloom_threshold: c.bloom_threshold,
            pixel_size: c.pixel_size, levels: c.levels, dither: c.dither,
        }
    }

    /// Clamped the way the active scene's image settings are.
    pub fn sanitized(&self) -> ImageSettings {
        let mut c = WallpaperConfig::default();
        c.set_image(*self);
        ImageSettings::of(&c.sanitized())
    }
}

pub const DEFAULT_TILT: f64 = 6.3;
/// Above the refresh rate of any display (FrameRate.swift); the wallpaper never draws faster
/// than its display, so a higher rate runs at the display's maximum.
pub const FPS_LIMIT: i64 = 1000;
pub const STANDARD_FPS: [i64; 4] = [12, 24, 30, 60];
pub const PIXEL_SIZES: [i64; 6] = [1, 2, 3, 4, 6, 8];

/// Wrapped, because going around keeps the same place (200 is -160) and clamping would move it.
/// Adding 0 turns -0 into 0. Matches Swift's `remainder(dividingBy:)`, which rounds to nearest.
pub fn kept_longitude(x: f64) -> f64 {
    if x.abs() <= 180.0 {
        x
    } else {
        x - 360.0 * (x / 360.0).round_ties_even() + 0.0
    }
}

/// Declares the config struct and its Default from one list, so each default is written once.
macro_rules! config_struct {
    ($($(#[$m:meta])* $field:ident : $ty:ty = $def:expr),* $(,)?) => {
        #[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
        #[serde(default, rename_all = "camelCase")]
        pub struct WallpaperConfig { $($(#[$m])* pub $field: $ty),* }
        impl Default for WallpaperConfig {
            fn default() -> Self { WallpaperConfig { $($field: $def),* } }
        }
    };
}

config_struct! {
    /// Set it with `set_scene` to swap in the scene's own image settings like the Swift didSet.
    scene: SceneKind = SceneKind::BlackHole,

    // Look
    pixel_size: i64 = 3,
    levels: i64 = 5,
    dither: DitherPattern = DitherPattern::Bayer8,
    fps: i64 = 24,
    saturation: f64 = 1.35,
    /// the exposure: scales the scene's light before tone mapping
    brightness: f64 = 1.15,
    palette: PaletteConfig = PaletteConfig::gargantua(),

    // Image, applied to the scene's light before tone mapping and dithering
    contrast: f64 = 1.0,
    black_point: f64 = 0.0,
    /// highlight rolloff: compresses the brightest light
    highlights: f64 = 0.0,
    vignette: f64 = 0.0,
    /// glow amount; 0 skips the bloom passes entirely
    bloom: f64 = 0.3,
    /// fraction of the frame's shorter side
    bloom_radius: f64 = 0.03,
    /// tone-mapped brightness where the glow starts
    bloom_threshold: f64 = 0.5,

    scene_image: BTreeMap<String, ImageSettings> = BTreeMap::new(),
    #[serde(skip_serializing_if = "Option::is_none")]
    shared_image: Option<ImageSettings> = None,

    lock_screen_still: bool = false,
    lock_screen_smooth: bool = false,

    // Camera
    /// The active scene's, in degrees above the disk / orbital plane. A scene that doesn't use it
    /// holds `shared_tilt` here.
    tilt: f64 = DEFAULT_TILT,
    /// Tilts of the other scenes, by scene raw value, where they differ from `shared_tilt`. The
    /// active scene's is only ever in `tilt`, so there's no second copy to go stale.
    scene_tilt: BTreeMap<String, f64> = BTreeMap::new(),
    /// The tilt of every scene without one in `scene_tilt`. A save without this key is from when
    /// all scenes shared `tilt`, and loads with it as this.
    shared_tilt: f64 = DEFAULT_TILT,
    #[serde(skip_serializing_if = "Option::is_none")]
    phone_framing: Option<PhoneFraming> = None,

    // Black hole
    /// outer radius
    disk_size: f64 = 15.0,
    disk_speed: f64 = 1.0,
    photon_ring: f64 = 1.0,

    // Wormhole
    throat: f64 = 3.5,

    // Star systems
    binary_stars: Vec<StarType> = vec![StarType::Yellow, StarType::RedDwarf],
    trinary_stars: Vec<StarType> = vec![StarType::BlueGiant, StarType::WhiteDwarf, StarType::RedDwarf],
    star_orbit_minutes: f64 = 3.0,
    star_separation: f64 = 6.0,

    // Galaxy
    galaxy_type: GalaxyType = GalaxyType::Spiral,
    galaxy_arms: i64 = 2,
    galaxy_pitch: f64 = 14.0,
    galaxy_view: f64 = 32.0,
    galaxy_rotation_minutes: f64 = 6.0,
    dark_matter: bool = true,
    galaxy_size: f64 = 1.0,

    // Star meets black hole
    tde_cycle_minutes: f64 = 4.0,
    tde_star: StarType = StarType::BlueGiant,
    tde_view: f64 = 14.0,
    tde_star_size: f64 = 1.0,
    tde_star_distance: f64 = 20.0,
    tde_stream_brightness: f64 = 1.0,
    tde_disk_colors: TdeDiskColors = TdeDiskColors::Palette,
    tde_jets: bool = true,
    tde_jet_color: Rgb = Tuned::TdeJet.color(),

    // Pulsar
    pulsar_period: f64 = 3.0,
    pulsar_inclination: f64 = 52.0,
    pulsar_axis_tilt: f64 = 25.0,
    pulsar_beam_width: f64 = 7.0,
    pulsar_beam_color: Rgb = Tuned::PulsarBeam.color(),
    pulsar_nebula_color: Rgb = Tuned::PulsarNebula.color(),
    pulsar_nebula: bool = true,
    pulsar_field_lines: bool = true,
    pulsar_beams: PulsarBeams = PulsarBeams::Both,
    pulsar_field_style: PulsarFieldStyle = PulsarFieldStyle::Lines,
    pulsar_ring: bool = false,
    pulsar_field_color: Rgb = Tuned::PulsarField.color(),
    pulsar_ring_color: Rgb = Tuned::PulsarRing.color(),
    pulsar_beam_intensity: f64 = 1.0,
    pulsar_field_intensity: f64 = 1.0,
    pulsar_ring_intensity: f64 = 1.0,
    pulsar_nebula_intensity: f64 = 1.0,
    pulsar_beam_trail: f64 = 1.0,

    // Nebula
    nebula_type: NebulaType = NebulaType::Pillars,
    nebula_seed: i64 = 1,
    nebula_flow: f64 = 1.0,
    nebula_ha: Rgb = rgb(1.0, 0.22, 0.35),
    #[serde(rename = "nebulaOIII")]
    nebula_oiii: Rgb = rgb(0.15, 0.85, 0.9),
    #[serde(rename = "nebulaSII")]
    nebula_sii: Rgb = rgb(1.0, 0.65, 0.2),

    // Planetary nebula
    planetary_size: f64 = 1.0,
    planetary_elongation: f64 = 1.4,
    planetary_view: f64 = 28.0,
    planetary_knots: f64 = 1.0,
    planetary_halo: bool = true,
    planetary_inner_color: Rgb = Tuned::PlanetaryInner.color(),
    planetary_rim_color: Rgb = Tuned::PlanetaryRim.color(),
    planetary_halo_color: Rgb = Tuned::PlanetaryHalo.color(),
    planetary_events: Frequency = Frequency::Normal,

    // Ringed planet
    ringed_size: f64 = 1.0,
    ringed_tilt: f64 = 16.0,
    ringed_roll: f64 = -14.0,
    ringed_sun: f64 = 60.0,
    ringed_sun_height: f64 = -10.0,
    ringed_bands: f64 = 1.0,
    ringed_turbulence: f64 = 1.0,
    ringed_wind: f64 = 1.0,
    ringed_ring_style: RingStyle = RingStyle::Classic,
    ringed_ring_width: f64 = 1.0,
    ringed_ring_density: f64 = 1.0,
    ringed_spokes: bool = true,
    ringed_moon_count: i64 = 2,
    ringed_moon_size: f64 = 1.0,
    ringed_moon_speed: f64 = 1.0,
    ringed_band_light: Rgb = Tuned::RingedBandLight.color(),
    ringed_band_dark: Rgb = Tuned::RingedBandDark.color(),
    ringed_ring_color: Rgb = Tuned::RingedRing.color(),
    ringed_events: Frequency = Frequency::Normal,

    // Aurora from orbit
    aurora_brightness: f64 = 1.0,
    aurora_activity: f64 = 0.6,
    aurora_distance: f64 = 33.0,
    aurora_oval_size: f64 = 20.0,
    aurora_green: Rgb = Tuned::AuroraGreen.color(),
    aurora_red: Rgb = Tuned::AuroraRed.color(),
    aurora_fringe: Rgb = Tuned::AuroraFringe.color(),
    aurora_city_lights: f64 = 1.0,
    aurora_city_color: Rgb = Tuned::AuroraCity.color(),
    aurora_clouds: f64 = 1.0,
    aurora_moonlight: f64 = 0.35,
    aurora_lightning: Frequency = Frequency::Normal,
    aurora_altitude: f64 = 640.0,
    aurora_horizon: f64 = 0.25,
    aurora_drift: f64 = 1.0,
    aurora_sunrise: f64 = 0.5,
    aurora_events: Frequency = Frequency::Normal,

    // Live Earth
    earth_distance: f64 = 4.2,
    earth_center_x: f64 = 0.0,
    earth_center_y: f64 = 0.0,
    earth_clouds: bool = true,
    earth_cloud_amount: f64 = 1.0,
    earth_aurora: bool = true,
    earth_aurora_brightness: f64 = 1.0,
    earth_aurora_speed: f64 = 0.5,
    earth_city_lights: f64 = 1.0,
    earth_moonlight: f64 = 1.0,
    earth_moon_size: f64 = 3.0,
    earth_atmosphere: f64 = 1.0,
    earth_stars: f64 = 1.0,
    earth_milky_way: f64 = 1.0,
    earth_planets: bool = true,
    earth_planet_size: f64 = 1.0,
    earth_planet_labels: bool = false,
    earth_hide_sun_at_night: bool = true,
    earth_marker: bool = false,
    earth_freeze_time: bool = false,
    /// seconds since 1970 (2026-06-21 00:00 UTC)
    earth_frozen_time: f64 = 1_782_000_000.0,

    home_latitude: f64 = 40.0,
    home_longitude: f64 = -30.0,
    home_from_device: bool = false,

    // Gas giant storms
    gas_wind: f64 = 1.0,
    gas_turbulence: f64 = 1.0,
    gas_storm_size: f64 = 1.0,
    /// from the planet's center, in planet radii
    gas_distance: f64 = 2.3,
    /// where the planet's center sits, in screen half-widths
    gas_center_x: f64 = -0.3,
    /// and half-heights
    gas_center_y: f64 = -0.55,
    /// spin axis lean, degrees
    gas_tilt: f64 = 12.0,
    /// degrees round from behind us; higher puts more of the planet in night
    gas_sun: f64 = 40.0,
    gas_moon: bool = true,
    gas_lightning: Frequency = Frequency::Normal,
    gas_zone: Rgb = Tuned::GasZone.color(),
    gas_belt: Rgb = Tuned::GasBelt.color(),
    gas_storm: Rgb = Tuned::GasStorm.color(),
    gas_events: Frequency = Frequency::Normal,

    // Protoplanetary disk
    proto_view: f64 = 52.0,
    proto_slant: f64 = -22.0,
    proto_size: f64 = 1.0,
    proto_gaps: i64 = 5,
    proto_gap_width: f64 = 1.0,
    proto_flaring: f64 = 1.0,
    proto_orbit_speed: f64 = 1.0,
    proto_jets: bool = true,
    proto_look: ProtoDiskLook = ProtoDiskLook::Blend,
    proto_dust_color: Rgb = Tuned::ProtoDust.color(),
    proto_gas_color: Rgb = Tuned::ProtoGas.color(),
    proto_star_color: Rgb = Tuned::ProtoStar.color(),
    proto_jet_color: Rgb = Tuned::ProtoJet.color(),
    proto_events: Frequency = Frequency::Normal,

    // Neutron star merger
    merger_cycle_minutes: f64 = 4.0,
    merger_view: f64 = 62.0,
    merger_brightness: f64 = 1.0,
    merger_glow: f64 = 1.0,
    merger_waves: f64 = 1.0,
    merger_jet: bool = true,
    merger_star_color: Rgb = Tuned::MergerStar.color(),
    merger_hot: Rgb = Tuned::MergerHot.color(),
    merger_cool: Rgb = Tuned::MergerCool.color(),

    // Black hole merger
    bbh_model: BlackHoleMergerModel = BlackHoleMergerModel::Stellar,
    bbh_mass_ratio: f64 = 0.86,
    bbh_spin: f64 = 0.69,
    bbh_precession: f64 = 0.15,
    bbh_view: f64 = 30.0,
    bbh_cycle_minutes: f64 = 4.0,
    bbh_speed: f64 = 1.0,
    bbh_ringdown: f64 = 3.0,
    bbh_waves: f64 = 1.0,
    bbh_lensing: f64 = 1.0,
    bbh_galaxy: bool = true,
    bbh_eccentric: bool = false,
    bbh_kick: f64 = 1.0,
    bbh_chain: bool = false,
    bbh_trace: bool = false,
    bbh_ring_color: Rgb = Tuned::BbhRing.color(),
    bbh_hot: Rgb = Tuned::BbhHot.color(),
    bbh_cool: Rgb = Tuned::BbhCool.color(),

    // Dyson swarm
    dyson_star: StarType = StarType::OrangeDwarf,
    dyson_density: f64 = 0.45,
    dyson_rings: i64 = 12,
    dyson_orbit_speed: f64 = 1.0,
    dyson_glint: f64 = 1.0,
    dyson_panel_a: Rgb = Tuned::DysonPanelA.color(),
    dyson_panel_b: Rgb = Tuned::DysonPanelB.color(),
    dyson_heat: Rgb = Tuned::DysonHeat.color(),
    dyson_events: Frequency = Frequency::Normal,

    // Rogue planet
    rogue_size: f64 = 1.0,
    rogue_center_x: f64 = 0.3,
    rogue_center_y: f64 = -0.12,
    rogue_spin: f64 = 1.0,
    rogue_aurora: f64 = 1.0,
    rogue_aurora_low: Rgb = Tuned::RogueAuroraLow.color(),
    rogue_aurora_high: Rgb = Tuned::RogueAuroraHigh.color(),
    rogue_rift: f64 = 1.0,
    rogue_rift_color: Rgb = Tuned::RogueRift.color(),
    rogue_milky_way: f64 = 1.0,
    rogue_moon: bool = true,
    rogue_events: Frequency = Frequency::Normal,

    // Eclipse
    eclipse_cycle_minutes: f64 = 4.0,
    eclipse_corona_size: f64 = 1.0,
    eclipse_corona_brightness: f64 = 1.0,
    eclipse_prominences: f64 = 1.0,
    eclipse_motion: EclipseMotion = EclipseMotion::Cycle,
    eclipse_landscape: bool = true,
    eclipse_world: EclipseWorld = EclipseWorld::Rock,
    eclipse_sky_body: EclipseSkyBody = EclipseSkyBody::TealGiant,
    eclipse_planet_size: f64 = 1.0,
    eclipse_planet_x: f64 = -0.6,
    eclipse_planet_y: f64 = -0.18,
    eclipse_atmosphere: bool = false,
    eclipse_air_color: Rgb = rgb(0.36, 0.6, 1.0),
    eclipse_air_density: f64 = 1.0,
    eclipse_air_haze: f64 = 0.15,
    eclipse_clouds: f64 = 0.5,
    eclipse_corona_color: Rgb = Tuned::EclipseCorona.color(),
    eclipse_prominence_color: Rgb = Tuned::EclipseProminence.color(),
    eclipse_ground_color: Rgb = Tuned::EclipseGround.color(),
    eclipse_planet_color: Rgb = Tuned::EclipsePlanet.color(),
    eclipse_events: Frequency = Frequency::Normal,

    // Comet
    comet_tail_length: f64 = 1.0,
    comet_activity: f64 = 1.0,
    comet_ion_color: Rgb = Tuned::CometIon.color(),
    comet_dust_color: Rgb = Tuned::CometDust.color(),
    comet_events: Frequency = Frequency::Normal,

    // Star close-up
    close_star: StarType = StarType::Yellow,
    star_spots: f64 = 1.0,
    star_flares: Frequency = Frequency::Normal,
    star_rotation: f64 = 1.0,
    star_zoom: f64 = 1.0,
    star_center_x: f64 = -0.15,
    star_limb_y: f64 = 0.12,

    // Quasar
    quasar_view: f64 = 66.0,
    quasar_jet_angle: f64 = 12.0,
    quasar_jet_length: f64 = 1.0,
    quasar_jet_brightness: f64 = 1.0,
    quasar_knot_speed: f64 = 1.0,
    quasar_galaxy: f64 = 1.0,
    quasar_jet_color: Rgb = Tuned::QuasarJet.color(),
    quasar_lobe_color: Rgb = Tuned::QuasarLobe.color(),
    quasar_events: Frequency = Frequency::Normal,

    // Sky
    star_density: f64 = 1.0,
    nebula: f64 = 1.0,
    galaxies: bool = true,
    milky_way: bool = false,
    /// 0 is the original sky; any other value turns it to a new one
    sky_seed: i64 = 0,

    // Planets
    planet_count: i64 = 3,
    planet_size: f64 = 1.0,
    planet_orbit_minutes: f64 = 40.0,
    planet_seed: i64 = 1,
    /// some giants get rings (around the black hole and wormhole)
    planet_rings: bool = true,

    // Events
    twinkles: Frequency = Frequency::Normal,
    /// how much a twinkling star brightens
    twinkle_brightness: f64 = 1.0,
    /// how fast twinkles come and go, and how fast they flicker
    twinkle_speed: f64 = 1.0,
    pulsars: bool = true,
    supernovae: Frequency = Frequency::Normal,
    comets: Frequency = Frequency::Normal,
    wormhole_events: Frequency = Frequency::Normal,
}

/// Anything that changes the precomputed ray lookups; other changes apply on the next frame.
/// Settings only one scene's bake reads are left at a fixed value for the other scenes.
#[derive(Clone, Debug, PartialEq)]
pub struct BakeKey {
    pub scene: SceneKind,
    pub tilt: f64,
    pub disk_size: f64,
    pub throat: f64,
    pub star_density: f64,
    pub galaxies: bool,
    pub milky_way: bool,
    pub sky_seed: i64,
    pub pixel_size: i64,
    pub nebula_type: NebulaType,
    pub nebula_seed: i64,
    /// star radius and distance (tidal disruption only)
    pub tde_star: [f64; 2],
    pub phone_framing: Option<PhoneFraming>,
}

pub const STAR_ZOOM_RANGE: (f64, f64) = (0.4, 4.0);
pub const EXPOSURE_RANGE: (f64, f64) = (0.3, 3.0);
pub const CONTRAST_RANGE: (f64, f64) = (0.5, 2.0);
pub const BLACK_POINT_RANGE: (f64, f64) = (0.0, 0.3);
pub const BLOOM_RANGE: (f64, f64) = (0.0, 3.0);
pub const BLOOM_RADIUS_RANGE: (f64, f64) = (0.005, 0.12);

impl WallpaperConfig {
    /// Camera elevation for the current scene; the galaxy and tidal disruption have their own, and
    /// scenes that don't offer a tilt stay at the default.
    pub fn camera_tilt(&self) -> f64 {
        match self.scene {
            SceneKind::Galaxy => self.galaxy_view,
            SceneKind::TidalDisruption => self.tde_view,
            s if s.has_tilt() => self.tilt,
            _ => DEFAULT_TILT,
        }
    }

    /// Called as `scene` changes: keeps the old scene's tilt, then brings in the new scene's.
    fn swap_tilt(&mut self, old: SceneKind) {
        if old.has_tilt() {
            self.scene_tilt.insert(old.raw().to_string(), self.tilt);
        }
        self.tilt = self.scene_tilt.get(self.scene.raw()).copied().unwrap_or(self.shared_tilt);
        self.normalize_tilts();
    }

    /// Drops parked tilts that mean nothing, so configs with the same tilts compare equal. Tilts
    /// of scenes this build doesn't know stay, for the version that does.
    pub fn normalize_tilts(&mut self) {
        let (shared, scene) = (self.shared_tilt, self.scene.raw());
        self.scene_tilt.retain(|name, v| {
            *v != shared && name != scene && SceneKind::from_raw(name).map_or(true, |k| k.has_tilt())
        });
        if !self.scene.has_tilt() {
            self.tilt = self.shared_tilt;
        }
    }

    pub fn bake_key(&self) -> BakeKey {
        let s = self.scene;
        BakeKey {
            scene: s,
            tilt: self.camera_tilt(),
            disk_size: if s == SceneKind::BlackHole { self.disk_size } else { 0.0 },
            throat: if s == SceneKind::Wormhole { self.throat } else { 0.0 },
            star_density: self.star_density,
            galaxies: self.galaxies,
            milky_way: self.milky_way,
            sky_seed: self.sky_seed,
            pixel_size: self.pixel_size,
            nebula_type: if s == SceneKind::Nebula { self.nebula_type } else { NebulaType::Pillars },
            nebula_seed: if s == SceneKind::Nebula { self.nebula_seed } else { 0 },
            tde_star: if s == SceneKind::TidalDisruption {
                [self.tde_star.radius() * self.tde_star_size, self.tde_star_distance]
            } else {
                [0.0, 0.0]
            },
            phone_framing: self.phone_framing,
        }
    }

    // MARK: per-scene image settings (SceneCustomization.swift)

    pub fn image(&self) -> ImageSettings {
        ImageSettings::of(self)
    }

    pub fn set_image(&mut self, v: ImageSettings) {
        self.saturation = v.saturation; self.brightness = v.brightness; self.contrast = v.contrast;
        self.black_point = v.black_point; self.highlights = v.highlights; self.vignette = v.vignette;
        self.bloom = v.bloom; self.bloom_radius = v.bloom_radius; self.bloom_threshold = v.bloom_threshold;
        self.pixel_size = v.pixel_size; self.levels = v.levels; self.dither = v.dither;
    }

    pub fn has_own_image(&self, kind: SceneKind) -> bool {
        self.scene_image.contains_key(kind.raw())
    }

    /// `sceneHasOwnImage`: turns the active scene's own image settings on, starting from the
    /// shared ones, or off, going back to the shared ones and forgetting its own.
    pub fn set_has_own_image(&mut self, on: bool) {
        let key = self.scene.raw().to_string();
        if on == self.has_own_image(self.scene) {
            return;
        }
        if on {
            let img = self.image();
            self.shared_image = Some(img);
            self.scene_image.insert(key, img);
        } else {
            if let Some(shared) = self.shared_image {
                self.set_image(shared);
            }
            self.scene_image.remove(&key);
            self.shared_image = None;
        }
    }

    /// Switches scenes the way the Swift `scene` didSet does: the old scene's own image settings
    /// and tilt are put back where they belong, then the new scene's come in.
    pub fn set_scene(&mut self, scene: SceneKind) {
        let old = self.scene;
        if scene == old {
            return;
        }
        self.scene = scene;
        self.swap_image(old);
        self.swap_tilt(old);
    }

    fn swap_image(&mut self, old: SceneKind) {
        let scene = self.scene;
        let shared = if self.has_own_image(old) {
            let img = self.image();
            self.scene_image.insert(old.raw().to_string(), img);
            self.shared_image.unwrap_or(img)
        } else {
            self.image()
        };
        if let Some(own) = self.scene_image.get(scene.raw()).copied() {
            self.shared_image = Some(shared);
            self.set_image(own);
        } else {
            self.shared_image = None;
            self.set_image(shared);
        }
    }

    // MARK: lenient decoding

    /// Decodes leniently like `WallpaperConfig.decode`: keys missing from older configs fall back
    /// to defaults (merged one level deep, so older palettes still load), and so does any single
    /// key that no longer decodes, instead of the whole config resetting. Then `sanitized`.
    pub fn decode(json: &str) -> Option<WallpaperConfig> {
        let saved: Value = serde_json::from_str(json).ok()?;
        let Value::Object(mut saved) = saved else { return None };
        let Value::Object(defaults) = serde_json::to_value(WallpaperConfig::default()).ok()? else { return None };
        migrate_tuned_colors(&mut saved);
        // from before scenes had their own tilts, when this was every scene's
        if !saved.get("sharedTilt").is_some_and(Value::is_number) {
            if let Some(t) = saved.get("tilt").cloned() {
                saved.insert("sharedTilt".into(), t);
            }
        }
        let saved_scene = saved.get("scene").and_then(Value::as_str).map(str::to_string);
        // a scene this build doesn't know loads as the default one, which has a tilt of its own
        let loaded = |c: WallpaperConfig| -> WallpaperConfig {
            let mut c = c;
            if let Some(name) = &saved_scene {
                if name != c.scene.raw() {
                    c.scene_tilt.insert(name.clone(), c.tilt);
                    c.tilt = c.scene_tilt.get(c.scene.raw()).copied().unwrap_or(c.shared_tilt);
                }
            }
            c.sanitized()
        };
        fn merging(key: &str, value: &Value, dict: &mut Map<String, Value>) {
            if let (Value::Object(nested), Some(Value::Object(base))) = (value, dict.get_mut(key)) {
                for (k, v) in nested {
                    base.insert(k.clone(), v.clone());
                }
            } else {
                dict.insert(key.to_string(), value.clone());
            }
        }
        fn decoded(dict: &Map<String, Value>) -> Option<WallpaperConfig> {
            serde_json::from_value(Value::Object(dict.clone())).ok()
        }
        let mut merged = defaults.clone();
        for (k, v) in &saved {
            merging(k, v, &mut merged);
        }
        if let Some(c) = decoded(&merged) {
            return Some(loaded(c));
        }
        // something in there is bad: keep each key only if the config still decodes with it
        merged = defaults;
        let mut keys: Vec<&String> = saved.keys().collect();
        keys.sort();
        for k in keys {
            let mut trial = merged.clone();
            merging(k, &saved[k], &mut trial);
            if decoded(&trial).is_some() {
                merged = trial;
            }
        }
        decoded(&merged).map(loaded)
    }

    /// Clamps values the renderer would choke on (zero periods, missing stars, a zero pixel size).
    pub fn sanitized(&self) -> WallpaperConfig {
        let d = WallpaperConfig::default();
        let mut c = self.clone();
        fn positive(v: &mut f64, d: f64, lo: f64) {
            if !(*v >= lo) {
                *v = if v.is_nan() { d } else { lo };
            }
        }
        fn clamp(v: &mut f64, d: f64, lo: f64, hi: f64) {
            *v = if v.is_nan() { d } else { v.max(lo).min(hi) };
        }
        c.pixel_size = c.pixel_size.clamp(1, 16);
        c.levels = c.levels.clamp(2, 256);
        c.fps = c.fps.clamp(1, FPS_LIMIT);
        c.planet_count = c.planet_count.clamp(0, 6);
        c.ringed_moon_count = c.ringed_moon_count.clamp(0, 3);
        c.proto_gaps = c.proto_gaps.clamp(1, 7);
        positive(&mut c.star_orbit_minutes, d.star_orbit_minutes, 0.05);
        positive(&mut c.planet_orbit_minutes, d.planet_orbit_minutes, 0.05);
        positive(&mut c.galaxy_rotation_minutes, d.galaxy_rotation_minutes, 0.05);
        positive(&mut c.tde_cycle_minutes, d.tde_cycle_minutes, 0.05);
        positive(&mut c.pulsar_period, d.pulsar_period, 0.05);
        positive(&mut c.nebula_flow, d.nebula_flow, 0.05);
        positive(&mut c.planet_size, d.planet_size, 0.05);
        positive(&mut c.galaxy_size, d.galaxy_size, 0.05);
        positive(&mut c.ringed_ring_width, d.ringed_ring_width, 0.05);
        positive(&mut c.ringed_bands, d.ringed_bands, 0.05);
        positive(&mut c.ringed_moon_speed, d.ringed_moon_speed, 0.05);
        positive(&mut c.merger_cycle_minutes, d.merger_cycle_minutes, 0.05);
        positive(&mut c.bbh_cycle_minutes, d.bbh_cycle_minutes, 0.05);
        if c.binary_stars.len() < 2 {
            let n = c.binary_stars.len();
            c.binary_stars.extend_from_slice(&d.binary_stars[n..]);
        }
        if c.trinary_stars.len() < 3 {
            let n = c.trinary_stars.len();
            c.trinary_stars.extend_from_slice(&d.trinary_stars[n..]);
        }
        if c.galaxy_arms < 1 {
            c.galaxy_arms = 1;
        }
        clamp(&mut c.star_zoom, d.star_zoom, STAR_ZOOM_RANGE.0, STAR_ZOOM_RANGE.1);
        clamp(&mut c.star_center_x, d.star_center_x, -1.0, 1.0);
        clamp(&mut c.star_limb_y, d.star_limb_y, -0.9, 1.0);
        clamp(&mut c.home_latitude, d.home_latitude, -90.0, 90.0);
        c.home_longitude = kept_longitude(c.home_longitude);
        clamp(&mut c.home_longitude, d.home_longitude, -180.0, 180.0); // only NaN is left
        clamp(&mut c.earth_distance, d.earth_distance, 1.3, 20.0);
        clamp(&mut c.brightness, d.brightness, EXPOSURE_RANGE.0, EXPOSURE_RANGE.1);
        clamp(&mut c.contrast, d.contrast, CONTRAST_RANGE.0, CONTRAST_RANGE.1);
        clamp(&mut c.black_point, d.black_point, BLACK_POINT_RANGE.0, BLACK_POINT_RANGE.1);
        clamp(&mut c.highlights, d.highlights, 0.0, 1.0);
        clamp(&mut c.vignette, d.vignette, 0.0, 1.0);
        clamp(&mut c.bloom, d.bloom, BLOOM_RANGE.0, BLOOM_RANGE.1);
        clamp(&mut c.bloom_radius, d.bloom_radius, BLOOM_RADIUS_RANGE.0, BLOOM_RADIUS_RANGE.1);
        clamp(&mut c.bloom_threshold, d.bloom_threshold, 0.0, 1.0);
        // the parked image settings become the flat ones on a scene switch, so they need it too
        for v in c.scene_image.values_mut() {
            *v = v.sanitized();
        }
        c.shared_image = c.shared_image.map(|v| v.sanitized());
        c.normalize_tilts();
        c
    }

    /// Puts the image controls back to their neutral defaults.
    pub fn reset_image(&mut self) {
        let d = WallpaperConfig::default();
        self.brightness = d.brightness; self.contrast = d.contrast; self.black_point = d.black_point;
        self.highlights = d.highlights; self.vignette = d.vignette; self.bloom = d.bloom;
        self.bloom_radius = d.bloom_radius; self.bloom_threshold = d.bloom_threshold;
        self.saturation = d.saturation;
    }
}

/// Settings saved before colors were picks hold the tuned shader light for any default or preset
/// color. Those become the matching picks, so they keep looking the same.
fn migrate_tuned_colors(saved: &mut Map<String, Value>) {
    fn read(v: Option<&Value>) -> Option<[f64; 3]> {
        let d = v?.as_object()?;
        Some([d.get("r")?.as_f64()?, d.get("g")?.as_f64()?, d.get("b")?.as_f64()?])
    }
    fn same(a: [f64; 3], c: Rgb) -> bool {
        let d = [(a[0] - c.r as f64).abs(), (a[1] - c.g as f64).abs(), (a[2] - c.b as f64).abs()];
        d[0].max(d[1]).max(d[2]) < 1e-5
    }
    fn dict(c: Rgb) -> Value {
        serde_json::json!({ "r": c.r as f64, "g": c.g as f64, "b": c.b as f64 })
    }
    for t in Tuned::ALL {
        if let Some(v) = read(saved.get(t.key())) {
            if same(v, t.light()) {
                saved.insert(t.key().to_string(), dict(t.color()));
            }
        }
    }
    let Some(Value::Object(palette)) = saved.get_mut("palette") else { return };
    let tuned = PaletteConfig::tuned_presets();
    for (name, lvl) in PALETTE_PICKED {
        let Some(v) = read(palette.get(name)) else { continue };
        let Some((_, preset)) = tuned.iter().find(|(_, p)| same(v, p.picked(name).unwrap())) else { continue };
        palette.insert(name.to_string(), dict(preset.picked(name).unwrap().as_pick(lvl)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_round_trip_uses_swift_keys() {
        let mut c = WallpaperConfig::default();
        c.scene = SceneKind::GasGiant;
        c.gas_center_x = 0.25;
        c.dither = DitherPattern::NoDither;
        c.binary_stars = vec![StarType::BlueGiant, StarType::NeutronStar];
        let json = serde_json::to_string(&c).unwrap();
        assert!(json.contains("\"scene\":\"gasGiant\""));
        assert!(json.contains("\"gasCenterX\":0.25"));
        assert!(json.contains("\"dither\":\"none\""));
        assert!(json.contains("\"binaryStars\":[\"blueGiant\",\"neutronStar\"]"));
        assert!(json.contains("\"nebulaOIII\""));
        assert!(json.contains("\"pixelSize\":3"));
        assert!(!json.contains("phoneFraming"));
        let back: WallpaperConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn decode_is_lenient() {
        // missing keys take defaults, unknown keys are ignored, a bad value falls back alone
        let c = WallpaperConfig::decode(
            r#"{"scene":"binary","tilt":9,"futureKey":1,"dither":"sparkles","palette":{"ring":{"r":1,"g":0,"b":0}}}"#,
        )
        .unwrap();
        assert_eq!(c.scene, SceneKind::Binary);
        assert_eq!(c.tilt, 9.0);
        assert_eq!(c.dither, DitherPattern::Bayer8);
        assert_eq!(c.palette.ring, rgb(1.0, 0.0, 0.0));
        assert_eq!(c.palette.receding, PaletteConfig::gargantua().receding);
        assert_eq!(c.levels, 5);
    }

    #[test]
    fn tilt_check() {
        // after TiltCheck.swift: each scene keeps its own tilt, through scene switches and saves
        let all = SceneKind::ALL;
        let tilted: Vec<SceneKind> = all.iter().copied().filter(|k| k.has_tilt()).collect();
        let shown = |c: &WallpaperConfig, k: SceneKind| { let mut c = c.clone(); c.set_scene(k); c.camera_tilt() };
        let shown_all = |c: &WallpaperConfig| all.iter().map(|&k| shown(c, k)).collect::<Vec<_>>();
        let distinct = |c: &WallpaperConfig, active: SceneKind| {
            let mut c = c.clone();
            for (i, &k) in tilted.iter().enumerate() {
                c.set_scene(k);
                c.tilt = 2.0 + i as f64;
            }
            c.set_scene(active);
            c
        };
        let saved = |c: &WallpaperConfig| WallpaperConfig::decode(&serde_json::to_string(c).unwrap()).unwrap();
        let old_save = |scene: SceneKind, tilt: f64| {
            let Value::Object(mut d) = serde_json::to_value(WallpaperConfig::default()).unwrap() else { unreachable!() };
            d.remove("sceneTilt");
            d.remove("sharedTilt");
            d.insert("scene".into(), scene.raw().into());
            d.insert("tilt".into(), tilt.into());
            d
        };
        let load = |d: &Map<String, Value>| WallpaperConfig::decode(&Value::Object(d.clone()).to_string()).unwrap();
        let d = WallpaperConfig::default();

        // scenes without a tilt draw the same whatever is set, even set directly
        for &k in all.iter().filter(|k| !k.has_tilt()) {
            let (mut c, mut t) = (d.clone(), d.clone());
            c.set_scene(k);
            t.set_scene(k);
            t.tilt = 20.0;
            assert_eq!(t.bake_key(), c.bake_key(), "a tilt moved {k:?}");
        }
        // a tilt is its scene's only, and comes back with it by any order of visits
        for &k in &tilted {
            for &start in all {
                let mut c = distinct(&d, start);
                let mut want = shown_all(&c);
                c.set_scene(k);
                c.tilt = 24.5;
                want[all.iter().position(|&x| x == k).unwrap()] = 24.5;
                assert_eq!(shown_all(&c), want, "tilting {k:?} from {start:?} changed another scene");
            }
        }
        for &start in all {
            for c in [d.clone(), distinct(&d, start)] {
                let mut v = c.clone();
                v.set_scene(start);
                let home = v.clone();
                for &k in all.iter().chain(all.iter().rev()) {
                    v.set_scene(k);
                }
                v.set_scene(start);
                assert_eq!(v, home, "visiting every scene and coming back to {start:?} changed the settings");
            }
        }
        // setting a tilt back leaves nothing behind that makes equal settings unequal
        let mut there = d.clone();
        there.set_scene(SceneKind::Comet);
        there.tilt = 20.0;
        there.set_scene(SceneKind::Eclipse);
        there.set_scene(SceneKind::Comet);
        there.tilt = DEFAULT_TILT;
        there.set_scene(d.scene);
        assert_eq!(there, d, "a tilt set and put back still reads as a change");
        // upgrade: one shared tilt becomes every scene's, whichever scene is active
        for &active in all {
            for tilt in [DEFAULT_TILT, 20.0, 1.0 / 3.0, 40.0] {
                let c = load(&old_save(active, tilt));
                for &k in all {
                    let mut old = d.clone();
                    old.set_scene(k);
                    let want = if k.has_tilt() { tilt } else { old.camera_tilt() };
                    assert_eq!(shown(&c, k), want, "old save on {active:?} at {tilt}: {k:?}");
                }
                assert!(c.scene == active && c.tilt == tilt, "old save on {active:?} at {tilt}: an older version would lose it");
                let mut again = c.clone();
                for _ in 0..3 {
                    again = saved(&again);
                    assert_eq!(again, c, "old save on {active:?} at {tilt}: saving and loading changed it");
                }
                again.set_scene(SceneKind::Comet);
                again.tilt = 11.0;
                again = saved(&again);
                assert!(tilted.iter().all(|&k| shown(&again, k) == if k == SceneKind::Comet { 11.0 } else { tilt }));
            }
        }
        let partial = WallpaperConfig::decode(r#"{"tilt": 20}"#).unwrap();
        assert!(tilted.iter().all(|&k| shown(&partial, k) == 20.0), "a file with only a tilt");
        assert_eq!(WallpaperConfig::decode("{}").unwrap(), d, "an empty save");
        for &active in all {
            let c = distinct(&load(&old_save(SceneKind::Galaxy, 20.0)), active);
            assert!(saved(&c) == c && shown_all(&saved(&c)) == shown_all(&c), "{active:?}: tilts didn't round trip");
        }
        // damaged and hand-edited saves
        let Value::Object(mut stale) = serde_json::to_value(&there).unwrap() else { unreachable!() };
        stale.insert("sceneTilt".into(), serde_json::json!({"blackHole": 9, "quasar": 20, "eclipse": DEFAULT_TILT}));
        assert_eq!(load(&stale), d, "meaningless parked tilts made equal settings unequal");
        let mut bad = old_save(SceneKind::Comet, 20.0);
        bad.insert("sharedTilt".into(), "high".into());
        bad.insert("sceneTilt".into(), 3.into());
        let c = load(&bad);
        assert!(tilted.iter().all(|&k| shown(&c, k) == 20.0), "damaged tilts lost the one that loads");
        // a newer version's scene loads as the default scene with that scene's own tilt
        let before = distinct(&d, SceneKind::Comet);
        let Value::Object(mut newer) = serde_json::to_value(&before).unwrap() else { unreachable!() };
        let comet_tilt = newer["tilt"].clone();
        newer.insert("scene".into(), "aNewerScene".into());
        newer["sceneTilt"].as_object_mut().unwrap().insert("comet".into(), comet_tilt);
        newer.insert("tilt".into(), 24.5.into());
        let c = load(&newer);
        assert!(shown_all(&c) == shown_all(&before) && c.scene_tilt.get("aNewerScene") == Some(&24.5), "a newer version's scene disturbed the tilts");
        assert_eq!(saved(&c), c, "a newer version's scene isn't stable");
    }

    #[test]
    fn scenes_keep_their_own_tilt() {
        let mut c = WallpaperConfig::default();
        c.tilt = 20.0;
        c.set_scene(SceneKind::GasGiant);
        assert_eq!(c.tilt, DEFAULT_TILT);
        c.tilt = 3.0;
        // the galaxy has no tilt: it holds the shared one, and leaving it parks nothing
        c.set_scene(SceneKind::Galaxy);
        assert_eq!(c.tilt, DEFAULT_TILT);
        c.set_scene(SceneKind::BlackHole);
        assert_eq!(c.tilt, 20.0);
        assert_eq!(c.scene_tilt.get("gasGiant"), Some(&3.0));
        assert!(!c.scene_tilt.contains_key("blackHole") && !c.scene_tilt.contains_key("galaxy"));
    }

    #[test]
    fn old_saves_share_their_tilt() {
        let c = WallpaperConfig::decode(r#"{"scene":"binary","tilt":9}"#).unwrap();
        assert_eq!((c.tilt, c.shared_tilt), (9.0, 9.0));
        // an unknown scene loads as the default one, and its tilt is parked for it
        let c = WallpaperConfig::decode(r#"{"scene":"futureScene","tilt":12,"sharedTilt":5}"#).unwrap();
        assert_eq!(c.scene, SceneKind::BlackHole);
        assert_eq!((c.tilt, c.scene_tilt.get("futureScene")), (5.0, Some(&12.0)));
    }

    #[test]
    fn longitudes_wrap() {
        assert_eq!(kept_longitude(200.0), -160.0);
        assert_eq!(kept_longitude(-190.0), 170.0);
        assert_eq!(kept_longitude(540.0), -180.0); // a tie rounds to even, as in Swift
        assert_eq!(kept_longitude(12.5), 12.5);
    }

    #[test]
    fn scene_raw_values() {
        assert_eq!(SceneKind::ALL.len(), 22);
        assert_eq!(serde_json::to_string(&SceneKind::BlackHole).unwrap(), "\"blackHole\"");
        assert_eq!(SceneKind::from_raw("gasGiant"), Some(SceneKind::GasGiant));
        assert_eq!(SceneKind::GasGiant.shader_index(), 13.0);
    }
}
