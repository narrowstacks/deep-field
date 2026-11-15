import SwiftUI

/// The Customize window's look: a dark console with one amber accent. Kept in one place so the
/// rest of the UI uses names, not numbers.
enum Theme {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.071)   // #0B0D12 window and stage
    static let panel      = Color(red: 0.067, green: 0.078, blue: 0.106)   // #11141B inspector column
    static let hairline   = Color.white.opacity(0.10)
    static let accent     = Color(red: 1.0, green: 0.694, blue: 0.290)     // #FFB14A amber
    static let accentDim  = Color(red: 1.0, green: 0.694, blue: 0.290).opacity(0.35)

    static let header    = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let readout   = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let thumbnail = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let title     = Font.system(size: 20, weight: .bold, design: .monospaced)

    static let stageWidth: CGFloat = 720, inspectorWidth: CGFloat = 440
    static let windowSize = CGSize(width: 1160, height: 740)
    static let stagePadding: CGFloat = 20
    static let previewBox = CGSize(width: 680, height: 425)
    static let thumbBox = CGSize(width: 128, height: 80)

    /// `size` scaled to fit inside `box`, keeping its aspect ratio.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        let aspect = size.width / max(size.height, 1)
        return aspect >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
    }
}

/// A group title in the inspector: amber monospaced caps.
struct GroupHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(Theme.header).tracking(1.5).foregroundStyle(Theme.accent)
    }
}

/// A group's explanatory note, kept leading-aligned (grouped forms push short footers right).
struct GroupFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Four L shapes at the corners of the rect, like a viewfinder.
struct CornerBrackets: Shape {
    var arm: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = min(arm, rect.width / 2, rect.height / 2)
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), a, a), (CGPoint(x: rect.maxX, y: rect.minY), -a, a),
                                 (CGPoint(x: rect.minX, y: rect.maxY), a, -a), (CGPoint(x: rect.maxX, y: rect.maxY), -a, -a)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + dy))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x + dx, y: corner.y))
        }
        return p
    }
}

/// An amber band that Bayer-dithers out from left to right, the wallpaper's own pixel motif.
struct DitherBand: View {
    private static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 3
            let columns = Int(size.width / cell)
            guard columns > 0 else { return }
            var path = Path()
            for y in 0..<4 {
                for x in 0..<columns where Self.bayer[y % 4][x % 4] / 16 < 1 - Double(x) / Double(columns) {
                    path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Theme.accent.opacity(0.55)))
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
