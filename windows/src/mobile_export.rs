//! Phone wallpapers (Mobile/MobileExport.swift): the current scene recomposed in portrait, as a
//! still and as a short loop that runs smoothly into itself. The Mac pairs the loop with the
//! still as a Live Photo (a HEIC and a QuickTime movie sharing Apple's content identifier, added
//! to Photos); that needs Apple's frameworks, so here the loop is an H.264 MP4, written with
//! Media Foundation, that a phone can play or set as a video wallpaper.

use std::path::Path;

use crate::config::{DitherPattern, Frequency, PhoneFraming, SceneKind, WallpaperConfig};
use crate::renderer::Renderer;

/// An iPhone screen, in portrait pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhoneModel {
    /// for `--device`
    pub key: &'static str,
    pub name: &'static str,
    pub width: u32,
    pub height: u32,
}

pub const PHONES: [PhoneModel; 10] = [
    PhoneModel { key: "17-pro-max", name: "iPhone 17 Pro Max, 16 Pro Max", width: 1320, height: 2868 },
    PhoneModel { key: "air", name: "iPhone Air", width: 1260, height: 2736 },
    PhoneModel { key: "17-pro", name: "iPhone 17, 17 Pro, 16 Pro", width: 1206, height: 2622 },
    PhoneModel { key: "16-plus", name: "iPhone 16 Plus, 15 Plus, 15 Pro Max, 14 Pro Max", width: 1290, height: 2796 },
    PhoneModel { key: "16", name: "iPhone 16, 15, 15 Pro, 14 Pro", width: 1179, height: 2556 },
    PhoneModel { key: "16e", name: "iPhone 16e, 14, 13, 13 Pro, 12, 12 Pro", width: 1170, height: 2532 },
    PhoneModel { key: "14-plus", name: "iPhone 14 Plus, 13 Pro Max, 12 Pro Max", width: 1284, height: 2778 },
    PhoneModel { key: "13-mini", name: "iPhone 13 mini, 12 mini", width: 1080, height: 2340 },
    PhoneModel { key: "11", name: "iPhone 11, XR", width: 828, height: 1792 },
    PhoneModel { key: "se", name: "iPhone SE (2nd and 3rd generation)", width: 750, height: 1334 },
];

/// What the Phone section (or `--mobile-export`) asks for, on top of the current scene settings.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MobileOptions {
    pub width: u32,
    pub height: u32,
    pub smooth: bool,
    /// 0 = automatic
    pub pixel_size: i64,
    pub framing: PhoneFraming,
    /// How much faster than the wallpaper the loop moves (its 3 s would barely show the
    /// wallpaper's slow drift).
    pub motion_speed: f64,
}

impl Default for MobileOptions {
    fn default() -> MobileOptions {
        MobileOptions {
            width: 1320, height: 2868, smooth: false, pixel_size: 0, framing: PhoneFraming::default(), motion_speed: 2.0,
        }
    }
}

/// Per side; the video encoders' limits are well above this.
pub const SIZE_RANGE: (u32, u32) = (320, 4096);

pub fn clamped_side(v: u32) -> u32 {
    v.clamp(SIZE_RANGE.0, SIZE_RANGE.1)
}

/// The pixel sizes offered besides Auto.
pub const PIXEL_SIZES: [i64; 6] = [2, 3, 4, 5, 6, 8];

impl MobileOptions {
    /// The cell size used when `pixel_size` is automatic. A phone sits about twice as close as a
    /// desktop display at about twice the density, so the wallpaper's own cell size would look
    /// about the same; one notch larger keeps the dither readable on the small screen.
    pub fn auto_pixel_size(desktop: i64) -> i64 {
        ((desktop as f64 * 1.34).round() as i64).clamp(2, 12)
    }

    pub fn resolved_pixel_size(&self, desktop: i64) -> i64 {
        if self.pixel_size > 0 { self.pixel_size.min(16) } else { Self::auto_pixel_size(desktop) }
    }
}

/// The loop's motion: `duration` seconds at `fps`, with the still in the middle, covering
/// `speed` times as much scene time. The last `fade` seconds dissolve into the frames before the
/// start, so it loops.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Loop {
    pub duration: f64,
    pub fps: u32,
    pub fade: f64,
    pub speed: f64,
}

impl Loop {
    pub fn frames(&self) -> u32 {
        (self.duration * self.fps as f64).round() as u32
    }
    pub fn still_offset(&self) -> f64 {
        self.duration / 2.0
    }
}

/// Everything needed to render: the adjusted config, the output size, and the shaded size.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub config: WallpaperConfig,
    pub width: u32,
    pub height: u32,
    /// output pixels per shaded pixel
    pub factor: u32,
    /// crisp cells (dithered) or smooth upscaling
    pub nearest: bool,
    pub still_time: f64,
    pub loop_: Loop,
}

impl Plan {
    pub fn shaded(&self) -> (u32, u32) {
        (self.width.div_ceil(self.factor), self.height.div_ceil(self.factor))
    }
}

pub fn plan(base: &WallpaperConfig, o: &MobileOptions) -> Plan {
    let mut c = base.clone();
    c.lock_screen_still = false;
    c.phone_framing = Some(o.framing);
    // only continuous motion: no transient events of any kind
    c.supernovae = Frequency::Off;
    c.comets = Frequency::Off;
    c.wormhole_events = Frequency::Off;
    c.comet_events = Frequency::Off;
    c.star_flares = Frequency::Off;
    let (w, h) = (clamped_side(o.width), clamped_side(o.height));
    let factor = if o.smooth {
        c.pixel_size = 1;
        c.levels = 256;
        c.dither = DitherPattern::Bayer8;
        ((w as f64 * h as f64 / crate::lock_screen::MAX_SHADED_PIXELS).sqrt().ceil() as u32).max(1)
    } else {
        let f = o.resolved_pixel_size(base.pixel_size);
        c.pixel_size = f;
        f as u32
    };
    c.lock_screen_smooth = false;
    Plan { still_time: still_time(&c), loop_: loop_for(&c, o.motion_speed), config: c, width: w, height: h, factor,
           nearest: !o.smooth }
}

/// The lock screen still's moment, except that the binary pair is caught further apart across
/// the narrow frame (there the lock screen's moment has one star behind the other).
pub fn still_time(c: &WallpaperConfig) -> f64 {
    if c.scene == SceneKind::Binary {
        0.62 * c.star_orbit_minutes * 60.0
    } else {
        crate::lock_screen::representative_time(c)
    }
}

/// About 3 s. The pulsar's loop is a whole number of turns, so its beams come round exactly.
pub fn loop_for(c: &WallpaperConfig, speed: f64) -> Loop {
    let speed = speed.clamp(0.25, 8.0);
    let mut d = 3.0;
    if c.scene == SceneKind::Pulsar {
        let p = c.pulsar_period.max(0.2) / speed;
        let turns = (3.0 / p).round().max(1.0);
        if turns * p >= 1.5 && turns * p <= 4.0 {
            d = turns * p;
        }
    }
    Loop { duration: d, fps: 30, fade: d * 0.3, speed }
}

/// A file name for the current scene and size, e.g. "Deep Field Black Hole 1320x2868".
pub fn base_name(plan: &Plan) -> String {
    format!("Deep Field {} {}x{}", plan.config.scene.title(), plan.width, plan.height)
}

// MARK: rendering

/// Many frames of one config from a single bake, at the shaded size.
pub struct Sequence<'a> {
    r: &'a Renderer,
    config: WallpaperConfig,
    baked: crate::renderer::Baked,
    target: wgpu::Texture,
    events: crate::events::EventSchedule,
}

impl<'a> Sequence<'a> {
    pub fn new(r: &'a Renderer, plan: &Plan) -> Sequence<'a> {
        let (w, h) = plan.shaded();
        let mut events = crate::events::EventSchedule::new(1);
        events.enabled = false;
        Sequence {
            r,
            config: plan.config.clone(),
            baked: r.bake(w, h, &plan.config, None),
            target: r.make_target(w, h, wgpu::TextureUsages::COPY_SRC),
            events,
        }
    }

    /// The frame at `time`, with planets and star orbits held at `orbit_time`, as RGBA rows.
    pub fn frame(&self, time: f64, orbit_time: f64) -> Vec<u8> {
        let mut enc = self.r.device.create_command_encoder(&Default::default());
        self.r.encode_frame_orbit(&mut enc, &self.target, &self.baked, time, &self.config, &self.events,
                                  &Default::default(), Some(orbit_time));
        self.r.queue.submit([enc.finish()]);
        self.r.read_rgba(&self.target)
    }
}

/// The portrait still at the output size, as RGBA rows.
pub fn render_still(r: &Renderer, plan: &Plan) -> Vec<u8> {
    let cells = Sequence::new(r, plan).frame(plan.still_time, plan.still_time);
    upscale(&cells, plan)
}

pub fn upscale(cells: &[u8], plan: &Plan) -> Vec<u8> {
    let (w, h) = plan.shaded();
    crate::capture::upscaled(cells, w, h, plan.factor, plan.width, plan.height, plan.nearest)
}

const BAYER8: [u8; 64] = [
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
    3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
];

/// `a` moving towards `b` by `weight`: cell by cell along an ordered-dither threshold when
/// dithered (every cell keeps a palette color), a plain cross-fade when smooth.
pub fn dissolve(a: &mut [u8], b: &[u8], w: u32, weight: f64, cells: bool) {
    if cells {
        // a cell switches to b once the weight passes its threshold
        let level = (weight * 64.0) as u8;
        for (i, (pa, pb)) in a.chunks_exact_mut(4).zip(b.chunks_exact(4)).enumerate() {
            let (x, y) = (i as u32 % w, i as u32 / w);
            if BAYER8[((y & 7) * 8 + (x & 7)) as usize] < level {
                pa[..3].copy_from_slice(&pb[..3]);
            }
        }
    } else {
        let k = weight as f32;
        for (pa, pb) in a.iter_mut().zip(b) {
            *pa = (*pa as f32 * (1.0 - k) + *pb as f32 * k).round() as u8;
        }
    }
}

/// Calls `body` with each frame of the loop at the shaded size, in order. Frames in the last
/// `fade` seconds dissolve into the frames one loop earlier, so the last frame leads into the
/// first.
pub fn render_loop(r: &Renderer, plan: &Plan, mut body: impl FnMut(u32, Vec<u8>) -> Result<(), String>)
                   -> Result<(), String> {
    let l = plan.loop_;
    let seq = Sequence::new(r, plan);
    let k = l.speed;
    let (start, orbit) = (plan.still_time - l.still_offset() * k, plan.still_time);
    let fade_start = l.duration - l.fade;
    for i in 0..l.frames() {
        let tau = i as f64 / l.fps as f64;
        let mut a = seq.frame(start + tau * k, orbit);
        if tau > fade_start {
            let x = (tau - fade_start) / l.fade;
            let weight = x * x * (3.0 - 2.0 * x);
            let b = seq.frame(start + (tau - l.duration) * k, orbit);
            dissolve(&mut a, &b, plan.shaded().0, weight, plan.nearest);
        }
        body(i, a)?;
    }
    Ok(())
}

/// Writes the loop as an H.264 MP4 at the output size, `repeats` times over (one loop to use as
/// a video wallpaper, more for a preview to share). `progress` gets the fraction done.
pub fn write_movie(r: &Renderer, plan: &Plan, path: &Path, repeats: u32, mut progress: impl FnMut(f64))
                   -> Result<(), String> {
    let _ = std::fs::remove_file(path);
    // 4:2:0 video needs even sizes; an odd last column or row is left out (iPhone 16: 1179)
    let (w, h) = (plan.width & !1, plan.height & !1);
    let fps = plan.loop_.fps;
    let mut movie = mp4::Writer::new(path, w, h, fps, (w as f64 * h as f64 * fps as f64 * 0.25) as u32)?;
    let frames = plan.loop_.frames();
    let total = frames * repeats.max(1);
    // repeats reuse the shaded frames (small) instead of rendering them again
    let mut cached: Vec<Vec<u8>> = Vec::new();
    let mut index = 0u32;
    let mut append = |shaded: &[u8], movie: &mut mp4::Writer| -> Result<(), String> {
        let full = upscale(shaded, plan);
        movie.write_frame(&full, plan.width, index)?;
        index += 1;
        progress(index as f64 / total as f64);
        Ok(())
    };
    render_loop(r, plan, |_, frame| {
        append(&frame, &mut movie)?;
        if repeats > 1 {
            cached.push(frame);
        }
        Ok(())
    })?;
    for _ in 1..repeats.max(1) {
        for frame in &cached {
            append(frame, &mut movie)?;
        }
    }
    movie.finish()
}

mod mp4 {
    //! Media Foundation's sink writer: BGRA frames in, H.264 in an MP4 out. The sink writer puts
    //! in the color conversion the encoder needs, and uses the GPU's encoder when it has one.

    use std::path::Path;

    use windows::core::HSTRING;
    use windows::Win32::Media::MediaFoundation::*;
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    pub struct Writer {
        sink: IMFSinkWriter,
        stream: u32,
        width: u32,
        height: u32,
        fps: u32,
    }

    fn err(e: windows::core::Error) -> String {
        e.message().to_string()
    }

    impl Writer {
        pub fn new(path: &Path, width: u32, height: u32, fps: u32, bit_rate: u32) -> Result<Writer, String> {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                MFStartup(MF_VERSION, MFSTARTUP_FULL).map_err(err)?;
                let mut attrs: Option<IMFAttributes> = None;
                MFCreateAttributes(&mut attrs, 2).map_err(err)?;
                let attrs = attrs.ok_or("no attributes")?;
                attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1).map_err(err)?;
                let sink = MFCreateSinkWriterFromURL(&HSTRING::from(path.as_os_str()), None, &attrs).map_err(err)?;

                let size = ((width as u64) << 32) | height as u64;
                let rate = ((fps as u64) << 32) | 1;
                let square = (1u64 << 32) | 1;
                let out = MFCreateMediaType().map_err(err)?;
                out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(err)?;
                out.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(err)?;
                out.SetUINT32(&MF_MT_AVG_BITRATE, bit_rate).map_err(err)?;
                out.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(err)?;
                // Main profile: what every phone plays
                out.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main.0 as u32).map_err(err)?;
                out.SetUINT64(&MF_MT_FRAME_SIZE, size).map_err(err)?;
                out.SetUINT64(&MF_MT_FRAME_RATE, rate).map_err(err)?;
                out.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, square).map_err(err)?;
                // tagged as the Mac's movies are: BT.709 primaries, transfer and matrix
                out.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32).map_err(err)?;
                out.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32).map_err(err)?;
                out.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32).map_err(err)?;
                let stream = sink.AddStream(&out).map_err(err)?;

                let input = MFCreateMediaType().map_err(err)?;
                input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(err)?;
                input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32).map_err(err)?;
                input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(err)?;
                input.SetUINT64(&MF_MT_FRAME_SIZE, size).map_err(err)?;
                input.SetUINT64(&MF_MT_FRAME_RATE, rate).map_err(err)?;
                input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, square).map_err(err)?;
                // a positive stride: rows top first (RGB in Media Foundation is otherwise bottom up)
                input.SetUINT32(&MF_MT_DEFAULT_STRIDE, width * 4).map_err(err)?;
                sink.SetInputMediaType(stream, &input, None).map_err(err)?;
                sink.BeginWriting().map_err(err)?;
                Ok(Writer { sink, stream, width, height, fps })
            }
        }

        /// One frame from RGBA rows `stride` pixels wide (at least the movie's width).
        pub fn write_frame(&mut self, rgba: &[u8], stride: u32, index: u32) -> Result<(), String> {
            let (w, h) = (self.width as usize, self.height as usize);
            let len = (w * h * 4) as u32;
            unsafe {
                let buffer = MFCreateMemoryBuffer(len).map_err(err)?;
                let mut data: *mut u8 = std::ptr::null_mut();
                buffer.Lock(&mut data, None, None).map_err(err)?;
                let out = std::slice::from_raw_parts_mut(data, len as usize);
                for y in 0..h {
                    let src = &rgba[y * stride as usize * 4..][..w * 4];
                    let dst = &mut out[y * w * 4..][..w * 4];
                    // RGB32 is B, G, R, X in memory
                    for (d, s) in dst.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
                        d[0] = s[2];
                        d[1] = s[1];
                        d[2] = s[0];
                        d[3] = 255;
                    }
                }
                buffer.Unlock().map_err(err)?;
                buffer.SetCurrentLength(len).map_err(err)?;
                let sample = MFCreateSample().map_err(err)?;
                sample.AddBuffer(&buffer).map_err(err)?;
                // in 100 ns units
                let tick = 10_000_000i64 / self.fps as i64;
                sample.SetSampleTime(index as i64 * 10_000_000 / self.fps as i64).map_err(err)?;
                sample.SetSampleDuration(tick).map_err(err)?;
                self.sink.WriteSample(self.stream, &sample).map_err(err)
            }
        }

        pub fn finish(self) -> Result<(), String> {
            unsafe {
                let done = self.sink.Finalize().map_err(err);
                let _ = MFShutdown();
                done
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_follow_the_mac() {
        let mut c = WallpaperConfig::default();
        c.pixel_size = 3;
        let p = plan(&c, &MobileOptions::default());
        // the automatic cell size is one notch above the desktop's
        assert_eq!(p.factor, 4);
        assert_eq!(p.shaded(), (330, 717));
        assert_eq!(p.config.supernovae, Frequency::Off);
        assert_eq!(p.loop_.frames(), 90);
        let smooth = plan(&c, &MobileOptions { smooth: true, ..Default::default() });
        // 1320 x 2868 is under the smooth shading cap, so it shades every pixel
        assert_eq!(smooth.factor, 1);
        assert_eq!(smooth.config.levels, 256);
        // a pulsar loop is whole turns long
        c.set_scene(SceneKind::Pulsar);
        let l = loop_for(&c, 2.0);
        let turns = l.duration / (c.pulsar_period / 2.0);
        assert!((turns - turns.round()).abs() < 1e-9, "{turns} turns");
        assert_eq!(clamped_side(100), 320);
    }

    #[test]
    fn dissolve_switches_whole_cells() {
        let mut a = vec![0u8; 8 * 8 * 4];
        let b = vec![200u8; 8 * 8 * 4];
        dissolve(&mut a, &b, 8, 0.5, true);
        let switched = a.chunks_exact(4).filter(|p| p[0] == 200).count();
        assert_eq!(switched, 32, "half the cells");
        assert!(a.chunks_exact(4).all(|p| p[0] == 0 || p[0] == 200), "a cell between colors");
    }

    #[test]
    fn upscale_keeps_crisp_cells_from_the_top_left() {
        let cells = [0u8, 0, 0, 255, 200, 100, 50, 255];
        let crisp = crate::capture::upscaled(&cells, 2, 1, 3, 5, 2, true);
        assert_eq!(&crisp[8..12], &[0, 0, 0, 255]);
        assert_eq!(&crisp[12..16], &[200, 100, 50, 255]);
        let smooth = crate::capture::upscaled(&cells, 2, 1, 2, 4, 1, false);
        // the second pixel sits a quarter of the way from the first cell's center to the second's
        assert_eq!(smooth[4], 50);
    }
}

#[cfg(test)]
mod movie_tests {
    use super::*;
    use windows::core::HSTRING;
    use windows::Win32::Media::MediaFoundation::*;

    /// Decodes every frame of `path` through Media Foundation: the count, the size, and the
    /// frame at `keep` as top-first RGBA rows.
    fn decode(path: &Path, keep: u32) -> (u32, (u32, u32), Vec<u8>) {
        unsafe {
            MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
            let mut attrs: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attrs, 1).unwrap();
            let attrs = attrs.unwrap();
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1).unwrap();
            let reader = MFCreateSourceReaderFromURL(&HSTRING::from(path.as_os_str()), &attrs).unwrap();
            let stream = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
            let t = MFCreateMediaType().unwrap();
            t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).unwrap();
            t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32).unwrap();
            reader.SetCurrentMediaType(stream, None, &t).unwrap();
            let current = reader.GetCurrentMediaType(stream).unwrap();
            let size = current.GetUINT64(&MF_MT_FRAME_SIZE).unwrap();
            let (w, h) = ((size >> 32) as u32, size as u32);

            let (mut count, mut kept) = (0u32, Vec::new());
            loop {
                let mut flags = 0u32;
                let mut sample: Option<IMFSample> = None;
                reader.ReadSample(stream, 0, None, Some(&mut flags), None, Some(&mut sample)).unwrap();
                if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                    break;
                }
                let Some(sample) = sample else { continue };
                if count == keep {
                    // The decoder pads its frames to whole 16-pixel blocks, which the media type
                    // doesn't say; the buffer's length over the padded height gives the row pitch.
                    let buf = sample.ConvertToContiguousBuffer().unwrap();
                    let mut data: *mut u8 = std::ptr::null_mut();
                    let mut len = 0u32;
                    buf.Lock(&mut data, None, Some(&mut len)).unwrap();
                    let bytes = std::slice::from_raw_parts(data, len as usize);
                    let padded = h.div_ceil(16) * 16;
                    let rows = if len % padded == 0 && len / padded >= w * 4 { padded } else { h };
                    let pitch = (len / rows) as usize;
                    kept = vec![0u8; (w * h * 4) as usize];
                    for y in 0..h as usize {
                        let src = &bytes[y * pitch..][..w as usize * 4];
                        for (d, s) in kept[y * w as usize * 4..][..w as usize * 4].chunks_exact_mut(4).zip(src.chunks_exact(4)) {
                            d.copy_from_slice(&[s[2], s[1], s[0], 255]);
                        }
                    }
                    buf.Unlock().unwrap();
                }
                count += 1;
            }
            let _ = MFShutdown();
            (count, (w, h), kept)
        }
    }

    /// Writes a small loop and reads it back: every frame there, the right size, and the middle
    /// frame (the still's moment) the right way up and close to the still. Ignored by default
    /// since it needs the GPU and a video encoder: `cargo test --lib -- --ignored movie`.
    #[test]
    #[ignore]
    fn movie_round_trip() {
        let r = Renderer::new().unwrap();
        let mut c = WallpaperConfig::default();
        c.set_scene(SceneKind::RingedPlanet);
        let p = plan(&c, &MobileOptions { width: 360, height: 780, ..Default::default() });
        let path = std::env::temp_dir().join("deepfield-movie-test.mp4");
        write_movie(&r, &p, &path, 1, |_| {}).unwrap();
        let mid = p.loop_.frames() / 2;
        let (count, size, frame) = decode(&path, mid);
        assert_eq!(count, p.loop_.frames());
        assert_eq!(size, (360, 780));
        let still = render_still(&r, &p);
        let diff: f64 = frame.iter().zip(&still).map(|(a, b)| (*a as f64 - *b as f64).abs()).sum::<f64>()
            / frame.len() as f64;
        if let Ok(dir) = std::env::var("DEEPFIELD_MOVIE_DUMP") {
            crate::capture::write_png(&format!("{dir}/decoded.png"), 360, 780, &frame).unwrap();
            crate::capture::write_png(&format!("{dir}/still.png"), 360, 780, &still).unwrap();
        }
        // compression blurs the dither a little; upside down or wrong channels would be far off
        assert!(diff < 12.0, "mean difference {diff}");
        let flipped: f64 = (0..780usize)
            .flat_map(|y| (0..360usize).map(move |x| (x, y)))
            .map(|(x, y)| (frame[(y * 360 + x) * 4] as f64 - still[((779 - y) * 360 + x) * 4] as f64).abs())
            .sum::<f64>()
            / (360.0 * 780.0);
        assert!(flipped > diff, "the movie matches the still upside down better ({flipped} vs {diff})");
        let _ = std::fs::remove_file(path);
    }
}
