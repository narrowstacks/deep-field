import AppKit
import Metal
import QuartzCore

/// Renders the scene at (screen pixels / pixelSize) and lets the compositor upscale it with
/// nearest-neighbor filtering, so the GPU shades a fraction of the pixels.
/// Used for each screen's wallpaper and, with `previewOf` set, for the customize window's preview.
final class WallpaperView: NSView {
    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private var baked: Baked?
    private var bakedSize = (0, 0)
    private var lastFrame: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var rebakeWork: DispatchWorkItem?
    private var lastRebake: CFTimeInterval = 0
    private let events = EventSchedule(seed: UInt64.random(in: 0...UInt64.max))

    /// Preview mode: render exactly what a screen of this pixel size would show, scaled down to fit.
    private let previewOf: CGSize?

    // debug counters
    private var framesSinceLog = 0
    private var lastLog = CACurrentMediaTime()

    var externallyPaused = false { didSet { updateRunning() } }

    /// Preview only: show the drawable at the wallpaper's real cell size, centered and cropped,
    /// instead of scaled to fit, so pixel size, levels and dither can be judged.
    var actualPixels = false {
        didSet {
            guard actualPixels != oldValue else { return }
            pan = .zero
            layoutDrawable()
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Preview at 1:1: how far the view has been dragged from centered, in points.
    private var pan = CGPoint.zero

    // Dragging the 1:1 preview pans it; it only moves the layer, so nothing redraws.
    override var mouseDownCanMoveWindow: Bool { !(previewOf != nil && actualPixels) }

    override func mouseDragged(with event: NSEvent) {
        guard previewOf != nil, actualPixels else { return super.mouseDragged(with: event) }
        pan.x += event.deltaX
        pan.y -= event.deltaY
        placePreviewLayer()
    }

    override func mouseDown(with event: NSEvent) {
        guard previewOf != nil, actualPixels else { return super.mouseDown(with: event) }
        NSCursor.closedHand.push()
    }

    override func mouseUp(with event: NSEvent) {
        guard previewOf != nil, actualPixels else { return super.mouseUp(with: event) }
        NSCursor.pop()
    }

    override func resetCursorRects() {
        if previewOf != nil, actualPixels { addCursorRect(bounds, cursor: .openHand) }
    }

    /// Dev only (`--check-picker`): called with the config each preview frame was drawn with.
    static var debugRenderHook: ((WallpaperConfig) -> Void)?

    private var config: WallpaperConfig { ConfigStore.shared.config }

    init(frame: NSRect, previewOf: CGSize? = nil) {
        self.previewOf = previewOf
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if previewOf != nil { layer?.masksToBounds = true }

        metalLayer.device = Renderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.magnificationFilter = .nearest
        metalLayer.minificationFilter = previewOf == nil ? .nearest : .linear
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 2
        metalLayer.anchorPoint = .zero
        metalLayer.contentsGravity = .resize
        layer?.addSublayer(metalLayer)

        observers.append(NotificationCenter.default.addObserver(
            forName: ConfigStore.changed, object: nil, queue: .main) { [weak self] _ in self?.configChanged() })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        link?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updateRunning() })

        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        layoutDrawable()
        updateRunning()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The preview renders at the screen's resolution whatever its size, so resizing the
        // window only moves the layer: the compositor rescales the last frame, with no re-bake
        // and no extra frame per step of a live resize.
        if previewOf != nil, window != nil, bakedSize != (0, 0) {
            placePreviewLayer()
        } else {
            layoutDrawable()
        }
    }

    /// Fits the preview's layer to the view: the whole frame, or centered at true pixel size.
    private func placePreviewLayer() {
        guard let ref = previewOf, let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if actualPixels {
            let px = CGFloat(config.pixelSize), scale = window.backingScaleFactor
            let fw = (ref.width / px).rounded(.up) * px / scale, fh = (ref.height / px).rounded(.up) * px / scale
            // Centered, then shifted by the drag, but never so far that an edge comes into view.
            func axis(_ view: CGFloat, _ layer: CGFloat, _ pan: inout CGFloat) -> CGFloat {
                let slack = max((layer - view) / 2, 0)
                pan = min(max(pan, -slack), slack)
                return (view - layer) / 2 + pan
            }
            metalLayer.frame = CGRect(x: axis(bounds.width, fw, &pan.x), y: axis(bounds.height, fh, &pan.y),
                                      width: fw, height: fh)
        } else {
            metalLayer.frame = bounds
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutDrawable()
    }

    /// Power or thermal state changed (frame rate caps), or the active Space changed.
    func systemStateChanged() {
        layoutDrawable()
        updateRunning()
    }

    private func configChanged() {
        updateRunning()
        // a new scene can't draw from the old scene's bake, so that one re-bakes right away
        if let baked, !baked.matches(config), baked.key.scene == config.scene {
            // Re-trace as a slider moves, so a tilt turns smoothly: every change for the flat
            // scenes (a bake is about a millisecond), at most every 0.1 s for the lensed ones
            // (tens of ms), plus once more when the slider stops.
            rebakeWork?.cancel()
            let gap = Renderer.lensing(config.scene) > 0 ? 0.1 : 0.0
            let wait = gap - (CACurrentMediaTime() - lastRebake)
            let work = DispatchWorkItem { [weak self] in
                self?.lastRebake = CACurrentMediaTime()
                self?.bakedSize = (0, 0)
                self?.layoutDrawable()
            }
            if wait <= 0 {
                work.perform()
            } else {
                rebakeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
        } else {
            rebakeWork?.cancel()
            layoutDrawable()
        }
    }

    private func layoutDrawable() {
        guard let window, bounds.width > 0 else { return }
        let scale = window.backingScaleFactor
        let px = CGFloat(config.pixelSize)
        let w: Int, h: Int
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let ref = previewOf {
            w = Int((ref.width / px).rounded(.up))
            h = Int((ref.height / px).rounded(.up))
            metalLayer.contentsScale = scale
        } else {
            // Round up and let the layer overhang the window edge, so every dither cell is
            // exactly px*px device pixels (no uneven columns from rescaling).
            w = Int((bounds.width * scale / px).rounded(.up))
            h = Int((bounds.height * scale / px).rounded(.up))
            metalLayer.contentsScale = scale
            metalLayer.frame = CGRect(x: 0, y: bounds.height - CGFloat(h) * px / scale,
                                      width: CGFloat(w) * px / scale, height: CGFloat(h) * px / scale)
        }
        metalLayer.drawableSize = CGSize(width: w, height: h)
        CATransaction.commit()
        placePreviewLayer()

        if bakedSize != (w, h) || !(baked?.matches(config) ?? false) {
            let t0 = CACurrentMediaTime()
            baked = Renderer.shared.bake(width: w, height: h, config: config, wait: Settings.debug, reusing: baked)
            bakedSize = (w, h)
            if Settings.debug {
                NSLog("DeepField: baked %@ %dx%d in %.1f ms, %.1f MB", config.scene.rawValue, w, h,
                      (CACurrentMediaTime() - t0) * 1000, Double(baked?.bytes ?? 0) / 1_048_576)
            }
        }
        render()
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) || Settings.ignoreOcclusion
    }

    private func updateRunning() {
        guard let link else { return }
        let fps = Settings.effectiveFPS
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 10)), maximum: Float(fps), preferred: Float(fps))
        let shouldRun = isOnScreen && !externallyPaused
        if link.isPaused == shouldRun {
            link.isPaused = !shouldRun
            if Settings.debug {
                NSLog("DeepField: %@ rendering on %@ (occlusion visible=%d, paused=%d)",
                      shouldRun ? "resume" : "stop", window?.screen?.localizedName ?? "?",
                      isOnScreen ? 1 : 0, externallyPaused ? 1 : 0)
            }
            if shouldRun { lastFrame = 0; render() }
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        // The display link may fire faster than asked on high refresh displays; skip extra ticks.
        if now - lastFrame < 0.75 / Settings.effectiveFPS { return }
        lastFrame = now
        render()
    }

    private func render() {
        guard let baked, metalLayer.drawableSize.width > 0 else { return }
        let r = Renderer.shared
        guard let drawable = metalLayer.nextDrawable(), let cb = r.queue.makeCommandBuffer() else { return }
        r.encodeFrame(cb, target: drawable.texture, baked: baked, elapsed: r.elapsed, config: config, events: events)
        cb.present(drawable)
        cb.commit()
        if previewOf != nil { Self.debugRenderHook?(config) }

        if Settings.debug && previewOf == nil {
            framesSinceLog += 1
            let now = CACurrentMediaTime()
            if now - lastLog > 10 {
                NSLog("DeepField: %.1f fps on %@", Double(framesSinceLog) / (now - lastLog),
                      window?.screen?.localizedName ?? "?")
                framesSinceLog = 0
                lastLog = now
            }
        }
    }
}
