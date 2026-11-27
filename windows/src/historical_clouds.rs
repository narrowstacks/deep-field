//! Real clouds for past moments, so a frozen date shows that day's weather and a time-lapse
//! shows the clouds moving (after Rendering/HistoricalClouds.swift). Two free sources:
//!
//! - NASA GIBS geostationary infrared (GOES-West, GOES-East, Himawari), every 10 minutes, kept
//!   for about the last 2.5 months. Used when the visible part of Earth is North America and the
//!   Pacific, which those three satellites cover.
//! - NOAA GridSat-B1, the global geostationary infrared record, every 3 hours since 1980 (up to a
//!   month or two ago), through NCEI's OPeNDAP server.
//!
//! Each frame becomes a cloud cover map (0 clear to 1 thick cloud), cached in
//! %APPDATA%\DeepField\LiveEarth\history. Between two frames the clouds don't fade from one to
//! the next: the motion between them is worked out once (block matching) and the shader carries
//! each frame's clouds along it toward the other, so they drift the way they really moved. The
//! cache files are the same as the Mac's (gray PNG maps, raw little-endian float32 flows).

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use glam::DVec3;

use crate::astronomy;
use crate::earth_maps;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    Gibs,
    Gridsat,
}

impl Source {
    pub fn step(self) -> f64 {
        if self == Source::Gibs { 600.0 } else { 10800.0 }
    }
    pub fn raw(self) -> &'static str {
        if self == Source::Gibs { "gibs" } else { "gridsat" }
    }
}

/// What the shader needs for one moment: the frames either side, the motion between them, and
/// how far between them the moment is (0 at `a`, 1 at `b`).
pub struct Moment {
    pub a: Rc<wgpu::Texture>,
    pub b: Rc<wgpu::Texture>,
    pub flow: Rc<wgpu::Texture>,
    pub fraction: f32,
}

pub const MAP_WIDTH: usize = 2048;
pub const MAP_HEIGHT: usize = 1024;
pub const FLOW_WIDTH: usize = 512;
pub const FLOW_HEIGHT: usize = 256;

pub fn directory() -> PathBuf {
    crate::live_earth_feeds::directory().join("history")
}

// MARK: choosing a source

/// The source for a moment (Unix seconds) seen from above `home` at `distance` Earth radii, or
/// None when the moment is too recent for either (then the live map stands in).
pub fn source(date: f64, home: DVec3, distance: f64, now: f64) -> Option<Source> {
    let age = now - date;
    if age <= 2.0 * 3600.0 {
        return None;
    }
    if age < 70.0 * 86400.0 && covered_by_pacific_satellites(home, distance) {
        return Some(Source::Gibs);
    }
    if age > 20.0 * 86400.0 { Some(Source::Gridsat) } else { None }
}

/// Subsatellite longitudes, degrees: GOES-West, GOES-East, Himawari.
pub const SATELLITES: [(&str, f64); 3] = [
    ("GOES-West_ABI_Band13_Clean_Infrared", -137.0), ("GOES-East_ABI_Band13_Clean_Infrared", -75.2),
    ("Himawari_AHI_Band13_Clean_Infrared", 140.7),
];

/// Whether what we can see below 65 degrees of latitude (where geostationary satellites see
/// well) is within 72 degrees of one of the three satellites: North America and the Pacific.
/// A few points at the far edge may fall outside (from high over California the view reaches
/// round to Iceland); their clouds fade out there.
pub fn covered_by_pacific_satellites(home: DVec3, distance: f64) -> bool {
    let cap = (1.0 / distance.max(1.01)).acos() * 0.92;
    let z = DVec3::Z;
    let mut e1 = z.cross(home);
    if e1.length() < 1e-6 {
        e1 = DVec3::X;
    }
    e1 = crate::math::normalize(e1);
    let e2 = home.cross(e1);
    let mut points = vec![home];
    for k in 0..24 {
        let a = k as f64 / 24.0 * 2.0 * std::f64::consts::PI;
        for r in [cap * 0.5, cap] {
            points.push(r.cos() * home + r.sin() * (a.cos() * e1 + a.sin() * e2));
        }
    }
    let limit = 72.0 * std::f64::consts::PI / 180.0;
    let outside = points
        .iter()
        .filter(|p| {
            if p.z.abs() > (65.0 * std::f64::consts::PI / 180.0).sin() {
                return false;
            }
            !SATELLITES.iter().any(|(_, lon)| {
                let s = astronomy::point(0.0, *lon);
                p.dot(s).max(-1.0).min(1.0).acos() < limit
            })
        })
        .count();
    outside as f64 <= 0.15 * points.len() as f64
}

// MARK: the moment's textures

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Map,
    Flow,
}

fn file_path(kind: Kind, source: Source, t: f64) -> PathBuf {
    let name = format!("{}{}", t as i64, if kind == Kind::Map { ".png" } else { ".flow" });
    directory().join(source.raw()).join(name)
}

/// What the background workers share with the render thread.
#[derive(Default)]
struct Shared {
    pending: HashSet<String>,
    failed: HashMap<String, Instant>,
    colormap: Option<Arc<HashMap<u32, f32>>>,
}

pub struct HistoricalClouds {
    shared: Arc<Mutex<Shared>>,
    textures: RefCell<HashMap<String, Rc<wgpu::Texture>>>,
    order: RefCell<Vec<String>>,
    /// Command-line renders wait for downloads; the app asks in the background and shows the
    /// usual clouds until the frames are in.
    pub blocking: Cell<bool>,
}

impl Default for HistoricalClouds {
    fn default() -> Self {
        HistoricalClouds {
            shared: Arc::default(),
            textures: RefCell::new(HashMap::new()),
            order: RefCell::new(Vec::new()),
            blocking: Cell::new(false),
        }
    }
}

impl HistoricalClouds {
    pub fn moment(&self, date: f64, source: Source, device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Moment> {
        let step = source.step();
        let t0 = (date / step).floor() * step;
        let t1 = t0 + step;
        let fraction = ((date - t0) / step) as f32;
        let a = self.texture(Kind::Map, source, t0, device, queue)?;
        let b = self.texture(Kind::Map, source, t1, device, queue)?;
        let flow = self.texture(Kind::Flow, source, t0, device, queue)?;
        Some(Moment { a, b, flow, fraction })
    }

    fn texture(&self, kind: Kind, source: Source, t: f64, device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Rc<wgpu::Texture>> {
        let key = format!("{}-{}-{}", source.raw(), if kind == Kind::Map { "map" } else { "flow" }, t as i64);
        if let Some(tex) = self.textures.borrow().get(&key) {
            return Some(tex.clone());
        }
        {
            let sh = self.shared.lock().unwrap();
            if sh.failed.get(&key).is_some_and(|when| when.elapsed() < Duration::from_secs(600)) {
                return None;
            }
        }
        if let Some(tex) = load_cached(kind, source, t, device, queue) {
            return Some(self.remember(key, tex));
        }
        if self.blocking.get() {
            produce(kind, source, t, &self.shared);
            if let Some(tex) = load_cached(kind, source, t, device, queue) {
                return Some(self.remember(key, tex));
            }
            self.shared.lock().unwrap().failed.insert(key, Instant::now());
            return None;
        }
        let start = self.shared.lock().unwrap().pending.insert(key.clone());
        if start {
            let shared = self.shared.clone();
            std::thread::spawn(move || {
                produce(kind, source, t, &shared);
                let mut sh = shared.lock().unwrap();
                sh.pending.remove(&key);
                if !file_path(kind, source, t).exists() {
                    sh.failed.insert(key, Instant::now());
                }
            });
        }
        None
    }

    fn remember(&self, key: String, tex: wgpu::Texture) -> Rc<wgpu::Texture> {
        let tex = Rc::new(tex);
        let mut textures = self.textures.borrow_mut();
        let mut order = self.order.borrow_mut();
        textures.insert(key.clone(), tex.clone());
        order.retain(|k| *k != key);
        order.push(key);
        // a time-lapse walks through frames; keep the last few
        while order.len() > 12 {
            let old = order.remove(0);
            textures.remove(&old);
        }
        tex
    }
}

fn load_cached(kind: Kind, source: Source, t: f64, device: &wgpu::Device, queue: &wgpu::Queue) -> Option<wgpu::Texture> {
    let path = file_path(kind, source, t);
    if !path.exists() {
        return None;
    }
    if kind == Kind::Map {
        return earth_maps::load(device, queue, &path, false);
    }
    let data = std::fs::read(&path).ok()?;
    if data.len() != FLOW_WIDTH * FLOW_HEIGHT * 8 {
        return None;
    }
    // half floats, since 32-bit float textures can't be filtered without an extra feature; the
    // motion is a few hundredths of the map at most, so they keep it to well under a texel
    let half: Vec<u16> = data.chunks(4).map(|c| f32_to_f16(f32::from_le_bytes(c.try_into().unwrap()))).collect();
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("cloud flow"),
        size: wgpu::Extent3d { width: FLOW_WIDTH as u32, height: FLOW_HEIGHT as u32, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rg16Float,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        wgpu::ImageCopyTexture { texture: &tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        bytemuck::cast_slice(&half),
        wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(FLOW_WIDTH as u32 * 4), rows_per_image: Some(FLOW_HEIGHT as u32) },
        wgpu::Extent3d { width: FLOW_WIDTH as u32, height: FLOW_HEIGHT as u32, depth_or_array_layers: 1 },
    );
    Some(tex)
}

/// An f32 as IEEE half-float bits, rounded to nearest even.
fn f32_to_f16(v: f32) -> u16 {
    let b = v.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xFF) as i32;
    let man = b & 0x7F_FFFF;
    if exp == 0xFF {
        return sign | 0x7C00 | if man != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1F {
        return sign | 0x7C00;
    }
    if e <= 0 {
        if e < -10 {
            return sign;
        }
        let m = man | 0x80_0000;
        let shift = (14 - e) as u32;
        let half = m >> shift;
        let rem = m & ((1 << shift) - 1);
        let mid = 1 << (shift - 1);
        let round = if rem > mid || (rem == mid && half & 1 == 1) { 1 } else { 0 };
        return sign | (half + round) as u16;
    }
    let half = ((e as u32) << 10) | (man >> 13);
    let rem = man & 0x1FFF;
    let round = if rem > 0x1000 || (rem == 0x1000 && half & 1 == 1) { 1 } else { 0 };
    sign | (half + round) as u16
}

/// Makes the file for a frame's map, or the flow from frame t to the next one.
fn produce(kind: Kind, source: Source, t: f64, shared: &Mutex<Shared>) {
    let path = file_path(kind, source, t);
    if path.exists() {
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    match kind {
        Kind::Map => {
            let cover = if source == Source::Gibs { gibs_cover(t, shared) } else { gridsat_cover(t) };
            let Some(mut cover) = cover else { return };
            // a light blur: the source is sampled every few points, which leaves a speckle
            for _ in 0..2 {
                cover = blur(&cover, MAP_WIDTH, MAP_HEIGHT, 1);
            }
            let px: Vec<u8> = cover.iter().map(|&v| (v.max(0.0).min(1.0) * 255.0 + 0.5) as u8).collect();
            earth_maps::write_gray_png(&path, MAP_WIDTH as u32, MAP_HEIGHT as u32, &px);
        }
        Kind::Flow => {
            produce(Kind::Map, source, t, shared);
            produce(Kind::Map, source, t + source.step(), shared);
            let (Some(a), Some(b)) = (read_gray(&file_path(Kind::Map, source, t)), read_gray(&file_path(Kind::Map, source, t + source.step()))) else { return };
            let flow = optical_flow(&a, &b);
            let bytes: Vec<u8> = flow.iter().flat_map(|v| v.to_le_bytes()).collect();
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }
}

fn read_gray(path: &std::path::Path) -> Option<Vec<u8>> {
    let img = earth_maps::read(path, false)?;
    (img.width as usize == MAP_WIDTH && img.height as usize == MAP_HEIGHT).then_some(img.data)
}

/// Runs `f` on every item, `workers` at a time.
fn parallel(items: &[f64], workers: usize, f: impl Fn(f64) + Sync) {
    let next = AtomicUsize::new(0);
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some(&t) = items.get(i) else { break };
                f(t);
            });
        }
    });
}

/// Fetches every frame and flow a span needs, a few at a time, so parallel renders find them
/// all cached (`--prefetch-history`).
pub fn prefetch(start: f64, seconds: f64, source: Source) {
    let shared = Mutex::new(Shared::default());
    let step = source.step();
    let first = (start / step).floor() * step;
    let last = start + seconds;
    let mut times = Vec::new();
    let mut t = first;
    while t <= last {
        times.push(t);
        t += step;
    }
    let mut maps = times.clone();
    maps.push(t);
    parallel(&maps, 4, |t| produce(Kind::Map, source, t, &shared));
    parallel(&times, 4, |t| produce(Kind::Flow, source, t, &shared));
    let ok = times.iter().filter(|&&t| file_path(Kind::Flow, source, t).exists()).count();
    println!("{}: {} of {} frame pairs ready in {}", source.raw(), ok, times.len(), directory().display());
}

// MARK: brightness temperature to cloud

/// How cloudy a pixel is from its infrared brightness temperature (K). Clouds read colder than
/// the ground under them, and higher, thicker cloud colder still. What "warm ground" means
/// changes with latitude and season (Canada in December is colder than a tropical cloud top),
/// so the threshold follows a rough surface temperature for the place and time of year.
pub fn cover(bt: f32, latitude: f64, day_of_year: f64) -> f32 {
    if !(bt.is_finite() && bt > 150.0) {
        return 0.0;
    }
    let s = (latitude * std::f64::consts::PI / 180.0).sin().abs();
    // +1 in the hemisphere's midwinter, -1 in its midsummer
    let winter = (2.0 * std::f64::consts::PI * (day_of_year - 355.0) / 365.25).cos() * if latitude >= 0.0 { 1.0 } else { -1.0 };
    let surface = 300.0 - 45.0 * s * s - 16.0 * winter * s;
    // a few degrees under the ground starts low cloud; 40 under is thick, high cloud
    let clear = (surface - 6.0) as f32;
    let thick = (surface - 40.0) as f32;
    let x = ((clear - bt) / (clear - thick)).max(0.0).min(1.0);
    // low cloud reads warm but is just as white from above, so thin cover rises quickly
    (x * x * (3.0 - 2.0 * x)).powf(0.7)
}

// MARK: NOAA GridSat-B1

fn gridsat_cover(t: f64) -> Option<Vec<f32>> {
    let (y, m, day, h, ..) = astronomy::civil(t);
    let name = format!("GRIDSAT-B1.{y:04}.{m:02}.{day:02}.{h:02}.v02r01.nc");
    // OPeNDAP's binary form, every other point (0.14 degrees): the packed values as they're
    // stored. (The subset service turns this variable into all missing values.)
    let (stride, rows, cols) = (2usize, 2000usize, 5143usize);
    let constraint = format!("irwin_cdr.irwin_cdr%5B0%5D%5B0:{stride}:{}%5D%5B0:{stride}:{}%5D", rows - 1, cols - 1);
    let url = format!("https://www.ncei.noaa.gov/thredds/dodsC/cdr/gridsat/{y}/{name}.dods?{constraint}");
    let nlat = (rows - 1) / stride + 1;
    let nlon = (cols - 1) / stride + 1;
    let data = download(&url)?;
    let bt = dods_int16(&data, nlat * nlon, 0.01, 200.0, -31999)?;
    let lat: Vec<f32> = (0..nlat).map(|k| (-70.0 + 0.07 * (k * stride) as f64) as f32).collect();
    let lon: Vec<f32> = (0..nlon).map(|k| (-180.0 + 0.07 * (k * stride) as f64) as f32).collect();
    let doy = astronomy::day_of_year(t);
    let (w, hh) = (MAP_WIDTH, MAP_HEIGHT);
    let lat0 = lat[0] as f64;
    let dlat = (lat[1] - lat[0]) as f64;
    let lon0 = lon[0] as f64;
    let dlon = (lon[1] - lon[0]) as f64;
    let mut out = vec![0f32; w * hh];
    for j in 0..hh {
        let la = 90.0 - (j as f64 + 0.5) / hh as f64 * 180.0;
        let row = ((la - lat0) / dlat).round() as i64;
        // the record stops near 70 degrees; fade out toward its edge instead of cutting off
        let edge = ((70.0 - la.abs()) / 4.0).max(0.0).min(1.0) as f32;
        if row < 0 || row >= lat.len() as i64 || edge <= 0.0 {
            continue;
        }
        for i in 0..w {
            let lo = -180.0 + (i as f64 + 0.5) / w as f64 * 360.0;
            let mut col = ((lo - lon0) / dlon).round() as i64 % lon.len() as i64;
            if col < 0 {
                col += lon.len() as i64;
            }
            out[j * w + i] = cover(bt[row as usize * lon.len() + col as usize], la, doy) * edge;
        }
    }
    Some(out)
}

/// The values of a DAP2 binary (.dods) response holding one 16-bit array: after the text
/// header and "Data:", the element count twice, then each value as a 32-bit big-endian integer.
pub fn dods_int16(data: &[u8], count: usize, scale: f32, offset: f32, fill: i32) -> Option<Vec<f32>> {
    let marker = b"\nData:\n";
    let at = data.windows(marker.len()).position(|w| w == marker)?;
    let start = at + marker.len() + 8;
    if data.len() < start + count * 4 {
        return None;
    }
    Some((0..count)
        .map(|k| {
            let o = start + 4 * k;
            let v = i32::from_be_bytes(data[o..o + 4].try_into().unwrap());
            if v != fill { v as f32 * scale + offset } else { f32::NAN }
        })
        .collect())
}

// MARK: NASA GIBS geostationary

/// The UTC time as ISO 8601 (ISO8601DateFormatter's default form).
fn iso8601(t: f64) -> String {
    let (y, m, d, h, mi, s) = astronomy::civil(t);
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn gibs_cover(t: f64, shared: &Mutex<Shared>) -> Option<Vec<f32>> {
    let cmap = load_colormap(shared)?;
    let stamp = iso8601(t);
    let (w, h) = (MAP_WIDTH, MAP_HEIGHT);
    let mut sum = vec![0f32; w * h];
    let mut weight = vec![0f32; w * h];
    let mut any = false;
    // exact colors normally; the nearest colormap color if decoding shifted one slightly
    let mut resolved: HashMap<u32, f32> = HashMap::new();
    let mut celsius = |key: u32| -> f32 {
        if let Some(v) = cmap.get(&key).or_else(|| resolved.get(&key)) {
            return *v;
        }
        let (r, g, b) = ((key >> 16) as i32, (key >> 8 & 255) as i32, (key & 255) as i32);
        let d = |k: u32| {
            let (dr, dg, db) = ((k >> 16) as i32 - r, (k >> 8 & 255) as i32 - g, (k & 255) as i32 - b);
            dr * dr + dg * dg + db * db
        };
        let best = cmap.iter().min_by_key(|(k, _)| d(**k)).map(|(_, v)| *v).unwrap_or(f32::NAN);
        resolved.insert(key, best);
        best
    };
    let doy = astronomy::day_of_year(t);
    for (layer, sat_lon) in SATELLITES {
        let url = format!("https://wvs.earthdata.nasa.gov/api/v1/snapshot?REQUEST=GetSnapshot&TIME={stamp}&BBOX=-90,-180,90,180&CRS=EPSG:4326&LAYERS={layer}&FORMAT=image/png&WIDTH={w}&HEIGHT={h}");
        let Some(data) = download(&url) else { continue };
        let Some(rgba) = decode_rgba(&data, w, h) else { continue };
        any = true;
        let sub = astronomy::point(0.0, sat_lon);
        for j in 0..h {
            let la = 90.0 - (j as f64 + 0.5) / h as f64 * 180.0;
            for i in 0..w {
                let o = (j * w + i) * 4;
                if rgba[o + 3] == 0 {
                    continue;
                }
                let key = (rgba[o] as u32) << 16 | (rgba[o + 1] as u32) << 8 | rgba[o + 2] as u32;
                let c = celsius(key);
                if !c.is_finite() {
                    continue;
                }
                let lo = -180.0 + (i as f64 + 0.5) / w as f64 * 360.0;
                // where satellites overlap, favor the one looking more nearly straight down,
                // and fade each out toward the edge of its view
                let view = astronomy::point(la, lo).dot(sub).max(-1.0).min(1.0).acos() * 180.0 / std::f64::consts::PI;
                let wt = ((76.0 - view) / 14.0).max(0.0).min(1.0) as f32;
                if wt <= 0.0 {
                    continue;
                }
                sum[j * w + i] += wt * cover(c + 273.15, la, doy);
                weight[j * w + i] += wt;
            }
        }
    }
    if !any {
        return None;
    }
    Some(sum.iter().zip(&weight).map(|(&s, &wt)| if wt > 0.0 { s / wt.max(1.0) } else { 0.0 }).collect())
}

/// A downloaded PNG as RGBA at exactly w x h (nearest-neighbor if it came back another size,
/// since exact colors are looked up in the colormap).
fn decode_rgba(data: &[u8], w: usize, h: usize) -> Option<Vec<u8>> {
    let img = earth_maps::decode(data, true)?;
    let (iw, ih) = (img.width as usize, img.height as usize);
    if iw == w && ih == h {
        return Some(img.data);
    }
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let sy = (y * ih / h).min(ih - 1);
        for x in 0..w {
            let sx = (x * iw / w).min(iw - 1);
            out[(y * w + x) * 4..(y * w + x) * 4 + 4].copy_from_slice(&img.data[(sy * iw + sx) * 4..(sy * iw + sx) * 4 + 4]);
        }
    }
    Some(out)
}

/// GIBS paints its infrared frames with a color scale; its colormap gives the temperature
/// (degrees C) behind each color, so the frames turn back into temperatures exactly.
fn load_colormap(shared: &Mutex<Shared>) -> Option<Arc<HashMap<u32, f32>>> {
    if let Some(c) = &shared.lock().unwrap().colormap {
        return Some(c.clone());
    }
    let file = directory().join("band13-colormap.xml");
    let mut data = std::fs::read(&file).ok();
    if data.is_none() {
        if let Some(fetched) = download("https://gibs.earthdata.nasa.gov/colormaps/v1.3/Clean_Longwave_Infrared_Window_Band.xml") {
            let _ = std::fs::create_dir_all(directory());
            let _ = std::fs::write(&file, &fetched);
            data = Some(fetched);
        }
    }
    let map = parse_colormap(&String::from_utf8(data?).ok()?);
    if map.len() <= 100 {
        return None;
    }
    let map = Arc::new(map);
    shared.lock().unwrap().colormap = Some(map.clone());
    Some(map)
}

/// The entries `rgb="R,G,B" ... value="[lo,hi)"` of a GIBS colormap, each color mapped to the
/// middle of its interval (or the one finite end of an open one). Matches the Swift regex
/// `rgb="(\d+),(\d+),(\d+)"[^>]*?value="[\(\[]([-+0-9.INF]+),([-+0-9.INF]+)[\)\]]"`.
pub fn parse_colormap(xml: &str) -> HashMap<u32, f32> {
    let mut map = HashMap::new();
    let mut rest = xml;
    while let Some(at) = rest.find("rgb=\"") {
        rest = &rest[at + 5..];
        let entry = (|| -> Option<(u32, f32)> {
            let end = rest.find('"')?;
            let parts: Vec<&str> = rest[..end].split(',').collect();
            if parts.len() != 3 || !parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())) {
                return None;
            }
            let (r, g, b): (u32, u32, u32) = (parts[0].parse().ok()?, parts[1].parse().ok()?, parts[2].parse().ok()?);
            // the value attribute must come before the tag closes
            let after = &rest[end + 1..];
            let tag = &after[..after.find('>').unwrap_or(after.len())];
            let v = tag.find("value=\"")?;
            let val = &tag[v + 7..];
            let open = val.chars().next()?;
            if open != '(' && open != '[' {
                return None;
            }
            let close = val.find(['"'])?;
            let inner = &val[1..close.checked_sub(1)?];
            let last = val[..close].chars().last()?;
            if last != ')' && last != ']' {
                return None;
            }
            let (lo_s, hi_s) = inner.split_once(',')?;
            let ok = |s: &str| !s.is_empty() && s.chars().all(|c| "-+0123456789.INF".contains(c));
            if !ok(lo_s) || !ok(hi_s) {
                return None;
            }
            let (lo, hi) = (lo_s.parse::<f32>().ok(), hi_s.parse::<f32>().ok());
            let value = match (lo, hi) {
                (Some(l), Some(h)) => (l + h) / 2.0,
                (l, h) => l.or(h).unwrap_or(f32::NAN),
            };
            Some((r << 16 | g << 8 | b, value))
        })();
        if let Some((k, v)) = entry {
            map.insert(k, v);
        }
    }
    map
}

// MARK: optical flow

/// The motion from map a to map b, in texture coordinates per frame step, at flow size. Block
/// matching: for each point, the shift (up to about 3.5 degrees) that best lines up the
/// cloud round it in a with b, then smoothed so neighboring clouds move together and glide
/// instead of jittering. (This finds about what winds aloft carry clouds in a few hours.)
pub fn optical_flow(a: &[u8], b: &[u8]) -> Vec<f32> {
    let (w, h) = (FLOW_WIDTH, FLOW_HEIGHT);
    let (sx, sy) = (MAP_WIDTH / w, MAP_HEIGHT / h);
    let shrink = |m: &[u8]| -> Vec<f32> {
        let mut out = vec![0f32; w * h];
        for j in 0..h {
            for i in 0..w {
                let mut s = 0usize;
                for y in 0..sy {
                    for x in 0..sx {
                        s += m[(j * sy + y) * MAP_WIDTH + i * sx + x] as usize;
                    }
                }
                out[j * w + i] = s as f32 / (sx * sy * 255) as f32;
            }
        }
        out
    };
    let (am, bm) = (shrink(a), shrink(b));
    let (radius, window) = (5i64, 4usize);
    let mut best = vec![f32::MAX; w * h];
    let mut fx = vec![0f32; w * h];
    let mut fy = vec![0f32; w * h];
    let mut diff = vec![0f32; w * h];
    for dy in -radius..=radius {
        for dx in -radius..=radius {
            // how badly b, shifted back by (dx, dy), fails to match a round each point
            for j in 0..h {
                let y = (j as i64 + dy).max(0).min(h as i64 - 1) as usize;
                for i in 0..w {
                    let x = ((i as i64 + dx) % w as i64 + w as i64) as usize % w;
                    let d = am[j * w + i] - bm[y * w + x];
                    diff[j * w + i] = d * d;
                }
            }
            let err = blur(&diff, w, h, window);
            for k in 0..w * h {
                if err[k] < best[k] - 1e-7 {
                    best[k] = err[k];
                    fx[k] = dx as f32;
                    fy[k] = dy as f32;
                }
            }
        }
    }
    for _ in 0..3 {
        fx = blur(&fx, w, h, 3);
        fy = blur(&fy, w, h, 3);
    }
    let mut out = vec![0f32; w * h * 2];
    for k in 0..w * h {
        out[2 * k] = fx[k] / w as f32;
        out[2 * k + 1] = fy[k] / h as f32;
    }
    out
}

/// A box blur of radius r: wrapping east-west, clamped (averaging only what's there) at the poles.
fn blur(v: &[f32], w: usize, h: usize, r: usize) -> Vec<f32> {
    let mut tmp = vec![0f32; v.len()];
    let mut out = vec![0f32; v.len()];
    let r = r as i64;
    for j in 0..h {
        for i in 0..w {
            let mut s = 0f32;
            for d in -r..=r {
                s += v[j * w + ((i as i64 + d) % w as i64 + w as i64) as usize % w];
            }
            tmp[j * w + i] = s / (2 * r + 1) as f32;
        }
    }
    for j in 0..h {
        for i in 0..w {
            let (mut s, mut n) = (0f32, 0f32);
            for d in -r..=r {
                let y = j as i64 + d;
                if y >= 0 && y < h as i64 {
                    s += tmp[y as usize * w + i];
                    n += 1.0;
                }
            }
            out[j * w + i] = s / n;
        }
    }
    out
}

// MARK: files and network

/// A GET with three tries, waiting a little longer after each failure.
fn download(url: &str) -> Option<Vec<u8>> {
    for attempt in 0..3 {
        if let Ok(data) = crate::live_earth_feeds::download(url, Duration::from_secs(90)) {
            return Some(data);
        }
        std::thread::sleep(Duration::from_secs(attempt + 1));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_floats() {
        assert_eq!(f32_to_f16(0.0), 0);
        assert_eq!(f32_to_f16(1.0), 0x3C00);
        assert_eq!(f32_to_f16(-2.0), 0xC000);
        assert_eq!(f32_to_f16(0.5 / 512.0), 0x1400);
        assert_eq!(f32_to_f16(65504.0), 0x7BFF);
        assert_eq!(f32_to_f16(1e-8), 0);
    }

    #[test]
    fn colormap_entries() {
        let xml = r#"<ColorMapEntry rgb="10,20,30" transparent="false" sourceValue="[0,1)" value="[-90.5,-89.5)" label="x"/>
<ColorMapEntry rgb="1,2,3" transparent="false" value="(-INF,-110)" label="y"/>"#;
        let m = parse_colormap(xml);
        assert_eq!(m[&(10 << 16 | 20 << 8 | 30)], -90.0);
        // an open end parses as infinite, so the middle is infinite and is skipped later
        assert!(!m[&(1 << 16 | 2 << 8 | 3)].is_finite());
    }

    #[test]
    fn dods_values() {
        let mut d = b"Dataset { Int16 irwin_cdr[time = 1]; } x;\n\nData:\n".to_vec();
        d.extend_from_slice(&2i32.to_be_bytes());
        d.extend_from_slice(&2i32.to_be_bytes());
        d.extend_from_slice(&1000i32.to_be_bytes());
        d.extend_from_slice(&(-31999i32).to_be_bytes());
        let v = dods_int16(&d, 2, 0.01, 200.0, -31999).unwrap();
        assert_eq!(v[0], 210.0);
        assert!(v[1].is_nan());
    }

    #[test]
    fn choosing_a_source() {
        let now = 1_800_000_000.0;
        let california = astronomy::point(37.0, -120.0);
        let europe = astronomy::point(50.0, 10.0);
        assert_eq!(source(now - 3600.0, california, 4.2, now), None);
        assert_eq!(source(now - 5.0 * 86400.0, california, 4.2, now), Some(Source::Gibs));
        assert_eq!(source(now - 5.0 * 86400.0, europe, 4.2, now), None);
        assert_eq!(source(now - 30.0 * 86400.0, europe, 4.2, now), Some(Source::Gridsat));
    }

    #[test]
    fn flow_finds_a_shift() {
        // a patch of mottled cloud (texture, so the match is unambiguous) moved 3 flow texels east
        let mut a = vec![0u8; MAP_WIDTH * MAP_HEIGHT];
        let mut b = a.clone();
        let cell = |x: usize, y: usize| {
            let mut r = crate::math::Rng::new((x / 4 * 4096 + y / 4) as u64);
            (r.next() > 0.5) as u8 * 255
        };
        for y in 360..520 {
            for x in 760..920 {
                a[y * MAP_WIDTH + x] = cell(x, y);
                b[y * MAP_WIDTH + x + 12] = cell(x, y);
            }
        }
        let f = optical_flow(&a, &b);
        let k = (440 / 4) * FLOW_WIDTH + 840 / 4;
        assert!((f[2 * k] * FLOW_WIDTH as f32 - 3.0).abs() < 0.6, "{}", f[2 * k] * FLOW_WIDTH as f32);
    }
}
