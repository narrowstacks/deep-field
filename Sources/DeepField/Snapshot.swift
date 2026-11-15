import AppKit
import Metal

/// `DeepField --snapshot out.png [--size 3440x1440] [--time 12.5] [--scene wormhole] [--preset Glacier] [--no-events]`
/// Renders one frame offscreen, upscaled with nearest-neighbor like the live wallpaper.
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        var config = ConfigStore.shared.config
        if let s = value("--scene"), let kind = SceneKind(rawValue: s) { config.scene = kind }
        if let p = value("--preset"), let preset = PaletteConfig.presets.first(where: { $0.0 == p }) { config.palette = preset.1 }
        // --config '{"milkyWay": false, "planetCount": 0}' overrides any settings
        if let json = value("--config"), let patch = json.data(using: .utf8),
           let patchDict = try? JSONSerialization.jsonObject(with: patch) as? [String: Any],
           let base = try? JSONEncoder().encode(config),
           var dict = try? JSONSerialization.jsonObject(with: base) as? [String: Any] {
            dict.merge(patchDict) { _, new in new }
            if let merged = try? JSONSerialization.data(withJSONObject: dict),
               let c = WallpaperConfig.decode(merged) { config = c }
        }
        // --demo 8:5,9:20 forces event kind 8 to start at t=5 s and kind 9 at t=20 s
        if let demo = value("--demo") {
            for pair in demo.split(separator: ",") {
                let parts = pair.split(separator: ":")
                if parts.count == 2, let id = UInt64(parts[0]), let start = Double(parts[1]) {
                    ConfigStore.shared.demoEvents[id] = start
                }
            }
        }
        if let j = args.firstIndex(of: "--list-events") {
            EventSchedule(seed: 1).list(minutes: j + 1 < args.count ? Double(args[j + 1]) ?? 60 : 60, config: config)
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let size = (value("--size") ?? "3440x1440").split(separator: "x").compactMap { Int($0) }
        let time = Double(value("--time") ?? "10") ?? 10
        let px = config.pixelSize
        let w = (size[0] + px - 1) / px, h = (size[1] + px - 1) / px

        let r = Renderer.shared
        guard let baked = r.bake(width: w, height: h, config: config, wait: false),
              let target = r.makeTexture(.bgra8Unorm, w, h, usage: [.renderTarget, .shaderRead]),
              let cb = r.queue.makeCommandBuffer() else { exit(1) }
        let events = EventSchedule(seed: 1, enabled: !args.contains("--no-events"))
        r.encodeFrame(cb, target: target, baked: baked, elapsed: time, config: config, events: events)

        let rowBytes = w * 4
        let buffer = r.device.makeBuffer(length: rowBytes * h, options: .storageModeShared)!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // nearest-neighbor upscale on the CPU (BGRA)
        let src = buffer.contents().bindMemory(to: UInt32.self, capacity: w * h)
        let W = size[0], H = size[1]
        var out = [UInt32](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W { out[y * W + x] = src[(y / px) * w + (x / px)] } }
        let data = Data(bytes: out, count: out.count * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                          provider: CGDataProvider(data: data as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: img)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
}
