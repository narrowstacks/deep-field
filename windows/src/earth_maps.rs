//! The Earth maps, made by `Design/Earth/make_earth_maps.py` (after Rendering/EarthMaps.swift):
//! NASA's Black Marble city lights and the dim ground under them (Aurora from Orbit and Live
//! Earth), Live Earth's daytime maps, the Moon, the bright star catalog and the Milky Way. Each
//! set is loaded on first use and kept by the renderer, since they're the same for every screen.
//! Also the image decoding and texture upload the live and past cloud maps share.

use std::path::{Path, PathBuf};

/// An 8-bit image: one channel (gray) or four (RGBA), rows top to bottom.
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub data: Vec<u8>,
}

/// The folder holding the maps: `Earth` beside the executable (where a packaged build puts
/// them), or, for a build in the repo, `Resources\Earth` found by walking up from the executable.
pub fn directory() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = exe.canonicalize().unwrap_or(exe);
    let mut dir = exe.parent()?.to_path_buf();
    let beside = dir.join("Earth");
    if beside.join("night-lights.png").exists() {
        return Some(beside);
    }
    for _ in 0..6 {
        let candidate = dir.join("Resources").join("Earth");
        if candidate.join("night-lights.png").exists() {
            return Some(candidate);
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

/// A file in the Earth maps folder (bundled fallbacks for Live Earth's live layers).
pub fn bundled(name: &str) -> Option<PathBuf> {
    directory().map(|d| d.join(name))
}

/// Decodes a PNG or JPEG into gray (`color` false, the luma of a color image) or RGBA.
pub fn decode(bytes: &[u8], color: bool) -> Option<Image> {
    let (w, h, ch, data) = if bytes.starts_with(b"\x89PNG") {
        decode_png(bytes)?
    } else if bytes.starts_with(&[0xFF, 0xD8]) {
        decode_jpeg(bytes)?
    } else {
        return None;
    };
    let n = (w * h) as usize;
    let data = match (ch, color) {
        (1, false) | (4, true) => data,
        (1, true) => data.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        (4, false) => (0..n).map(|i| luma(data[4 * i], data[4 * i + 1], data[4 * i + 2])).collect(),
        _ => return None,
    };
    Some(Image { width: w, height: h, channels: if color { 4 } else { 1 }, data })
}

/// Gray from RGB, with the Rec. 601 weights a gray color space conversion uses.
fn luma(r: u8, g: u8, b: u8) -> u8 {
    (0.299 * r as f32 + 0.587 * g as f32 + 0.114 * b as f32 + 0.5).min(255.0) as u8
}

/// PNG to 8-bit gray or RGBA (width, height, channels, pixels).
fn decode_png(bytes: &[u8]) -> Option<(u32, u32, u32, Vec<u8>)> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    let (w, h) = (info.width, info.height);
    let n = (w * h) as usize;
    let rows = |bpp: usize| -> Vec<u8> {
        // rows may carry padding past width * bpp
        let line = info.line_size;
        (0..h as usize).flat_map(|y| buf[y * line..y * line + w as usize * bpp].to_vec()).collect()
    };
    Some(match info.color_type {
        png::ColorType::Grayscale => (w, h, 1, rows(1)),
        png::ColorType::GrayscaleAlpha => {
            let px = rows(2);
            (w, h, 4, (0..n).flat_map(|i| [px[2 * i], px[2 * i], px[2 * i], px[2 * i + 1]]).collect())
        }
        png::ColorType::Rgb => {
            let px = rows(3);
            (w, h, 4, (0..n).flat_map(|i| [px[3 * i], px[3 * i + 1], px[3 * i + 2], 255]).collect())
        }
        png::ColorType::Rgba => (w, h, 4, rows(4)),
        png::ColorType::Indexed => return None, // EXPAND turns palettes into RGB(A)
    })
}

fn decode_jpeg(bytes: &[u8]) -> Option<(u32, u32, u32, Vec<u8>)> {
    let mut dec = jpeg_decoder::Decoder::new(std::io::Cursor::new(bytes));
    let px = dec.decode().ok()?;
    let info = dec.info()?;
    let (w, h) = (info.width as u32, info.height as u32);
    let n = (w * h) as usize;
    Some(match info.pixel_format {
        jpeg_decoder::PixelFormat::L8 => (w, h, 1, px),
        jpeg_decoder::PixelFormat::RGB24 => (w, h, 4, (0..n).flat_map(|i| [px[3 * i], px[3 * i + 1], px[3 * i + 2], 255]).collect()),
        jpeg_decoder::PixelFormat::CMYK32 => (w, h, 4, (0..n).flat_map(|i| {
            let (c, m, y, k) = (px[4 * i] as u32, px[4 * i + 1] as u32, px[4 * i + 2] as u32, px[4 * i + 3] as u32);
            [(c * k / 255) as u8, (m * k / 255) as u8, (y * k / 255) as u8, 255]
        }).collect()),
        jpeg_decoder::PixelFormat::L16 => (w, h, 1, px.chunks(2).map(|c| c[0]).collect()),
    })
}

pub fn read(path: &Path, color: bool) -> Option<Image> {
    decode(&std::fs::read(path).ok()?, color)
}

/// 8-bit gray pixels as a PNG file, written beside it first and moved into place, so a reader
/// never sees half a file.
pub fn write_gray_png(path: &Path, w: u32, h: u32, px: &[u8]) -> bool {
    let tmp = path.with_extension("tmp");
    let ok = (|| -> Option<()> {
        let file = std::fs::File::create(&tmp).ok()?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
        enc.set_color(png::ColorType::Grayscale);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(px).ok()?;
        writer.finish().ok()?;
        Some(())
    })()
    .is_some();
    ok && std::fs::rename(&tmp, path).is_ok()
}

/// Uploads an image with a full mip chain: gray into r8, color into sRGB rgba8 (so sampling
/// returns linear light). The mips are box filtered on the CPU, color in linear light (Metal's
/// generateMipmaps does the same for an sRGB texture).
pub fn upload(device: &wgpu::Device, queue: &wgpu::Queue, img: &Image, mipmapped: bool) -> wgpu::Texture {
    let color = img.channels == 4;
    let levels = if mipmapped { 32 - img.width.max(img.height).leading_zeros() } else { 1 };
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("earth map"),
        size: wgpu::Extent3d { width: img.width, height: img.height, depth_or_array_layers: 1 },
        mip_level_count: levels,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: if color { wgpu::TextureFormat::Rgba8UnormSrgb } else { wgpu::TextureFormat::R8Unorm },
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let to_linear: Vec<f32> = (0..256).map(|i| srgb_to_linear(i as f32 / 255.0)).collect();
    let (mut w, mut h) = (img.width, img.height);
    let mut level = img.data.clone();
    for mip in 0..levels {
        write_level(queue, &tex, mip, w, h, img.channels, &level);
        if mip + 1 == levels {
            break;
        }
        let (nw, nh) = ((w / 2).max(1), (h / 2).max(1));
        let ch = img.channels as usize;
        let mut next = vec![0u8; (nw * nh) as usize * ch];
        for y in 0..nh as usize {
            let (y0, y1) = ((2 * y).min(h as usize - 1), (2 * y + 1).min(h as usize - 1));
            for x in 0..nw as usize {
                let (x0, x1) = ((2 * x).min(w as usize - 1), (2 * x + 1).min(w as usize - 1));
                for c in 0..ch {
                    let at = |xx: usize, yy: usize| level[(yy * w as usize + xx) * ch + c];
                    let v = if color && c < 3 {
                        let s = to_linear[at(x0, y0) as usize] + to_linear[at(x1, y0) as usize]
                              + to_linear[at(x0, y1) as usize] + to_linear[at(x1, y1) as usize];
                        (linear_to_srgb(s * 0.25) * 255.0 + 0.5) as u8
                    } else {
                        ((at(x0, y0) as u32 + at(x1, y0) as u32 + at(x0, y1) as u32 + at(x1, y1) as u32 + 2) / 4) as u8
                    };
                    next[(y * nw as usize + x) * ch + c] = v;
                }
            }
        }
        level = next;
        w = nw;
        h = nh;
    }
    tex
}

fn write_level(queue: &wgpu::Queue, tex: &wgpu::Texture, mip: u32, w: u32, h: u32, channels: u32, data: &[u8]) {
    queue.write_texture(
        wgpu::ImageCopyTexture { texture: tex, mip_level: mip, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        data,
        wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(w * channels), rows_per_image: Some(h) },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
}

fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn linear_to_srgb(c: f32) -> f32 {
    let c = c.max(0.0).min(1.0);
    if c <= 0.0031308 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

/// A file into a mipmapped texture, or None when it's missing or unreadable.
pub fn load(device: &wgpu::Device, queue: &wgpu::Queue, path: &Path, color: bool) -> Option<wgpu::Texture> {
    read(path, color).map(|img| upload(device, queue, &img, true))
}

/// City lights and the ground under them.
pub struct NightTextures {
    pub lights: wgpu::Texture,
    pub ground: wgpu::Texture,
}

pub fn night(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<NightTextures> {
    let dir = directory();
    let maps = dir.as_ref().and_then(|d| Some(NightTextures {
        lights: load(device, queue, &d.join("night-lights.png"), false)?,
        ground: load(device, queue, &d.join("night-ground.png"), false)?,
    }));
    if maps.is_none() {
        eprintln!("deepfield: Earth maps not found, the Aurora scene draws a made-up Earth");
    }
    maps
}

/// Live Earth's daytime surface (January and July), open water and the Moon.
pub struct DayTextures {
    pub january: wgpu::Texture,
    pub july: wgpu::Texture,
    pub water: wgpu::Texture,
    pub moon: wgpu::Texture,
}

pub fn day(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<DayTextures> {
    let dir = directory();
    let maps = dir.as_ref().and_then(|d| Some(DayTextures {
        january: load(device, queue, &d.join("day-jan.jpg"), true)?,
        july: load(device, queue, &d.join("day-jul.jpg"), true)?,
        water: load(device, queue, &d.join("water.png"), false)?,
        moon: load(device, queue, &d.join("moon.png"), false)?,
    }));
    if maps.is_none() {
        eprintln!("deepfield: daytime Earth maps not found, Live Earth draws a made-up Earth");
    }
    maps
}

/// The real sky for Live Earth: the bright star catalog splatted into an equirectangular map
/// (column 0 at right ascension 0, increasing east; row 0 at declination +90), and the Milky
/// Way's glow on the same grid.
pub struct SkyTextures {
    pub stars: wgpu::Texture,
    pub milky_way: wgpu::Texture,
}

pub const STAR_MAP_WIDTH: u32 = 4096;

pub fn sky(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<SkyTextures> {
    let dir = directory();
    let maps = dir.as_ref().and_then(|d| Some(SkyTextures {
        stars: star_map(device, queue, &d.join("stars.bin"))?,
        milky_way: load(device, queue, &d.join("milkyway.jpg"), true)?,
    }));
    if maps.is_none() {
        eprintln!("deepfield: star catalog not found, Live Earth shows the usual starfield");
    }
    maps
}

/// The catalog (little-endian float32 records: right ascension, declination, V magnitude, B-V)
/// as RGBA pixels: each star in the texel holding its position (the brighter one where two
/// share a texel), rgb its color from the B-V index, a its magnitude as (7 - V) / 9.
pub fn star_pixels(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() < 16 {
        return None;
    }
    let (w, h) = (STAR_MAP_WIDTH as usize, STAR_MAP_WIDTH as usize / 2);
    let mut pixels = vec![0u8; w * h * 4];
    let f = |k: usize| f32::from_le_bytes(data[4 * k..4 * k + 4].try_into().unwrap()) as f64;
    for i in 0..data.len() / 16 {
        let (ra, dec, v, bv) = (f(4 * i), f(4 * i + 1), f(4 * i + 2), f(4 * i + 3));
        let x = ((ra / (2.0 * std::f64::consts::PI) * w as f64) as i64).min(w as i64 - 1).max(0) as usize;
        let y = (((0.5 - dec / std::f64::consts::PI) * h as f64) as i64).max(0).min(h as i64 - 1) as usize;
        let a = (((7.0 - v) / 9.0).max(0.0).min(1.0) * 255.0) as u8;
        let o = (y * w + x) * 4;
        if a <= pixels[o + 3] {
            continue;
        }
        let c = star_color(bv);
        pixels[o] = (c[0] * 255.0) as u8;
        pixels[o + 1] = (c[1] * 255.0) as u8;
        pixels[o + 2] = (c[2] * 255.0) as u8;
        pixels[o + 3] = a;
    }
    Some(pixels)
}

fn star_map(device: &wgpu::Device, queue: &wgpu::Queue, path: &Path) -> Option<wgpu::Texture> {
    let pixels = star_pixels(&std::fs::read(path).ok()?)?;
    let (w, h) = (STAR_MAP_WIDTH, STAR_MAP_WIDTH / 2);
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("star map"),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    write_level(queue, &tex, 0, w, h, 4, &pixels);
    Some(tex)
}

/// A star's color from its B-V index: the temperature by Ballesteros' formula, then a
/// blackbody's color, normalized so the brightest channel is 1 and pushed a little toward
/// saturation so the colors read at a pixel's size.
fn star_color(bv: f64) -> [f64; 3] {
    let b = bv.max(-0.4).min(2.0);
    let t = 4600.0 * (1.0 / (0.92 * b + 1.7) + 1.0 / (0.92 * b + 0.62));
    // Planck's law at 610, 550 and 465 nm, relative
    let planck = |nm: f64| 1.0 / ((nm * 1e-9).powi(5) * ((1.4388e-2 / (nm * 1e-9 * t)).exp() - 1.0));
    let mut c = [planck(610.0), planck(550.0), planck(465.0)];
    let mx = c[0].max(c[1]).max(c[2]);
    c = c.map(|v| v / mx);
    let mean = (c[0] + c[1] + c[2]) / 3.0;
    c = c.map(|v| (mean + (v - mean) * 1.6).max(0.05).min(1.0));
    let mx = c[0].max(c[1]).max(c[2]);
    c.map(|v| v / mx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_repo_maps_and_decodes_them() {
        // the test binary lives under windows\target, so the walk up reaches Resources\Earth
        let Some(dir) = directory() else { return };
        let g = read(&dir.join("aurora-fallback.png"), false).unwrap();
        assert_eq!((g.width, g.height, g.channels), (360, 181, 1));
        let c = read(&dir.join("milkyway.jpg"), true).unwrap();
        assert_eq!((c.width, c.height, c.channels), (1024, 512, 4));
        let stars = star_pixels(&std::fs::read(dir.join("stars.bin")).unwrap()).unwrap();
        assert!(stars.chunks(4).filter(|p| p[3] > 0).count() > 5000);
    }

    #[test]
    fn hot_stars_are_blue() {
        let c = star_color(-0.3);
        assert!(c[2] >= c[0]);
        let c = star_color(1.6);
        assert!(c[0] >= c[2]);
    }
}
