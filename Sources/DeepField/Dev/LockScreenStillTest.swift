import AppKit

/// `--lockscreen-still-test [--keep out.png]`: turns the lock screen still on through the real
/// code path, checks that every screen shows a fresh still, changes the scene and checks that
/// the debounced refresh replaces it, then turns the setting off and checks that every screen
/// is back on its exact original picture and the stills are gone. `--keep` copies the first
/// still before it's removed. If anything fails, the original pictures are put back directly.
enum LockScreenStillTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--lockscreen-still-test") else { return }
        let keep = args.firstIndex(of: "--keep").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        exit(run(keep: keep) ? 0 : 1)
    }

    private static func run(keep: String?) -> Bool {
        _ = NSApplication.shared
        let ws = NSWorkspace.shared
        let screens = NSScreen.screens
        let before = screens.map { (screen: $0, url: ws.desktopImageURL(for: $0), options: ws.desktopImageOptions(for: $0) ?? [:]) }
        for b in before { print("original  \(b.screen.localizedName): \(b.url?.absoluteString ?? "nil") \(b.options)") }

        let store = ConfigStore.shared
        let m = LockScreenStill.shared
        guard !store.config.lockScreenStill, m.loadOriginals().isEmpty else {
            print("FAIL: the setting or saved originals are already present for this binary; not touching anything")
            return false
        }
        let savedConfig = store.config
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "ok    " : "FAIL  ") + what); ok = ok && cond }
        func wait(_ seconds: Double, until cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return cond()
        }
        func ours(_ s: NSScreen) -> URL? {
            guard let u = ws.desktopImageURL(for: s),
                  u.deletingLastPathComponent().standardizedFileURL.path == LockScreenStill.folder.standardizedFileURL.path else { return nil }
            return u
        }

        m.start()
        let t0 = Date()
        store.config.lockScreenStill = true
        let applied = wait(60) { !m.busy && screens.allSatisfy { ours($0) != nil } }
        check(applied, String(format: "still set on all %d screen(s) in %.1f s", screens.count, Date().timeIntervalSince(t0)))
        let first = screens.compactMap(ours)
        for u in first {
            let size = NSImageRep(contentsOf: u).map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
            print("still     \(u.path) \(size)")
        }
        if let keep, let u = first.first {
            try? FileManager.default.removeItem(atPath: keep)
            try? FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: keep))
        }

        if applied {
            store.config.scene = store.config.scene == .galaxy ? .blackHole : .galaxy
            let refreshed = wait(30) { !m.busy && screens.allSatisfy { s in ours(s).map { !first.contains($0) } ?? false } }
            check(refreshed, "scene change refreshed the still under a new filename")
            check(first.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "old stills deleted")
            RunLoop.main.run(until: Date().addingTimeInterval(2))
        }

        store.config.lockScreenStill = false
        _ = wait(5) { screens.allSatisfy { ours($0) == nil } }
        for b in before {
            let now = ws.desktopImageURL(for: b.screen)
            print("restored  \(b.screen.localizedName): \(now?.absoluteString ?? "nil") \(ws.desktopImageOptions(for: b.screen) ?? [:])")
            check(now == b.url, "\(b.screen.localizedName) is back on its exact original URL")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: LockScreenStill.folder.path)) ?? []
        check(left.isEmpty, "no stills left in \(LockScreenStill.folder.path)")
        check(m.loadOriginals().isEmpty, "saved originals cleared")

        // safety net: whatever happened above, put the original pictures back
        for b in before where ws.desktopImageURL(for: b.screen) != b.url {
            if let url = b.url { try? ws.setDesktopImageURL(url, for: b.screen, options: b.options) }
        }
        store.config = savedConfig
        store.flush()
        print(ok ? "PASS" : "FAIL")
        return ok
    }
}
