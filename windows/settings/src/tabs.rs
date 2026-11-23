//! The inspector's sections: Scene (SceneTab.swift with SceneColors and PlanetsGroup), Sky
//! (SkyTab.swift), Image (ImageTab.swift) and System (the parts of SystemTab.swift that apply
//! on Windows, plus start at login and the settings folder).

use std::rc::Rc;
use std::time::{Duration, Instant};

use deepfield::config::*;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::app::Settings;
use crate::controls::*;
use crate::model::*;
use crate::slider;
use crate::system;
use crate::theme;

type Rows = Vec<AnyElement>;

/// A Swatch for a color preset.
fn preset_swatches(c: &WallpaperConfig) -> Vec<Swatch> {
    color_presets(c.scene)
        .into_iter()
        .map(|p| {
            let selected = p.matches(c);
            let colors = p.swatches();
            let name = p.name;
            let p = Rc::new(p);
            Swatch { name, colors, selected, apply: Rc::new(move |c: &mut WallpaperConfig| p.apply(c)) }
        })
        .collect()
}

fn palette_swatches(c: &WallpaperConfig) -> Vec<Swatch> {
    palette_presets(&c.palette)
        .into_iter()
        .map(|(name, palette, colors)| Swatch {
            name,
            colors,
            selected: c.palette == palette,
            apply: Rc::new(move |c: &mut WallpaperConfig| c.palette = palette),
        })
        .collect()
}

macro_rules! color {
    ($s:ident, $w:ident, $cx:ident, $title:expr, $($field:ident).+) => {
        $s.color_row(concat!($(stringify!($field), "."),+), $title, $s.config().$($field).+,
                     |c, v| c.$($field).+ = v, $w, $cx)
    };
}

macro_rules! toggle {
    ($s:ident, $cx:ident, $title:expr, $field:ident) => {
        $s.toggle_row(stringify!($field), $title, $s.config().$field, |c, v| c.$field = v, None, $cx)
    };
    ($s:ident, $cx:ident, $title:expr, $field:ident, $help:expr) => {
        $s.toggle_row(stringify!($field), $title, $s.config().$field, |c, v| c.$field = v, Some($help), $cx)
    };
}

macro_rules! pick {
    ($s:ident, $cx:ident, $title:expr, $field:ident, $ty:ident, $name:expr) => {
        $s.picker_row(stringify!($field), $title, $s.config().$field, $ty::ALL, $name, |c, v| c.$field = v, None, $cx)
    };
    ($s:ident, $cx:ident, $title:expr, $field:ident, $ty:ident, $name:expr, $help:expr) => {
        $s.picker_row(stringify!($field), $title, $s.config().$field, $ty::ALL, $name, |c, v| c.$field = v, Some($help), $cx)
    };
}

macro_rules! freq {
    ($s:ident, $cx:ident, $title:expr, $field:ident) => {
        $s.frequency_row(stringify!($field), $title, $s.config().$field, |c, v| c.$field = v, None, $cx)
    };
    ($s:ident, $cx:ident, $title:expr, $field:ident, $help:expr) => {
        $s.frequency_row(stringify!($field), $title, $s.config().$field, |c, v| c.$field = v, Some($help), $cx)
    };
}

fn star_picker(s: &mut Settings, key: &'static str, title: &'static str, value: StarType,
               set: fn(&mut WallpaperConfig, StarType), cx: &mut Context<Settings>) -> AnyElement {
    s.picker_row(key, title, value, StarType::ALL, star_title, set, None, cx)
}

// MARK: Scene

pub fn scene_tab(s: &mut Settings, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    let c = s.config().clone();
    let scene = c.scene;
    let mut groups: Vec<AnyElement> = Vec::new();

    // the scene itself heads its first group
    let customized = is_customized(&c, scene);
    let reset_help = if scene.shares_settings() {
        "Puts this scene's settings and colors back to their defaults. Camera tilt and planets are shared with other scenes and reset for them too."
    } else {
        "Puts this scene's settings and colors back to their defaults"
    };
    let header = div()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .pb(px(4.0))
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(div().text_size(px(16.0)).font_weight(FontWeight::SEMIBOLD).child(scene.title()))
                .child(
                    Button::new("reset-scene")
                        .label("Reset")
                        .xsmall()
                        .disabled(!customized)
                        .tooltip(reset_help)
                        .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                            this.edit(cx, |c| *c = resetting_scene(c, scene));
                        })),
                ),
        )
        .child(div().text_size(px(12.5)).text_color(theme::secondary()).child(blurb(scene)));
    let mut first = Group::new(Some(header.into_any_element())).rows(scene_rows(s, &c, w, cx));
    if let Some(note) = scene_note(&c) {
        first = first.footer(note);
    }
    groups.push(first.into_element());

    for g in extra_groups(s, &c, w, cx) {
        groups.push(g.into_element());
    }

    if has_colors(&c) {
        groups.push(Group::titled("Colors").rows(color_rows(s, &c, w, cx)).into_element());
    }
    if let Some(g) = events_group(s, &c, cx) {
        groups.push(g.into_element());
    }
    if scene.has_planets() {
        let collapsed = s.planets_collapsed;
        let mut g = Group::new(Some(collapsible("Planets", collapsed, |s| &mut s.planets_collapsed, cx)));
        if !collapsed {
            g = g.rows(planet_rows(s, &c, w, cx)).footer(
                "Around the black hole and wormhole, planets bend as they pass behind. Rings show only in those two scenes.",
            );
        }
        groups.push(g.into_element());
    }
    let collapsed = s.camera_collapsed;
    let mut cam = Group::new(Some(collapsible("Camera", collapsed, |s| &mut s.camera_collapsed, cx)));
    if !collapsed {
        cam = cam.row(camera_row(s, scene, w, cx));
    }
    groups.push(cam.into_element());
    groups
}

/// A group header that folds its group away.
fn collapsible(title: &'static str, collapsed: bool, flag: fn(&mut Settings) -> &mut bool,
               cx: &mut Context<Settings>) -> AnyElement {
    div()
        .id(SharedString::from(format!("fold-{title}")))
        .flex()
        .items_center()
        .gap(px(4.0))
        .cursor_pointer()
        .child(
            div()
                .w(px(10.0))
                .text_size(px(9.0))
                .text_color(theme::secondary())
                .child(if collapsed { "\u{25b6}" } else { "\u{25bc}" }),
        )
        .child(group_header(title))
        .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
            let f = flag(this);
            *f = !*f;
            cx.notify();
        }))
        .into_any_element()
}

fn scene_rows(s: &mut Settings, c: &WallpaperConfig, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    use SceneKind::*;
    match c.scene {
        BlackHole => vec![
            s.slider_row(slider!("Disk size", disk_size, 8.0, 18.0, f1), w, cx),
            s.slider_row(slider!("Disk speed", disk_speed, 0.1, 3.0), w, cx),
            s.slider_row(slider!("Photon ring", photon_ring, 0.0, 2.0), w, cx),
        ],
        Wormhole => vec![
            s.slider_row(slider!("Throat size", throat, 1.5, 5.5, f1), w, cx),
            s.slider_row(slider!("Rim glow", photon_ring, 0.0, 2.0), w, cx),
        ],
        Binary => vec![
            star_picker(s, "binaryA", "Star A", c.binary_stars[0], |c, v| c.binary_stars[0] = v, cx),
            star_picker(s, "binaryB", "Star B", c.binary_stars[1], |c, v| c.binary_stars[1] = v, cx),
            s.slider_row(slider!("Separation", star_separation, 3.0, 10.0, f1), w, cx),
            s.slider_row(slider!("Orbit period", star_orbit_minutes, 0.5, 20.0, min1), w, cx),
        ],
        Trinary => vec![
            star_picker(s, "trinaryA", "Inner star A", c.trinary_stars[0], |c, v| c.trinary_stars[0] = v, cx),
            star_picker(s, "trinaryB", "Inner star B", c.trinary_stars[1], |c, v| c.trinary_stars[1] = v, cx),
            star_picker(s, "trinaryC", "Outer star", c.trinary_stars[2], |c, v| c.trinary_stars[2] = v, cx),
            s.slider_row(slider!("Separation", star_separation, 3.0, 10.0, f1), w, cx),
            s.slider_row(slider!("Inner orbit period", star_orbit_minutes, 0.5, 20.0, min1), w, cx),
        ],
        TidalDisruption => vec![
            star_picker(s, "tdeStar", "Star", c.tde_star, |c, v| c.tde_star = v, cx),
            s.slider_row(slider!("Star size", tde_star_size, 0.5, 1.6), w, cx),
            s.slider_row(slider!("Star distance", tde_star_distance, 16.0, 28.0, f0), w, cx),
            s.slider_row(slider!("Stream brightness", tde_stream_brightness, 0.0, 2.0)
                .help("Gas peeled off the star, spiraling into the disk"), w, cx),
            s.slider_row(slider!("Disk speed", disk_speed, 0.1, 3.0), w, cx),
            toggle!(s, cx, "Jets", tde_jets),
        ],
        Pulsar => {
            let mut r = vec![
                s.slider_row(slider!("Rotation period", pulsar_period, 0.5, 12.0, sec1)
                    .help("Real pulsars spin up to hundreds of times a second. This one is slowed down so the beams don't strobe."), w, cx),
                s.slider_row(slider!("Magnetic angle", pulsar_inclination, 0.0, 90.0, deg), w, cx),
                s.slider_row(slider!("Spin axis tilt", pulsar_axis_tilt, -60.0, 60.0, deg), w, cx),
                pick!(s, cx, "Beams", pulsar_beams, PulsarBeams, pulsar_beams_title),
            ];
            if c.pulsar_beams != PulsarBeams::NoBeams {
                r.push(s.slider_row(slider!("Beam width", pulsar_beam_width, 2.0, 20.0, deg), w, cx));
                r.push(s.slider_row(slider!("Beam brightness", pulsar_beam_intensity, 0.2, 3.0), w, cx));
                r.push(s.slider_row(slider!("Beam trail", pulsar_beam_trail, 0.0, 3.0), w, cx));
            }
            r.push(toggle!(s, cx, "Magnetic field", pulsar_field_lines));
            if c.pulsar_field_lines {
                r.push(pick!(s, cx, "Field style", pulsar_field_style, PulsarFieldStyle, pulsar_field_title));
                r.push(s.slider_row(slider!("Field brightness", pulsar_field_intensity, 0.2, 3.0), w, cx));
            }
            r.push(toggle!(s, cx, "Dust ring", pulsar_ring));
            if c.pulsar_ring {
                r.push(s.slider_row(slider!("Ring brightness", pulsar_ring_intensity, 0.2, 3.0), w, cx));
            }
            r.push(toggle!(s, cx, "Wind nebula", pulsar_nebula, "The torus and jets around the pulsar"));
            if c.pulsar_nebula {
                r.push(s.slider_row(slider!("Nebula brightness", pulsar_nebula_intensity, 0.2, 3.0), w, cx));
            }
            r
        }
        Nebula => vec![s.slider_row(slider!("Flow speed", nebula_flow, 0.1, 4.0), w, cx)],
        PlanetaryNebula => vec![
            s.slider_row(slider!("Size", planetary_size, 0.6, 1.5), w, cx),
            s.slider_row(slider!("Elongation", planetary_elongation, 1.0, 2.2, f1)
                .help("How much longer the barrel of gas is than it is wide"), w, cx),
            s.slider_row(slider!("Viewing angle", planetary_view, 0.0, 85.0, deg)
                .help("0\u{b0} looks straight down the barrel and shows a round ring"), w, cx),
            s.slider_row(slider!("Knots", planetary_knots, 0.0, 1.5)
                .help("Dense droplets of gas around the inner rim, lit on the side facing the star"), w, cx),
            toggle!(s, cx, "Halo", planetary_halo, "Faint older shells from earlier puffs, drifting outward"),
        ],
        RingedPlanet => vec![
            s.slider_row(slider!("Size", ringed_size, 0.7, 1.3), w, cx),
            s.slider_row(slider!("Bands", ringed_bands, 0.5, 2.0).help("Lower for a few broad belts, higher for many fine ones"), w, cx),
            s.slider_row(slider!("Turbulence", ringed_turbulence, 0.0, 2.5).help("How much the bands swirl and streak where they meet"), w, cx),
            s.slider_row(slider!("Wind", ringed_wind, 0.0, 3.0).help("How fast the bands drift and shear past each other"), w, cx),
        ],
        AuroraOrbit => vec![
            s.slider_row(slider!("Brightness", aurora_brightness, 0.0, 2.5), w, cx),
            s.slider_row(slider!("Speed", aurora_activity, 0.05, 4.0).help("How fast the curtains ripple, fold and drift"), w, cx),
            s.slider_row(slider!("Distance", aurora_distance, 22.0, 60.0, deg)
                .help("How far ahead the magnetic pole lies. Nearer brings the curtains in below you; farther puts them along the horizon"), w, cx),
            s.slider_row(slider!("Oval size", aurora_oval_size, 10.0, 30.0, deg), w, cx),
        ],
        LiveEarth => {
            fn earth_km(v: f64) -> String {
                let km = (v - 1.0) * 6371.0;
                if km >= 10_000.0 { format!("{:.0}k km", km / 1000.0) } else { format!("{km:.0} km") }
            }
            fn planet_size(v: f64) -> String {
                if v < 1.5 { "true".into() } else { format!("{v:.0}x") }
            }
            let mut r = vec![
                s.slider_row(slider!("Distance", earth_distance, 1.4, 12.0, earth_km)
                    .help("Height above the chosen place. Geostationary satellites orbit at about 35,800 km"), w, cx),
                s.slider_row(slider!("Horizontal position", earth_center_x, -1.0, 1.0), w, cx),
                s.slider_row(slider!("Vertical position", earth_center_y, -1.0, 1.0), w, cx),
                s.slider_row(slider!("Atmosphere", earth_atmosphere, 0.0, 2.0), w, cx),
                s.slider_row(slider!("Moon size", earth_moon_size, 1.0, 6.0, x1)
                    .help("1x is its true size. The Moon only shows when it's behind Earth from here"), w, cx),
                s.slider_row(slider!("Stars", earth_stars, 0.0, 3.0).help("The real stars, where they are in the sky at the moment shown"), w, cx),
                s.slider_row(slider!("Milky Way", earth_milky_way, 0.0, 3.0), w, cx),
                toggle!(s, cx, "Planets", earth_planets, "Mercury to Neptune where they really are, at their real brightness"),
            ];
            if c.earth_planets {
                r.push(s.slider_row(slider!("Planet size", earth_planet_size, 1.0, 300.0, planet_size)
                    .help("At true size they're points of light, as you'd see them. Larger shows their disks, phases, bands and Saturn's rings"), w, cx));
                r.push(toggle!(s, cx, "Label planets", earth_planet_labels));
            }
            r.push(toggle!(s, cx, "Hide the sun at night", earth_hide_sun_at_night,
                "While it's night at the chosen place the sun sits behind Earth; this hides its disk and glare but keeps its light"));
            r.push(toggle!(s, cx, "Mark the place", earth_marker));
            r
        }
        GasGiant => vec![
            s.slider_row(slider!("Wind", gas_wind, 0.0, 4.0).help("How fast the bands flow and the storms spin"), w, cx),
            s.slider_row(slider!("Turbulence", gas_turbulence, 0.0, 2.5), w, cx),
            s.slider_row(slider!("Storm size", gas_storm_size, 0.5, 2.0), w, cx),
            s.slider_row(slider!("Distance", gas_distance, 1.2, 3.0).help("How close you are, in planet radii from its center"), w, cx),
            s.slider_row(slider!("Sun angle", gas_sun, 0.0, 140.0, deg), w, cx),
            s.slider_row(slider!("Axis tilt", gas_tilt, -40.0, 40.0, deg), w, cx),
            toggle!(s, cx, "Moon", gas_moon),
            freq!(s, cx, "Lightning", gas_lightning),
        ],
        ProtoplanetaryDisk => vec![
            pick!(s, cx, "Look", proto_look, ProtoDiskLook, proto_look_title,
                "Scattered light shows the disk's surface lit by the star; the ALMA glow shows the dust's own warmth at millimeter wavelengths, rings and gaps seen right through"),
            s.slider_row(slider!("Viewing angle", proto_view, 0.0, 88.0, deg)
                .help("0\u{b0} looks straight down on the disk; near 90\u{b0} it's edge-on, a dark dust lane between two lit surfaces"), w, cx),
            s.slider_row(slider!("Slant", proto_slant, -60.0, 60.0, deg), w, cx),
            s.slider_row(slider!("Size", proto_size, 0.6, 1.4), w, cx),
            s.stepper_row("protoGaps", format!("Gaps: {}", c.proto_gaps), c.proto_gaps, 1, 7, |c, v| c.proto_gaps = v,
                Some("Each gap is cleared by a forming planet orbiting inside it"), cx),
            s.slider_row(slider!("Gap width", proto_gap_width, 0.4, 2.0), w, cx),
            s.slider_row(slider!("Flaring", proto_flaring, 0.0, 2.0)
                .help("How fast the disk thickens outward. More flaring catches more starlight on its surface"), w, cx),
            s.slider_row(slider!("Orbit speed", proto_orbit_speed, 0.0, 4.0), w, cx),
            toggle!(s, cx, "Jets", proto_jets, "Thin jets from the star's poles, with knots of shocked gas moving outward"),
        ],
        NeutronMerger => vec![
            s.slider_row(slider!("Cycle length", merger_cycle_minutes, 2.0, 15.0, min1)
                .help("From one merger to the next: the kilonova fades around the new remnant, a companion falls in and is captured, and their orbit speeds up until they merge"), w, cx),
            s.slider_row(slider!("Star brightness", merger_brightness, 0.3, 2.5), w, cx),
            s.slider_row(slider!("Glow", merger_glow, 0.4, 2.5).help("How far each star's halo spreads"), w, cx),
            s.slider_row(slider!("Wave ripple", merger_waves, 0.0, 3.0)
                .help("How strongly the gravitational waves bend the starlight behind them"), w, cx),
            s.slider_row(slider!("Viewing angle", merger_view, 0.0, 85.0, deg).help("0\u{b0} looks straight down onto the orbit"), w, cx),
            toggle!(s, cx, "Jet", merger_jet, "A short jet punching out along the orbit's axis just after the merger"),
        ],
        BlackHoleMerger => {
            let current = DETECTIONS.iter().find(|d| d.matches(c)).map(|d| d.name).unwrap_or("Custom");
            let mut options: Vec<(String, bool)> = DETECTIONS.iter().map(|d| (d.name.to_string(), d.name == current)).collect();
            options.push(("Custom".into(), current == "Custom"));
            let detection = s.menu_button("bbhDetection", current.into(), options, |c, i| {
                if let Some(d) = DETECTIONS.get(i) {
                    d.apply(c);
                }
            }, cx);
            vec![
                row("Detection", Some("Load the masses, spins and viewing angle of a merger LIGO, Virgo and KAGRA heard"), detection),
                pick!(s, cx, "Black holes", bbh_model, BlackHoleMergerModel, bbh_model_title,
                    "Stellar pairs merge in empty space, or in a quasar's gas disk where the kicked remnant sets off a flare. Intermediate ones sit in a dense star cluster. Supermassive ones, brought together by colliding galaxies, clear a hole in their gas disk and feed on streams from its edge"),
                s.slider_row(slider!("Mass ratio", bbh_mass_ratio, 0.05, 1.0)
                    .help("The lighter hole's mass over the heavier one's. Unequal pairs are tighter, wind through more orbits and add a third arm to the waves"), w, cx),
                s.slider_row(slider!("Remnant spin", bbh_spin, 0.0, 0.98)
                    .help("Faster spin flattens one side of the shadow and makes the ringdown higher and longer"), w, cx),
                s.slider_row(slider!("Precession", bbh_precession, 0.0, 1.0)
                    .help("Spins tilted off the orbit's axis make the orbit wobble, faster as it tightens. They also make the recoil kick much stronger"), w, cx),
                s.slider_row(slider!("Recoil kick", bbh_kick, 0.0, 2.0)
                    .help("Waves beamed unevenly push the remnant away. Unequal masses and tilted spins kick hardest"), w, cx),
                toggle!(s, cx, "Eccentric orbit", bbh_eccentric,
                    "The pair stays eccentric to the end: the companion dives in, whirls round and swings back out, sending a burst of waves at each close pass"),
                toggle!(s, cx, "Hierarchical chain", bbh_chain,
                    "Each remnant becomes the heavy partner of the next merger, three times over, so it grows and each new companion is relatively smaller"),
                s.slider_row(slider!("Speed", bbh_speed, 0.25, 3.0, x2).help("How fast everything in this scene moves, the merger cycle included"), w, cx),
                s.slider_row(slider!("Cycle length", bbh_cycle_minutes, 2.0, 15.0, min1)
                    .help("From one merger to the next: the remnant settles, a companion falls in and is captured, and their orbit speeds up until they merge, timed at Speed 1"), w, cx),
                s.slider_row(slider!("Ringdown slow motion", bbh_ringdown, 1.0, 6.0, x1)
                    .help("Slows the last second of the chirp and the ringdown so the joined shadow's spin and wobble can be seen. 1 is true to the rest of the scene"), w, cx),
                s.slider_row(slider!("Lensing", bbh_lensing, 0.0, 2.0).help("How strongly each hole bends the light behind it into arcs and rings"), w, cx),
                toggle!(s, cx, "Background galaxy", bbh_galaxy,
                    "A distant galaxy almost straight behind the pair, bent into a ring that breaks into arcs as they move"),
                toggle!(s, cx, "Strain trace", bbh_trace,
                    "The waves as a detector records them, drawn along the bottom: a rising chirp, the merger, the ringdown"),
                s.slider_row(slider!("Wave ripple", bbh_waves, 0.0, 3.0)
                    .help("How strongly the gravitational waves bend the starlight behind them"), w, cx),
                s.slider_row(slider!("Viewing angle", bbh_view, 0.0, 85.0, deg).help("0\u{b0} looks straight down onto the orbit"), w, cx),
            ]
        }
        DysonSwarm => vec![
            star_picker(s, "dysonStar", "Star", c.dyson_star, |c, v| c.dyson_star = v, cx),
            s.slider_row(slider!("Density", dyson_density, 0.0, 1.0)
                .help("From a few sparse bands of panels to a swarm that nearly closes over the star"), w, cx),
            s.stepper_row("dysonRings", format!("Rings: {}", c.dyson_rings), c.dyson_rings, 3, 20, |c, v| c.dyson_rings = v, None, cx),
            s.slider_row(slider!("Orbit speed", dyson_orbit_speed, 0.0, 4.0), w, cx),
            s.slider_row(slider!("Panel glints", dyson_glint, 0.0, 2.5)
                .help("How brightly panels flash as their mirrors swing through the line between the star and you"), w, cx),
        ],
        RoguePlanet => vec![
            s.slider_row(slider!("Size", rogue_size, 0.5, 1.8), w, cx),
            s.slider_row(slider!("Position X", rogue_center_x, -0.8, 0.8), w, cx),
            s.slider_row(slider!("Position Y", rogue_center_y, -0.8, 0.8), w, cx),
            s.slider_row(slider!("Spin", rogue_spin, 0.0, 3.0).help("How fast the planet turns"), w, cx),
            s.slider_row(slider!("Aurora", rogue_aurora, 0.0, 2.5)
                .help("The glow round both magnetic poles, powered by the planet's own magnetic field"), w, cx),
            s.slider_row(slider!("Rift glow", rogue_rift, 0.0, 2.5).help("Heat from inside the planet glowing through cracks in its ice"), w, cx),
            s.slider_row(slider!("Milky Way", rogue_milky_way, 0.0, 2.0), w, cx),
            toggle!(s, cx, "Moon", rogue_moon),
        ],
        Eclipse => {
            let mut r = vec![pick!(s, cx, "Motion", eclipse_motion, EclipseMotion, eclipse_motion_title,
                "Hold at totality parks the moon over the sun, so the corona, prominences and eruptions are always out")];
            if c.eclipse_motion == EclipseMotion::Cycle {
                r.push(s.slider_row(slider!("Cycle length", eclipse_cycle_minutes, 1.0, 10.0, min1)
                    .help("How long one eclipse takes, from full sun through totality and back to full sun"), w, cx));
            }
            r.push(s.slider_row(slider!("Corona size", eclipse_corona_size, 0.5, 2.0), w, cx));
            r.push(s.slider_row(slider!("Corona brightness", eclipse_corona_brightness, 0.3, 2.5), w, cx));
            r.push(s.slider_row(slider!("Prominences", eclipse_prominences, 0.0, 2.5)
                .help("How many pink loops and sheets of cool gas stand round the edge of the sun, and how often small jets shoot up"), w, cx));
            r
        }
        Comet => vec![
            s.slider_row(slider!("Tail length", comet_tail_length, 0.3, 2.0), w, cx),
            s.slider_row(slider!("Activity", comet_activity, 0.2, 2.5), w, cx),
        ],
        StellarSurface => vec![
            star_picker(s, "closeStar", "Star", c.close_star, |c, v| c.close_star = v, cx),
            s.slider_row(slider!("Sunspots", star_spots, 0.0, 1.5), w, cx),
            s.slider_row(slider!("Rotation", star_rotation, 0.0, 4.0), w, cx),
        ],
        Quasar => vec![
            s.slider_row(slider!("Jet length", quasar_jet_length, 0.5, 1.3), w, cx),
            s.slider_row(slider!("Jet brightness", quasar_jet_brightness, 0.2, 2.5), w, cx),
            s.slider_row(slider!("Jet direction", quasar_jet_angle, -60.0, 60.0, deg).help("Which way the jets point across the screen"), w, cx),
            s.slider_row(slider!("Knot speed", quasar_knot_speed, 0.0, 3.0).help("How fast the bright knots travel out along the jets"), w, cx),
            s.slider_row(slider!("Galaxy", quasar_galaxy, 0.0, 2.0)
                .help("The host galaxy's brightness. All the way down hides it, leaving the nucleus and jets"), w, cx),
        ],
        Galaxy => {
            let mut r = vec![pick!(s, cx, "Type", galaxy_type, GalaxyType, galaxy_type_title)];
            if matches!(c.galaxy_type, GalaxyType::Spiral | GalaxyType::Barred) {
                r.push(s.stepper_row("galaxyArms", format!("Spiral arms: {}", c.galaxy_arms), c.galaxy_arms, 1, 4,
                    |c, v| c.galaxy_arms = v, None, cx));
                r.push(s.slider_row(slider!("Arm pitch", galaxy_pitch, 6.0, 35.0, deg), w, cx));
            }
            r.push(s.slider_row(slider!("Size", galaxy_size, 0.6, 1.5), w, cx));
            r.push(s.slider_row(slider!("Edge orbit period", galaxy_rotation_minutes, 1.0, 30.0, min0), w, cx));
            r.push(if c.dark_matter {
                toggle!(s, cx, "Dark matter halo", dark_matter,
                    "A flat rotation curve: stars at the edge orbit as fast as those near the middle, as observed in real galaxies. The unseen halo supplies the extra gravity.")
            } else {
                toggle!(s, cx, "Dark matter halo", dark_matter,
                    "Visible mass only: orbital speed falls off like v \u{221d} 1/\u{221a}r, so the outer disk lags far behind. Real galaxies don't do this.")
            });
            r
        }
    }
}

/// The scenes with groups of their own below the first: rings and moons, Earth and view, ground
/// and air, framing.
fn extra_groups(s: &mut Settings, c: &WallpaperConfig, w: &mut Window, cx: &mut Context<Settings>) -> Vec<Group> {
    use SceneKind::*;
    match c.scene {
        RingedPlanet => {
            let mut rings = vec![pick!(s, cx, "Style", ringed_ring_style, RingStyle, ring_style_title)];
            if c.ringed_ring_style != RingStyle::NoRings {
                rings.push(s.slider_row(slider!("Width", ringed_ring_width, 0.6, 1.6), w, cx));
                rings.push(s.slider_row(slider!("Density", ringed_ring_density, 0.3, 1.6)
                    .help("Lower for thin, see-through rings, higher for solid ones"), w, cx));
                if c.ringed_ring_style != RingStyle::Narrow {
                    rings.push(toggle!(s, cx, "Spokes", ringed_spokes,
                        "Faint wisps of dust over the dense ring, turning with the planet's magnetic field"));
                }
            }
            rings.push(s.slider_row(slider!("Opening", ringed_tilt, 2.0, 40.0, deg).help("How far the ring plane is tipped toward you"), w, cx));
            rings.push(s.slider_row(slider!("Slant", ringed_roll, -40.0, 40.0, deg), w, cx));
            let lighting = vec![
                s.slider_row(slider!("Sun angle", ringed_sun, 0.0, 160.0, deg)
                    .help("0\u{b0} lights the planet from behind you; past 90\u{b0} it turns into a crescent and the rings glow, backlit"), w, cx),
                s.slider_row(slider!("Sun height", ringed_sun_height, -25.0, 40.0, deg)
                    .help("The sun above the ring plane. Below it, you see the rings' unlit side, glowing where they're thin, and their shadow falls across the planet"), w, cx),
            ];
            let mut moons = vec![s.stepper_row("ringedMoons", format!("Moons: {}", c.ringed_moon_count), c.ringed_moon_count, 0, 3,
                |c, v| c.ringed_moon_count = v, None, cx)];
            if c.ringed_moon_count > 0 {
                moons.push(s.slider_row(slider!("Moon size", ringed_moon_size, 0.5, 2.0), w, cx));
                moons.push(s.slider_row(slider!("Orbit speed", ringed_moon_speed, 0.2, 4.0), w, cx));
            }
            vec![Group::titled("Rings").rows(rings), Group::titled("Lighting").rows(lighting), Group::titled("Moons").rows(moons)]
        }
        AuroraOrbit => vec![
            Group::titled("Earth").rows(vec![
                s.slider_row(slider!("City lights", aurora_city_lights, 0.0, 2.5), w, cx),
                s.slider_row(slider!("Clouds", aurora_clouds, 0.0, 1.5), w, cx),
                s.slider_row(slider!("Moonlight", aurora_moonlight, 0.0, 1.5).help("Faint light on the clouds and seas"), w, cx),
                freq!(s, cx, "Lightning", aurora_lightning),
            ]),
            Group::titled("View").rows(vec![
                s.slider_row(slider!("Altitude", aurora_altitude, 250.0, 1500.0, km), w, cx),
                s.slider_row(slider!("Horizon", aurora_horizon, -0.6, 0.8).help("Where the edge of Earth sits on screen"), w, cx),
                s.slider_row(slider!("Ground drift", aurora_drift, 0.0, 4.0).help("The ground sliding by below as you orbit"), w, cx),
                s.slider_row(slider!("Sunrise", aurora_sunrise, 0.0, 1.5).help("Dawn glow along one end of the horizon"), w, cx),
            ]),
        ],
        LiveEarth => {
            fn lat(v: f64) -> String {
                format!("{:.1}\u{b0} {}", v.abs(), if v >= 0.0 { "N" } else { "S" })
            }
            fn lon(v: f64) -> String {
                format!("{:.1}\u{b0} {}", v.abs(), if v >= 0.0 { "E" } else { "W" })
            }
            let mut live = vec![toggle!(s, cx, "Live clouds", earth_clouds)];
            if c.earth_clouds {
                live.push(s.slider_row(slider!("Cloud cover", earth_cloud_amount, 0.0, 1.5), w, cx));
            }
            live.push(toggle!(s, cx, "Aurora forecast", earth_aurora));
            if c.earth_aurora {
                live.push(s.slider_row(slider!("Aurora brightness", earth_aurora_brightness, 0.0, 3.0), w, cx));
                live.push(s.slider_row(slider!("Aurora speed", earth_aurora_speed, 0.1, 2.0).help("How fast the curtains ripple and drift"), w, cx));
            }
            vec![
                Group::titled("Place")
                    .rows(vec![
                        s.slider_row(slider!("Latitude", home_latitude, -90.0, 90.0, lat), w, cx),
                        s.slider_row(slider!("Longitude", home_longitude, -180.0, 180.0, lon), w, cx),
                    ])
                    .footer("This place stays in the middle of Earth's disk, with north up."),
                Group::titled("Live data").rows(live)
                    .footer("Clouds from geostationary weather satellites; aurora from NOAA's OVATION forecast."),
                Group::titled("Night side").rows(vec![
                    s.slider_row(slider!("City lights", earth_city_lights, 0.0, 2.5), w, cx),
                    s.slider_row(slider!("Moonlight", earth_moonlight, 0.0, 3.0)
                        .help("How brightly the Moon lights the night side; it follows the Moon's phase"), w, cx),
                ]),
            ]
        }
        Eclipse => {
            let mut ground = vec![toggle!(s, cx, "Landscape", eclipse_landscape)];
            if c.eclipse_landscape {
                ground.push(pick!(s, cx, "Surface", eclipse_world, EclipseWorld, eclipse_world_title));
            }
            let mut sky = vec![pick!(s, cx, "Body", eclipse_sky_body, EclipseSkyBody, eclipse_body_title)];
            if c.eclipse_sky_body != EclipseSkyBody::NoBody {
                sky.push(s.slider_row(slider!("Size", eclipse_planet_size, 0.4, 1.8), w, cx));
                sky.push(s.slider_row(slider!("Horizontal position", eclipse_planet_x, -1.0, 1.0), w, cx));
                sky.push(s.slider_row(slider!("Height", eclipse_planet_y, -0.6, 0.9), w, cx));
            }
            let mut air = vec![toggle!(s, cx, "Atmosphere", eclipse_atmosphere,
                "Off is an airless world with a black sky. With air the sky darkens as the sun goes, and at totality a sunset glow rings the horizon")];
            if c.eclipse_atmosphere {
                let current = AIR_PRESETS.iter().find(|p| p.matches(c)).map(|p| p.name).unwrap_or("Custom");
                let mut options: Vec<(String, bool)> = AIR_PRESETS.iter().map(|p| (p.name.to_string(), p.name == current)).collect();
                options.push(("Custom".into(), current == "Custom"));
                let menu = s.menu_button("eclipseAir", current.into(), options, |c, i| {
                    if let Some(p) = AIR_PRESETS.get(i) {
                        p.apply(c);
                    }
                }, cx);
                air.push(row("Composition", None, menu));
                air.push(color!(s, w, cx, "Sky color", eclipse_air_color));
                air.push(s.slider_row(slider!("Density", eclipse_air_density, 0.1, 3.0), w, cx));
                air.push(s.slider_row(slider!("Haze", eclipse_air_haze, 0.0, 2.0)
                    .help("Dust or smog: it whitens and dims the sky and spreads a glow round the sun"), w, cx));
                air.push(s.slider_row(slider!("Clouds", eclipse_clouds, 0.0, 1.0), w, cx));
            }
            vec![Group::titled("Ground").rows(ground), Group::titled("In the sky").rows(sky), Group::titled("Air").rows(air)]
        }
        StellarSurface => {
            fn frame(zoom: f64, x: f64, top: f64) -> Rc<dyn Fn(&mut Settings, &mut Context<Settings>)> {
                Rc::new(move |s: &mut Settings, cx: &mut Context<Settings>| {
                    s.edit(cx, |c| {
                        c.star_zoom = zoom;
                        c.star_center_x = x;
                        c.star_limb_y = top;
                    })
                })
            }
            vec![Group::titled("Framing").rows(vec![
                s.slider_row(slider!("Zoom", star_zoom, STAR_ZOOM_RANGE.0, STAR_ZOOM_RANGE.1), w, cx),
                s.slider_row(slider!("Horizontal position", star_center_x, -1.0, 1.0), w, cx),
                s.slider_row(slider!("Top of the star", star_limb_y, -0.9, 1.0), w, cx),
                s.buttons_row("Framing", vec![
                    ("Whole Star", frame(0.45, 0.0, 0.8)),
                    ("Limb", frame(1.0, -0.15, 0.12)),
                    ("Close-Up", frame(3.0, -0.1, -0.2)),
                ], cx),
            ])]
        }
        _ => vec![],
    }
}

/// False when the scene has no colors of its own to show, so the group can be left out.
fn has_colors(c: &WallpaperConfig) -> bool {
    use SceneKind::*;
    match c.scene {
        Binary | Trinary | StellarSurface | LiveEarth => false,
        Pulsar => c.pulsar_beams != PulsarBeams::NoBeams || c.pulsar_field_lines || c.pulsar_ring || c.pulsar_nebula,
        _ => true,
    }
}

/// Only the colors the selected scene draws with; each is what that part shows where it's
/// typically lit (a pick, turned into shader light by the renderer).
fn color_rows(s: &mut Settings, c: &WallpaperConfig, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    use SceneKind::*;
    let uses_palette = match c.scene {
        BlackHole | Wormhole => true,
        TidalDisruption => c.tde_disk_colors == TdeDiskColors::Palette,
        _ => false,
    };
    let mut r = Vec::new();
    if uses_palette {
        let items = palette_swatches(c);
        r.push(s.swatch_grid("palette", items, cx));
    } else {
        let items = preset_swatches(c);
        if !items.is_empty() {
            r.push(s.swatch_grid("scene", items, cx));
        }
    }
    let disk = |s: &mut Settings, w: &mut Window, cx: &mut Context<Settings>| -> Rows {
        vec![
            color!(s, w, cx, "Receding side", palette.receding),
            color!(s, w, cx, "Approaching side", palette.approaching),
            color!(s, w, cx, "Hot core", palette.core),
        ]
    };
    match c.scene {
        BlackHole => {
            r.extend(disk(s, w, cx));
            r.push(color!(s, w, cx, "Photon ring", palette.ring));
        }
        TidalDisruption => {
            r.push(pick!(s, cx, "Disk colors", tde_disk_colors, TdeDiskColors, tde_colors_title));
            if c.tde_disk_colors == TdeDiskColors::Palette {
                r.extend(disk(s, w, cx));
            }
            r.push(color!(s, w, cx, "Photon ring", palette.ring));
            if c.tde_jets {
                r.push(color!(s, w, cx, "Jet color", tde_jet_color));
            }
        }
        Wormhole => {
            r.push(color!(s, w, cx, "Rim", palette.ring));
            r.push(color!(s, w, cx, "Other universe glow", palette.far_a));
            r.push(color!(s, w, cx, "Other universe wisps", palette.far_b));
        }
        Galaxy => {
            r.push(color!(s, w, cx, "Old stars", palette.galaxy_core));
            r.push(color!(s, w, cx, "Young stars", palette.galaxy_arms));
            r.push(color!(s, w, cx, "Star-forming nebulae", palette.galaxy_nebula));
            r.push(color!(s, w, cx, "Dust", palette.galaxy_dust));
        }
        Pulsar => {
            if c.pulsar_beams != PulsarBeams::NoBeams {
                r.push(color!(s, w, cx, "Beams", pulsar_beam_color));
            }
            if c.pulsar_field_lines {
                r.push(color!(s, w, cx, "Magnetic field", pulsar_field_color));
            }
            if c.pulsar_ring {
                r.push(color!(s, w, cx, "Dust ring", pulsar_ring_color));
            }
            if c.pulsar_nebula {
                r.push(color!(s, w, cx, "Wind nebula", pulsar_nebula_color));
            }
        }
        GasGiant => {
            r.push(color!(s, w, cx, "Light zones", gas_zone));
            r.push(color!(s, w, cx, "Dark belts", gas_belt));
            r.push(color!(s, w, cx, "Great spot", gas_storm));
        }
        ProtoplanetaryDisk => {
            r.push(color!(s, w, cx, "Dust rings", proto_dust_color));
            r.push(color!(s, w, cx, "Lit surface", proto_gas_color));
            r.push(color!(s, w, cx, "Star", proto_star_color));
            if c.proto_jets {
                r.push(color!(s, w, cx, "Jets", proto_jet_color));
            }
        }
        BlackHoleMerger => {
            r.push(color!(s, w, cx, "Photon rings", bbh_ring_color));
            if c.bbh_model != BlackHoleMergerModel::Stellar {
                let gas = c.bbh_model != BlackHoleMergerModel::Intermediate;
                r.push(color!(s, w, cx, if gas { "Gas, hot" } else { "Blue stars" }, bbh_hot));
                r.push(color!(s, w, cx, if gas { "Gas, cool" } else { "Red giants" }, bbh_cool));
            }
        }
        NeutronMerger => {
            r.push(color!(s, w, cx, "Stars", merger_star_color));
            r.push(color!(s, w, cx, "Kilonova, hot", merger_hot));
            r.push(color!(s, w, cx, "Kilonova, cooled", merger_cool));
        }
        DysonSwarm => {
            r.push(color!(s, w, cx, "Panels", dyson_panel_a));
            r.push(color!(s, w, cx, "Panels, second finish", dyson_panel_b));
            r.push(color!(s, w, cx, "Waste heat", dyson_heat));
        }
        RoguePlanet => {
            r.push(color!(s, w, cx, "Aurora (low)", rogue_aurora_low));
            r.push(color!(s, w, cx, "Aurora tops", rogue_aurora_high));
            r.push(color!(s, w, cx, "Rift glow", rogue_rift_color));
        }
        Eclipse => {
            r.push(color!(s, w, cx, "Corona", eclipse_corona_color));
            r.push(color!(s, w, cx, "Prominences", eclipse_prominence_color));
            if c.eclipse_landscape {
                r.push(color!(s, w, cx, "Ground", eclipse_ground_color));
            }
            if c.eclipse_sky_body != EclipseSkyBody::NoBody {
                r.push(color!(s, w, cx, "Sky body", eclipse_planet_color));
            }
        }
        AuroraOrbit => {
            r.push(color!(s, w, cx, "Aurora (oxygen, low)", aurora_green));
            r.push(color!(s, w, cx, "Aurora tops (oxygen, high)", aurora_red));
            r.push(color!(s, w, cx, "Lower fringe (nitrogen)", aurora_fringe));
            r.push(color!(s, w, cx, "City lights", aurora_city_color));
        }
        RingedPlanet => {
            r.push(color!(s, w, cx, "Light bands", ringed_band_light));
            r.push(color!(s, w, cx, "Dark bands", ringed_band_dark));
            if c.ringed_ring_style != RingStyle::NoRings {
                r.push(color!(s, w, cx, "Rings", ringed_ring_color));
            }
        }
        PlanetaryNebula => {
            r.push(color!(s, w, cx, "Inner glow (oxygen)", planetary_inner_color));
            r.push(color!(s, w, cx, "Rim (hydrogen)", planetary_rim_color));
            if c.planetary_halo {
                r.push(color!(s, w, cx, "Halo", planetary_halo_color));
            }
        }
        Comet => {
            r.push(color!(s, w, cx, "Ion tail", comet_ion_color));
            r.push(color!(s, w, cx, "Dust tail", comet_dust_color));
        }
        Nebula => {
            r.push(color!(s, w, cx, "Hydrogen (H\u{3b1})", nebula_ha));
            r.push(color!(s, w, cx, "Oxygen (OIII)", nebula_oiii));
            r.push(color!(s, w, cx, "Sulfur (SII)", nebula_sii));
        }
        Quasar => {
            r.push(color!(s, w, cx, "Jets", quasar_jet_color));
            r.push(color!(s, w, cx, "Radio lobes", quasar_lobe_color));
        }
        Binary | Trinary | StellarSurface | LiveEarth => {}
    }
    r
}

/// The scene's own occasional events. The Mac's Show Me buttons start an event in the running
/// wallpaper, which the Windows wallpaper can't be asked to do yet, so only the frequencies show.
fn events_group(s: &mut Settings, c: &WallpaperConfig, cx: &mut Context<Settings>) -> Option<Group> {
    use SceneKind::*;
    let g = Group::titled("Events");
    Some(match c.scene {
        Comet => g.row(freq!(s, cx, "Outbursts and tail breaks", comet_events)),
        StellarSurface => g.row(freq!(s, cx, "Flares and eruptions", star_flares)),
        GasGiant => g.row(freq!(s, cx, "Comet impacts", gas_events)),
        ProtoplanetaryDisk => g.row(freq!(s, cx, "Accretion outbursts", proto_events)),
        DysonSwarm => g.row(freq!(s, cx, "Reorientation waves", dyson_events)),
        RoguePlanet => g.row(freq!(s, cx, "Star glints", rogue_events,
            "A bright star passing behind the planet, its light bent round the limb by the thin atmosphere")),
        Eclipse => g.row(freq!(s, cx, "Eruptions", eclipse_events)).footer(if c.eclipse_motion == EclipseMotion::Cycle {
            "Eruptions wait for totality, when the corona is out."
        } else {
            "Held at totality, eruptions come every few minutes, with small jets in between."
        }),
        AuroraOrbit => g.row(freq!(s, cx, "Substorms", aurora_events)),
        RingedPlanet => g.row(freq!(s, cx, "Great white storms", ringed_events)),
        PlanetaryNebula => g.row(freq!(s, cx, "Shell ejections", planetary_events)),
        Quasar => g.row(freq!(s, cx, "Flares", quasar_events)),
        Wormhole => g.row(freq!(s, cx, "Wormhole events", wormhole_events)),
        _ => return None,
    })
}

fn planet_rows(s: &mut Settings, c: &WallpaperConfig, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    vec![
        s.stepper_row("planetCount", format!("Planets: {}", c.planet_count), c.planet_count, 0, 6, |c, v| c.planet_count = v, None, cx),
        s.slider_row(slider!("Size", planet_size, 0.4, 2.0), w, cx),
        s.slider_row(slider!("Outer orbit period", planet_orbit_minutes, 2.0, 120.0, min0), w, cx),
        s.buttons_row("Arrangement", vec![(
            "Shuffle",
            Rc::new(|s: &mut Settings, cx: &mut Context<Settings>| s.edit(cx, |c| c.planet_seed += 1)),
        )], cx),
        toggle!(s, cx, "Rings on some giants", planet_rings),
    ]
}

fn camera_row(s: &mut Settings, scene: SceneKind, w: &mut Window, cx: &mut Context<Settings>) -> AnyElement {
    match scene {
        SceneKind::Galaxy => s.slider_row(slider!("Viewing angle", galaxy_view, 5.0, 85.0, deg), w, cx),
        SceneKind::Quasar => s.slider_row(slider!("Viewing angle", quasar_view, 20.0, 90.0, deg)
            .help("The angle between the jets and our line of sight. Smaller angles boost the approaching jet and hide the receding one; near 90\u{b0} the dust ring hides the core"), w, cx),
        SceneKind::TidalDisruption => s.slider_row(slider!("Viewing angle", tde_view, 4.0, 35.0, deg), w, cx),
        _ => s.slider_row(slider!("Tilt", tilt, 1.0, 25.0, deg), w, cx),
    }
}

// MARK: Sky

pub fn sky_tab(s: &mut Settings, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    let c = s.config().clone();
    let mut seed_buttons: Vec<(&'static str, Rc<dyn Fn(&mut Settings, &mut Context<Settings>)>)> = vec![(
        "Randomize",
        Rc::new(|s: &mut Settings, cx: &mut Context<Settings>| {
            let n = random_seed(999_999);
            s.edit(cx, |c| c.sky_seed = n)
        }),
    )];
    if c.sky_seed != 0 {
        seed_buttons.push(("Original", Rc::new(|s: &mut Settings, cx: &mut Context<Settings>| s.edit(cx, |c| c.sky_seed = 0))));
    }
    let seed_label = if c.sky_seed == 0 { "Star field: original".to_string() } else { format!("Star field: {}", c.sky_seed) };
    let background = Group::titled("Background").rows(vec![
        s.slider_row(slider!("Star density", star_density, 0.2, 3.0), w, cx),
        s.slider_row(slider!("Nebula brightness", nebula, 0.0, 4.0), w, cx),
        toggle!(s, cx, "Distant galaxies", galaxies),
        toggle!(s, cx, "Milky Way band", milky_way, "A band of dense stars and dust across the sky"),
        s.buttons_row(seed_label, seed_buttons, cx),
    ]);
    let colors = Group::titled("Colors").rows(vec![
        color!(s, w, cx, "Nebula", palette.nebula_a),
        color!(s, w, cx, "Nebula wisps", palette.nebula_b),
        color!(s, w, cx, "Galaxies", palette.galaxy),
        color!(s, w, cx, "Warm stars", palette.star_warm),
        color!(s, w, cx, "Cool stars", palette.star_cool),
    ]);
    let mut events = vec![freq!(s, cx, "Twinkling stars", twinkles)];
    if c.twinkles != Frequency::Off {
        events.push(s.slider_row(slider!("Twinkle brightness", twinkle_brightness, 0.2, 3.0), w, cx));
        events.push(s.slider_row(slider!("Twinkle speed", twinkle_speed, 0.25, 3.0, x2)
            .help("How fast twinkles come and go, and how fast each one flickers"), w, cx));
    }
    events.push(toggle!(s, cx, "Blinking stars", pulsars, "A few stars blink on a steady beat, like distant pulsars"));
    events.push(freq!(s, cx, "Supernovae", supernovae));
    events.push(freq!(s, cx, "Comets", comets));
    let events = Group::titled("Events").rows(events).footer(
        "At Normal, a supernova goes off about every 6 minutes and a comet passes about every 9. Each plays out over two to three minutes.",
    );
    vec![background.into_element(), colors.into_element(), events.into_element()]
}

fn random_seed(max: u64) -> i64 {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(1) as u64;
    // splitmix64, so seeds picked a moment apart still differ widely
    let mut z = t.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^= z >> 31;
    (1 + z % max) as i64
}

// MARK: Image

pub fn image_tab(s: &mut Settings, w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    let c = s.config().clone();
    let scene = c.scene;
    let own = c.has_own_image(scene);
    let separate = s.toggle_row(
        "ownImage",
        format!("Separate settings for {}", scene.title()),
        own,
        |c, on| set_own_image(c, on),
        Some("Give this scene its own tone, glow and pixel look. Turning it off goes back to the shared settings."),
        cx,
    );
    let sep = Group::new(None).row(separate).footer(if own {
        format!("These settings apply only to {}. Other scenes keep the shared ones.", scene.title())
    } else {
        "These settings are shared by every scene that doesn't have its own.".to_string()
    });

    let tone_header = div()
        .flex()
        .items_center()
        .justify_between()
        .child(group_header("Tone"))
        .child(
            Button::new("reset-image")
                .label("Reset")
                .xsmall()
                .tooltip("Puts tone and glow back to their defaults")
                .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| this.edit(cx, |c| c.reset_image()))),
        );
    let tone = Group::new(Some(tone_header.into_any_element()))
        .rows(vec![
            s.slider_row(slider!("Saturation", saturation, 0.0, 2.5), w, cx),
            s.slider_row(slider!("Exposure", brightness, EXPOSURE_RANGE.0, EXPOSURE_RANGE.1), w, cx),
            s.slider_row(slider!("Contrast", contrast, CONTRAST_RANGE.0, CONTRAST_RANGE.1), w, cx),
            s.slider_row(slider!("Black point", black_point, BLACK_POINT_RANGE.0, BLACK_POINT_RANGE.1), w, cx),
            s.slider_row(slider!("Highlight rolloff", highlights, 0.0, 1.0), w, cx),
            s.slider_row(slider!("Vignette", vignette, 0.0, 1.0), w, cx),
        ])
        .footer("Applied before the dither, so the result stays pixel-dithered.");

    fn bloom_fmt(v: f64) -> String {
        if v == 0.0 { "Off".into() } else { format!("{v:.2}") }
    }
    fn pct(v: f64) -> String {
        format!("{:.1}%", v * 100.0)
    }
    let mut glow = vec![s.slider_row(slider!("Bloom", bloom, BLOOM_RANGE.0, BLOOM_RANGE.1, bloom_fmt), w, cx)];
    if c.bloom > 0.0 {
        glow.push(s.slider_row(slider!("Bloom radius", bloom_radius, BLOOM_RADIUS_RANGE.0, BLOOM_RADIUS_RANGE.1, pct), w, cx));
        glow.push(s.slider_row(slider!("Bloom threshold", bloom_threshold, 0.0, 1.0), w, cx));
    }
    let glow = Group::titled("Glow").rows(glow).footer("Adds a glow around bright light. Off uses no extra power.");

    const SIZES: [i64; 6] = [1, 2, 3, 4, 6, 8];
    let pixel = s.segmented_row(
        "pixelSize",
        "Pixel size",
        SIZES.iter().map(|n| (format!("{n} px"), *n == c.pixel_size)).collect(),
        |c, i| c.pixel_size = SIZES[i],
        cx,
    );
    // 32 and 64 match the welcome guide's Smooth look; the current value is always listed, so a
    // level set elsewhere stays selectable
    let mut levels: Vec<i64> = vec![2, 3, 4, 5, 6, 8, 16, 32, 64];
    if !levels.contains(&c.levels) {
        levels.push(c.levels);
        levels.sort();
    }
    let lv = levels.clone();
    let levels_row = s.segmented_row(
        "levels",
        "Color levels per channel",
        levels.iter().map(|n| (n.to_string(), *n == c.levels)).collect(),
        move |c, i| c.levels = lv[i],
        cx,
    );
    let dither = pick!(s, cx, "Dither pattern", dither, DitherPattern, DitherPattern::title);
    let pixels = Group::titled("Pixels").rows(vec![pixel, levels_row, dither]);
    vec![sep.into_element(), tone.into_element(), glow.into_element(), pixels.into_element()]
}

/// `sceneHasOwnImage`: turns the active scene's own image settings on, starting from the shared
/// ones, or off, going back to the shared ones and forgetting its own.
fn set_own_image(c: &mut WallpaperConfig, on: bool) {
    let key = c.scene.raw().to_string();
    if on == c.has_own_image(c.scene) {
        return;
    }
    if on {
        let img = c.image();
        c.shared_image = Some(img);
        c.scene_image.insert(key, img);
    } else {
        if let Some(shared) = c.shared_image {
            c.set_image(shared);
        }
        c.scene_image.remove(&key);
        c.shared_image = None;
    }
}

// MARK: System

pub fn system_tab(s: &mut Settings, _w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    let c = s.config().clone();
    const RATES: [i64; 4] = [12, 24, 30, 60];
    let fps = s.segmented_row(
        "fps",
        "Frame rate",
        RATES.iter().map(|n| (format!("{n} fps"), *n == c.fps)).collect(),
        |c, i| c.fps = RATES[i],
        cx,
    );
    let performance = Group::titled("Performance").row(fps).footer(
        "Rendering pauses while a full-screen app has the focus. With battery saver on it drops to 12 fps. Larger pixels and lower frame rates use less power.",
    );

    let login = s.login_item;
    let login_switch = gpui_kit::component::switch::Switch::new("login-item")
        .checked(login)
        .color(theme::accent())
        .on_click(cx.listener(|this: &mut Settings, on: &bool, _, cx| {
            match system::set_login_item(*on) {
                Ok(()) => this.login_item = *on,
                Err(e) => this.flash(format!("Couldn't change the startup setting: {e}")),
            }
            this.login_item = system::login_item().is_some();
            cx.notify();
        }));
    let startup = Group::titled("Startup")
        .row(row("Start Deep Field when you sign in", None, login_switch))
        .footer("Adds Deep Field to the apps Windows starts when you sign in (Settings > Apps > Startup lists it too).");

    let path = s.store.path().clone();
    let folder = path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let open_folder = Button::new("open-folder").label("Open Folder").small().on_click(move |_, _, _| system::open(&folder));
    let p2 = path.clone();
    let open_file = Button::new("open-file").label("Edit File").small().on_click(move |_, _, _| {
        let _ = std::process::Command::new("notepad").arg(&p2).spawn();
    });
    let files = Group::titled("Settings file")
        .row(row("config.json", None, div().flex().gap(px(6.0)).child(open_folder).child(open_file)))
        .footer(format!(
            "{}. The wallpaper picks up changes to it within a second, and so does this window.",
            path.display()
        ));

    let confirming = s.confirm_reset_until.is_some();
    let reset = Button::new("reset-all")
        .label(if confirming { "Click Again to Reset Everything" } else { "Reset All Settings..." })
        .small()
        .when(confirming, |b| b.danger())
        .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| {
            if this.confirm_reset_until.is_some() {
                this.confirm_reset_until = None;
                this.edit(cx, |c| *c = WallpaperConfig::default());
                this.flash("Every setting is back to its default");
            } else {
                this.confirm_reset_until = Some(Instant::now() + Duration::from_secs(4));
                cx.notify();
            }
        }));
    let reset = Group::new(None).row(div().py(px(8.0)).flex().child(reset).into_any_element());
    vec![performance.into_element(), startup.into_element(), files.into_element(), reset.into_element()]
}
