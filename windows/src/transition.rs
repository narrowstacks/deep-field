//! How one look gives way to the next when the schedule switches (TransitionStyle in
//! Config/Schedule.swift, drawn by `transitionFragment`).

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransitionStyle {
    Dissolve,
    Crossfade,
    Pan,
    DriftAway,
    Warp,
    BlackHole,
    Random,
}

impl TransitionStyle {
    pub const ALL: [TransitionStyle; 7] = [
        TransitionStyle::Dissolve, TransitionStyle::Crossfade, TransitionStyle::Pan, TransitionStyle::DriftAway,
        TransitionStyle::Warp, TransitionStyle::BlackHole, TransitionStyle::Random,
    ];

    /// The styles Random picks from.
    pub const CONCRETE: [TransitionStyle; 6] = [
        TransitionStyle::Dissolve, TransitionStyle::Crossfade, TransitionStyle::Pan, TransitionStyle::DriftAway,
        TransitionStyle::Warp, TransitionStyle::BlackHole,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            TransitionStyle::Dissolve => "dissolve",
            TransitionStyle::Crossfade => "crossfade",
            TransitionStyle::Pan => "pan",
            TransitionStyle::DriftAway => "driftAway",
            TransitionStyle::Warp => "warp",
            TransitionStyle::BlackHole => "blackHole",
            TransitionStyle::Random => "random",
        }
    }

    pub fn from_raw(s: &str) -> Option<TransitionStyle> {
        Self::ALL.into_iter().find(|t| t.raw().eq_ignore_ascii_case(s))
    }

    pub fn title(self) -> &'static str {
        match self {
            TransitionStyle::Dissolve => "Dissolve",
            TransitionStyle::Crossfade => "Crossfade",
            TransitionStyle::Pan => "Pan",
            TransitionStyle::DriftAway => "Drift Away",
            TransitionStyle::Warp => "Warp",
            TransitionStyle::BlackHole => "Black Hole",
            TransitionStyle::Random => "Random",
        }
    }

    pub fn help(self) -> &'static str {
        match self {
            TransitionStyle::Dissolve => "The new scene grows in from soft, dithered patches",
            TransitionStyle::Crossfade => "One scene fades into the other",
            TransitionStyle::Pan => "The camera slides over to the new scene",
            TransitionStyle::DriftAway => "The old scene's objects float off into the distance as the new one settles in",
            TransitionStyle::Warp => "Fly forward through the old scene into the new one",
            TransitionStyle::BlackHole => "A black hole sweeps across, bending light, with the new scene behind it",
            TransitionStyle::Random => "A different transition each time",
        }
    }

    /// Random becomes one of the others, picked when a transition starts.
    pub fn resolved(self) -> TransitionStyle {
        if self != TransitionStyle::Random {
            return self;
        }
        let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
        Self::CONCRETE[n as usize % Self::CONCRETE.len()]
    }

    /// Which effect `transitionFragment` draws: the place among the concrete styles.
    pub fn shader_index(self) -> f32 {
        Self::CONCRETE.iter().position(|&t| t == self).unwrap_or(0) as f32
    }
}
