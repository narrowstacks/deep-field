import Foundation

/// Part of `--check-customization`: the gallery beside the phone preview has two columns wherever
/// they fit with the scroller, and one elsewhere.
enum PhoneGalleryCheck {
    /// The stage inside its padding, at the smallest window width.
    private static let stageWidth = Theme.stageWidth - 2 * Theme.stagePadding
    /// The same at the smallest and first-open window heights.
    private static let short = Theme.minWindowHeight - 32, normal = Theme.windowSize.height - 32
    /// An overlay scroller, and an always-shown one.
    private static let scrollers: [CGFloat] = [0, 15]
    private static let se = CGSize(width: 750, height: 1334), wide = CGSize(width: 4096, height: 320)

    static func failures() -> [String] {
        var failures: [String] = []

        func preview(_ phone: CGSize, _ height: CGFloat) -> CGFloat {
            var o = MobileOptions()
            o.width = Int(phone.width)
            o.height = Int(phone.height)
            return PhoneStage.previewSize(o, stageHeight: height).width
        }
        func columns(_ screen: CGSize, _ phone: CGSize, _ height: CGFloat, stage: CGFloat = stageWidth, scroller: CGFloat) -> Int {
            PhoneStage.galleryColumns(thumbnail: CGFloat(SceneThumbnails.size(for: screen).width),
                                      preview: preview(phone, height), stage: stage, scroller: scroller)
        }
        func expect(_ n: Int, _ what: String, _ screen: CGSize, _ phone: CGSize, _ height: CGFloat,
                    stage: CGFloat = stageWidth, scroller: CGFloat) {
            let got = columns(screen, phone, height, stage: stage, scroller: scroller)
            if got != n { failures.append("phone gallery, \(what), scroller \(scroller): \(got) columns, not \(n)") }
        }

        let mac = CGSize(width: 2560, height: 1600), ultrawide = CGSize(width: 3440, height: 1440)
        let proMax = CGSize(width: 1320, height: 2868)
        for s in scrollers {
            expect(2, "defaults", mac, proMax, normal, scroller: s)
            expect(2, "defaults on 21:9", ultrawide, proMax, normal, scroller: s)
            expect(1, "SE on 21:9", ultrawide, se, normal, scroller: s)
            expect(2, "SE on 21:9, short window", ultrawide, se, short, scroller: s)
            expect(2, "SE on 21:9, wider window", ultrawide, se, normal, stage: stageWidth + 100, scroller: s)
            for h in [short, normal] { expect(1, "4096x320 on 21:9", ultrawide, wide, h, scroller: s) }
            // 266 pt of room for two 128 pt columns and their gap: exactly enough without a scroller
            expect(s == 0 ? 2 : 1, "4096x320 on 16:10", mac, wide, normal, scroller: s)
        }

        // whatever the sizes, what's chosen fits, and two columns are used if they would
        let screens = [mac, CGSize(width: 2560, height: 1440), ultrawide, CGSize(width: 5120, height: 1440),
                       CGSize(width: 1440, height: 2560)]
        let sides = [1, 320, 750, 1334, 2868, 4096, 9999]   // 1 and 9999 are clamped
        let phones = PhoneModel.presets.map { CGSize(width: $0.width, height: $0.height) }
            + sides.flatMap { w in sides.map { CGSize(width: w, height: $0) } }
        for screen in screens { for phone in phones { for scroller in scrollers {
            for height in [short, 620, normal, 1400] { for extra in [0, 40, 500] as [CGFloat] {
                let stage = stageWidth + extra
                let cell = CGFloat(SceneThumbnails.size(for: screen).width)
                let room = stage - preview(phone, height) - 20 + 0.25   // half a Retina pixel
                let n = columns(screen, phone, height, stage: stage, scroller: scroller)
                let two = 2 * cell + 10 + scroller <= room
                if n != (two ? 2 : 1) || CGFloat(n) * (cell + 10) - 10 + scroller > room {
                    failures.append("phone gallery: \(n) columns in \(room) pt, phone \(phone), screen \(screen), scroller \(scroller)")
                }
            } }
        } } }
        return failures
    }
}
