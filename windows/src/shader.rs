//! WGSL source, joined per module in dependency order and compiled when the app starts (like the
//! macOS app's Metal source). `check` validates every module with naga and prints readable
//! errors, so a broken shader shows up without starting the GPU.

macro_rules! wgsl {
    ($name:literal) => {
        ($name, include_str!(concat!("../shaders/", $name)))
    };
}

type Part = (&'static str, &'static str);

/// The bake kernels and the sky pass.
pub const BAKE: &[Part] = &[
    wgsl!("common.wgsl"),
    wgsl!("bake_bindings.wgsl"),
    wgsl!("sky_common.wgsl"),
    wgsl!("sky_bake.wgsl"),
    wgsl!("bake.wgsl"),
];

/// Every scene's fragment shader, reading the frame bindings.
pub const FRAME: &[Part] = &[
    wgsl!("common.wgsl"),
    wgsl!("frame_bindings.wgsl"),
    wgsl!("output.wgsl"),
    wgsl!("sky_common.wgsl"),
    wgsl!("sky_frame.wgsl"),
    wgsl!("planets.wgsl"),
    wgsl!("lensed.wgsl"),
    wgsl!("stars.wgsl"),
    wgsl!("gas_giant.wgsl"),
];

/// Bloom's bright pass, downsample and blur, and the composite that tone maps after it.
pub const BLOOM: &[Part] = &[
    wgsl!("common.wgsl"),
    wgsl!("output.wgsl"),
    wgsl!("bloom.wgsl"),
];

/// The nearest-neighbor upscale onto a screen.
pub const PRESENT: &[Part] = &[
    wgsl!("common.wgsl"),
    wgsl!("present.wgsl"),
];

pub fn join(parts: &[Part]) -> String {
    let mut s = String::new();
    for (name, src) in parts {
        s.push_str(&format!("// ===== {name} =====\n"));
        s.push_str(src);
        s.push('\n');
    }
    s
}

/// Which file and line a line of the joined source came from.
fn locate(parts: &[Part], line: usize) -> (String, usize) {
    let mut start = 1;
    for (name, src) in parts {
        let n = src.lines().count() + 2; // header + trailing newline
        if line < start + n {
            return (name.to_string(), line.saturating_sub(start));
        }
        start += n;
    }
    ("?".into(), line)
}

/// Parses and validates a module; Err holds a readable report with file names and lines.
pub fn validate(label: &str, parts: &[Part]) -> Result<(), String> {
    let src = join(parts);
    let module = naga::front::wgsl::parse_str(&src).map_err(|e| {
        let mut msg = e.emit_to_string_with_path(&src, label);
        if let Some(loc) = e.location(&src) {
            let (file, l) = locate(parts, loc.line_number as usize);
            msg.push_str(&format!("\n  -> in {file}, line {l}\n"));
        }
        msg
    })?;
    let mut v = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all());
    v.validate(&module).map_err(|e| {
        let mut msg = e.emit_to_string_with_path(&src, label);
        if let Some((span, _)) = e.spans().next() {
            let loc = span.location(&src);
            let (file, l) = locate(parts, loc.line_number as usize);
            msg.push_str(&format!("\n  -> in {file}, line {l}\n"));
        }
        msg
    })?;
    Ok(())
}

/// `--check-shaders`: validates every module, printing each error.
pub fn check() -> bool {
    let mut ok = true;
    for (label, parts) in [("bake", BAKE), ("frame", FRAME), ("bloom", BLOOM), ("present", PRESENT)] {
        match validate(label, parts) {
            Ok(()) => println!("{label}: ok"),
            Err(e) => {
                ok = false;
                println!("{label}: FAILED\n{e}");
            }
        }
    }
    ok
}
