//! The welcome guide's example looks (`Tweak` in WelcomeView.swift): each a name, what it does,
//! and how to turn it on and back off. Off puts the fields it touches back to what they were when
//! the guide opened, so trying one never loses a setting made before.

use crate::config::{DitherPattern, Frequency, SceneKind, WallpaperConfig};

pub struct Tweak {
    pub id: &'static str,
    pub title: &'static str,
    pub detail: &'static str,
    pub is_on: fn(&WallpaperConfig) -> bool,
    pub apply: fn(&mut WallpaperConfig),
    /// copies the fields it touches from the second config into the first
    pub restore: fn(&mut WallpaperConfig, &WallpaperConfig),
    /// changes only the shared sky, which scenes that draw the real sky don't show
    pub sky_only: bool,
}

pub static ALL: [Tweak; 7] = [
    Tweak {
        id: "chunky", title: "Chunkier pixels", detail: "Twice the pixel size, more retro",
        is_on: |c| c.pixel_size >= 5,
        apply: |c| c.pixel_size = 6,
        restore: |c, b| c.pixel_size = b.pixel_size,
        sky_only: false,
    },
    Tweak {
        id: "smooth", title: "Smooth", detail: "Full resolution and many more colors",
        is_on: |c| c.pixel_size == 1 && c.levels >= 32,
        apply: |c| { c.pixel_size = 1; c.levels = 64; },
        restore: |c, b| { c.pixel_size = b.pixel_size; c.levels = b.levels; },
        sky_only: false,
    },
    Tweak {
        id: "retro", title: "Coarse dither", detail: "A 4\u{d7}4 pattern and only three shades per color",
        is_on: |c| c.dither == DitherPattern::Bayer4 && c.levels <= 3,
        apply: |c| { c.dither = DitherPattern::Bayer4; c.levels = 3; },
        restore: |c, b| { c.dither = b.dither; c.levels = b.levels; },
        sky_only: false,
    },
    Tweak {
        id: "glow", title: "Glow", detail: "Bright parts bloom into the dark",
        is_on: |c| c.bloom >= 0.9,
        apply: |c| c.bloom = 1.2,
        restore: |c, b| c.bloom = b.bloom,
        sky_only: false,
    },
    Tweak {
        id: "vivid", title: "Vivid", detail: "Stronger color and a little more light",
        is_on: |c| c.saturation >= 1.7,
        apply: |c| { c.saturation = 1.8; c.brightness = 1.35; },
        restore: |c, b| { c.saturation = b.saturation; c.brightness = b.brightness; },
        sky_only: false,
    },
    Tweak {
        id: "moody", title: "Moody", detail: "More contrast and darker corners",
        is_on: |c| c.vignette >= 0.4,
        apply: |c| { c.contrast = 1.3; c.vignette = 0.55; },
        restore: |c, b| { c.contrast = b.contrast; c.vignette = b.vignette; },
        sky_only: false,
    },
    Tweak {
        id: "busy", title: "Busier sky", detail: "Supernovae, comets and twinkles more often",
        is_on: |c| c.supernovae == Frequency::Often,
        apply: |c| { c.supernovae = Frequency::Often; c.comets = Frequency::Often; c.twinkles = Frequency::Often; },
        restore: |c, b| { c.supernovae = b.supernovae; c.comets = b.comets; c.twinkles = b.twinkles; },
        sky_only: true,
    },
];

/// The tweaks that show in `scene`. Undo All covers the rest too, so one turned on in another
/// scene isn't stuck on.
pub fn offered(scene: SceneKind) -> Vec<&'static Tweak> {
    ALL.iter().filter(|t| !(t.sky_only && scene.draws_real_sky())).collect()
}

/// `base`, with the image settings it has for `c`'s scene in place: a scene with its own image
/// settings undoes to those, not to the shared ones.
fn base_for(base: &WallpaperConfig, c: &WallpaperConfig) -> WallpaperConfig {
    let mut b = base.clone();
    b.set_scene(c.scene);
    b
}

impl Tweak {
    /// Puts its fields back to `base`'s, or to the defaults when `base` had the tweak on already.
    pub fn turn_off(&self, c: &mut WallpaperConfig, base: &WallpaperConfig) {
        let b = base_for(base, c);
        if (self.is_on)(&b) {
            (self.restore)(c, &WallpaperConfig::default());
        } else {
            (self.restore)(c, &b);
        }
    }

    /// On turns off, off turns on.
    pub fn toggle(&self, c: &mut WallpaperConfig, base: &WallpaperConfig) {
        if (self.is_on)(c) {
            self.turn_off(c, base);
        } else {
            (self.apply)(c);
        }
    }
}

pub fn undoing_all(c: &WallpaperConfig, base: &WallpaperConfig) -> WallpaperConfig {
    let b = base_for(base, c);
    let mut c = c.clone();
    for t in &ALL {
        (t.restore)(&mut c, &b);
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    /// CustomizationCheck's welcome-guide section.
    #[test]
    fn tweaks_undo_to_the_earlier_settings() {
        let d = WallpaperConfig::default();
        let mut base = d.clone();
        base.pixel_size = 2;
        base.bloom = 0.6;
        base.supernovae = Frequency::Rare;
        base.set_scene(SceneKind::Comet);
        base.set_has_own_image(true);
        base.bloom = 0.1;
        base.set_scene(SceneKind::BlackHole);
        for scene in [SceneKind::BlackHole, SceneKind::Comet] {
            let mut start = base.clone();
            start.set_scene(scene);
            assert!(undoing_all(&start, &base) == start, "Undo All changed settings nothing had tweaked");
            for t in &ALL {
                let mut c = start.clone();
                (t.apply)(&mut c);
                t.turn_off(&mut c, &base);
                assert!(c == start, "{} didn't undo to the earlier settings", t.id);
            }
            let mut all = start.clone();
            ALL.iter().for_each(|t| (t.apply)(&mut all));
            assert!(undoing_all(&all, &base) == start, "Undo All didn't restore the earlier settings");
        }
        let mut bright = d.clone();
        bright.bloom = 1.5;
        let mut off = bright.clone();
        ALL.iter().find(|t| t.id == "glow").unwrap().turn_off(&mut off, &bright);
        assert_eq!(off.bloom, d.bloom, "a tweak already on at the start couldn't be turned off");

        // a scene that draws the real sky leaves out Busier sky; Undo All there still undoes it,
        // and another scene shows whether it's on
        for &scene in SceneKind::all() {
            let hidden: Vec<_> = ALL.iter().map(|t| t.id).filter(|id| !offered(scene).iter().any(|t| t.id == *id)).collect();
            let want: Vec<&str> = if scene.draws_real_sky() { vec!["busy"] } else { vec![] };
            assert_eq!(hidden, want, "tweaks left out in {scene:?}");
        }
        let busy = ALL.iter().find(|t| t.id == "busy").unwrap();
        let mut sky = base.clone();
        (busy.apply)(&mut sky);
        sky.set_scene(SceneKind::LiveEarth);
        let mut undone = undoing_all(&sky, &base);
        assert!(undone != sky, "Undo All had nothing to undo in Live Earth");
        sky.set_scene(base.scene);
        undone.set_scene(base.scene);
        assert!((busy.is_on)(&sky) && undone == base, "Busier sky was stuck after Live Earth");
    }
}
