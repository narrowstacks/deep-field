import Foundation
import Metal
import QuartzCore

/// `--benchmark`: for each scene, the GPU time of a bake (ray trace plus sky pass) and of an
/// average frame, measured from MTLCommandBuffer GPU timestamps. Each command buffer is waited
/// on before the next is committed, so GPU times don't overlap. Also reports the CPU time spent
/// encoding a frame (scene state, events, uniforms), since some scenes do real work there, and
/// that scene-state work alone in microseconds (repeated per frame to rise above timer noise).
enum Benchmark {
    static func run(config base: WallpaperConfig, scenes: [SceneKind], size: (width: Int, height: Int),
                    startTime: Double, frames: Int, eventsEnabled: Bool) {
        let r = Renderer.shared
        let px = base.pixelSize
        let w = (size.width + px - 1) / px, h = (size.height + px - 1) / px
        print("Deep Field benchmark on \(r.device.name): \(size.width)x\(size.height) at pixel size \(px) "
              + "(\(w)x\(h) shaded), \(frames) frames from t = \(startTime) s, events \(eventsEnabled ? "on" : "off")")
        print(pad("scene", 16) + pad("bake ms", 10) + pad("frame GPU ms", 14) + pad("max ms", 9) + pad("encode CPU ms", 15)
              + "scene state us")

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
            // the scene-state part of encoding on its own, repeated so microseconds don't drown in noise
            let aspect = Double(w) / Double(h)
            let reps = 20
            let s0 = CACurrentMediaTime()
            for i in 0..<frames {
                let t = startTime + Double(i) / 24
                for _ in 0..<reps { sceneState(c, elapsed: t, aspect: aspect, width: w, height: h, events: events) }
            }
            let stateMicros = (CACurrentMediaTime() - s0) * 1e6 / Double(frames * reps)
            print(pad(scene.rawValue, 16)
                  + pad(String(format: "%.2f", mean(bakeTimes)), 10)
                  + pad(String(format: "%.3f", mean(gpuTimes)), 14)
                  + pad(String(format: "%.3f", gpuTimes.max() ?? 0), 9)
                  + pad(String(format: "%.3f", mean(cpuTimes)), 15)
                  + String(format: "%.2f", stateMicros))
        }
    }

    /// The CPU scene work `Renderer.encodeFrame` does each frame, without the Metal calls.
    private static func sceneState(_ c: WallpaperConfig, elapsed: Double, aspect: Double,
                                   width: Int, height: Int, events: EventSchedule) {
        let cam = Camera(c, aspect: aspect)
        let planets = PlanetFactory.make(c).map { $0.gpu(elapsed: elapsed) }
        let stars = StarSystem.stars(c, elapsed: elapsed)
        let lights = StarSystem.lights(c, stars: stars)
        let ev = events.gpu(at: elapsed, config: c, camera: cam, heightPixels: height)
        let galaxy = c.scene == .galaxy ? GalaxyModel.gpu(c, elapsed: elapsed) : .empty
        let params = SceneParams.build(c, elapsed: elapsed, camera: cam, width: width, height: height, events: events)
        sink((planets, stars, lights, ev, galaxy, params))
    }

    @inline(never) private static func sink<T>(_ x: T) { withExtendedLifetime(x) {} }

    private static func gpuMilliseconds(_ cb: MTLCommandBuffer) -> Double {
        (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }

    private static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
}
