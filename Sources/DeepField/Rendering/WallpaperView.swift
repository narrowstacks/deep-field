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
    private let events = EventSchedule(seed: UInt64.random(in: 0...UInt64.max))

    /// Preview mode: render exactly what a screen of this pixel size would show, scaled down to fit.
    private let previewOf: CGSize?

    // debug counters
    private var framesSinceLog = 0
    private var lastLog = CACurrentMediaTime()

    var externallyPaused = false { didSet { updateRunning() } }

    private var config: WallpaperConfig { ConfigStore.shared.config }

    init(frame: NSRect, previewOf: CGSize? = nil) {
        self.previewOf = previewOf
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

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
        layoutDrawable()
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
            // debounce, so dragging a slider doesn't re-trace every intermediate value
            rebakeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.bakedSize = (0, 0)
                self?.layoutDrawable()
            }
            rebakeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
            metalLayer.frame = bounds
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
