import Foundation
import Metal
import QuartzCore

/// `--benchmark`: for each scene, the GPU time of a bake (ray trace plus sky pass) and of an
/// average frame, measured from MTLCommandBuffer GPU timestamps. Each command buffer is waited
/// on before the next is committed, so GPU times don't overlap. Also reports the CPU time spent
/// encoding a frame (scene state, events, uniforms), since some scenes do real work there.
enum Benchmark {
    static func run(config base: WallpaperConfig, scenes: [SceneKind], size: (width: Int, height: Int),
                    startTime: Double, frames: Int, eventsEnabled: Bool) {
        let r = Renderer.shared
        let px = base.pixelSize
        let w = (size.width + px - 1) / px, h = (size.height + px - 1) / px
        print("Deep Field benchmark on \(r.device.name): \(size.width)x\(size.height) at pixel size \(px) "
              + "(\(w)x\(h) shaded), \(frames) frames from t = \(startTime) s, events \(eventsEnabled ? "on" : "off")")
        print(pad("scene", 16) + pad("bake ms", 10) + pad("frame GPU ms", 14) + pad("max ms", 9) + "encode CPU ms")

        for scene in scenes {
            var c = base
            c.scene = scene
            guard let target = r.makeTexture(.bgra8Unorm, w, h, usage: [.renderTarget, .shaderRead]) else { exit(1) }

            // bake: one warm-up, then the mean of three
            var baked: Baked?
            var bakeTimes: [Double] = []
            for i in 0..<4 {
                guard let cb = r.queue.makeCommandBuffer(),
                      let b = r.encodeBake(cb, width: w, height: h, config: c) else { exit(1) }
                cb.commit()
                cb.waitUntilCompleted()
                if i > 0 { bakeTimes.append(gpuMilliseconds(cb)) }
                baked = b
            }
            guard let baked else { exit(1) }

            let events = EventSchedule(seed: 1, enabled: eventsEnabled)
            var gpuTimes: [Double] = [], cpuTimes: [Double] = []
            let warmUp = 10
            for i in 0..<(warmUp + frames) {
                let t = startTime + Double(i) / 24
                let t0 = CACurrentMediaTime()
                guard let cb = r.queue.makeCommandBuffer() else { exit(1) }
                r.encodeFrame(cb, target: target, baked: baked, elapsed: t, config: c, events: events)
                let encode = (CACurrentMediaTime() - t0) * 1000
                cb.commit()
                cb.waitUntilCompleted()
                if i >= warmUp {
                    gpuTimes.append(gpuMilliseconds(cb))
                    cpuTimes.append(encode)
                }
            }
            print(pad(scene.rawValue, 16)
                  + pad(String(format: "%.2f", mean(bakeTimes)), 10)
                  + pad(String(format: "%.3f", mean(gpuTimes)), 14)
                  + pad(String(format: "%.3f", gpuTimes.max() ?? 0), 9)
                  + String(format: "%.3f", mean(cpuTimes)))
        }
    }

    private static func gpuMilliseconds(_ cb: MTLCommandBuffer) -> Double {
        (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }

    private static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
}
