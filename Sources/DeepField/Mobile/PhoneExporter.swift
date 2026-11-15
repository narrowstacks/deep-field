import AppKit
import UniformTypeIdentifiers

/// Drives the Phone tab: keeps a preview of the phone wallpaper up to date with the current
/// scene and the tab's options, and runs the exports one at a time off the main thread.
final class PhoneExporter: ObservableObject {
    static let shared = PhoneExporter()

    @Published var options = MobileOptions() { didSet { if options != oldValue { schedulePreview() } } }
    /// A `PhoneModel.key`, or "custom".
    @Published var model = PhoneModel.presets[0].key {
        didSet {
            guard let m = PhoneModel.presets.first(where: { $0.key == model }) else { return }
            options.width = m.width
            options.height = m.height
        }
    }
    @Published var stillFormat = MobileExport.StillFormat.png
    @Published private(set) var preview: CGImage?
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var status = ""

    private let queue = DispatchQueue(label: "local.deepfield.phone-export", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var previewWork: DispatchWorkItem?
    private var previewGeneration = 0

    private var plan: MobileExport.Plan { MobileExport.plan(ConfigStore.shared.config, options) }

    // MARK: preview

    func appear() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ConfigStore.changed, object: nil, queue: .main) {
                [weak self] _ in self?.schedulePreview()
            }
        }
        schedulePreview(after: 0)
    }

    func disappear() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        previewWork?.cancel()
    }

    private func schedulePreview(after delay: TimeInterval = 0.3) {
        guard observer != nil else { return }
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func renderPreview() {
        previewGeneration += 1
        let gen = previewGeneration, plan = plan
        queue.async {
            let image = MobileExport.renderStill(plan)
            DispatchQueue.main.async { if gen == self.previewGeneration { self.preview = image } }
        }
    }

    // MARK: exports

    func saveStill() {
        let plan = plan, format = stillFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .heic]
        panel.nameFieldStringValue = MobileExport.baseName(plan) + (format == .png ? ".png" : ".heic")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Rendering the still…") { _ in
            guard let image = MobileExport.renderStill(plan) else { throw MobileExport.ExportError.render }
            try MobileExport.writeStill(image, to: url, format: format)
            return ("Saved \(url.lastPathComponent).", url)
        }
    }

    /// The HEIC and MOV pair into a folder the user picks (to AirDrop, say).
    func saveLivePhotoFiles() {
        let plan = plan
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the Live Photo's still (HEIC) and movie (MOV)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run("Rendering the Live Photo…") { progress in
            let files = try MobileExport.writeLivePhoto(plan, folder: folder, baseName: MobileExport.baseName(plan),
                                                        progress: progress)
            return ("Saved \(files.still.lastPathComponent) and \(files.movie.lastPathComponent). Send both together.", files.still)
        }
    }

    /// Renders the pair to a temporary folder and adds it to the Photos library as one Live Photo.
    func addLivePhotoToPhotos() {
        let plan = plan
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Deep Field \(UUID().uuidString)")
        busy = true
        progress = 0
        status = "Rendering the Live Photo…"
        queue.async {
            do {
                let files = try MobileExport.writeLivePhoto(plan, folder: folder, baseName: MobileExport.baseName(plan)) { p in
                    DispatchQueue.main.async { self.progress = p }
                }
                DispatchQueue.main.async {
                    self.status = "Adding to Photos…"
                    LivePhotoLibrary.save(files) { error in
                        try? FileManager.default.removeItem(at: folder)
                        self.finish(error.map { $0.localizedDescription } ?? "Added to Photos. With iCloud Photos on, it shows up on your iPhone shortly.")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async { self.finish(error.localizedDescription) }
            }
        }
    }

    /// Runs `work` on the export queue with progress, then shows its message and reveals its file.
    private func run(_ message: String, _ work: @escaping (@escaping (Double) -> Void) throws -> (String, URL)) {
        busy = true
        progress = nil
        status = message
        queue.async {
            do {
                let (done, url) = try work { p in DispatchQueue.main.async { self.progress = p } }
                DispatchQueue.main.async {
                    self.finish(done)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async { self.finish(error.localizedDescription) }
            }
        }
    }

    private func finish(_ message: String) {
        busy = false
        progress = nil
        status = message
    }
}
