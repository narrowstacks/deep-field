import AppKit
import SwiftUI

/// The Customize window's colors and sizes, kept in one place so the rest of the UI uses names,
/// not numbers. Colors are the system's own, in the dark appearance.
enum Theme {
    static let stageBackground = Color(nsColor: .underPageBackgroundColor)
    static let inspectorBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let stageWidth: CGFloat = 720, inspectorWidth: CGFloat = 440
    static let windowSize = CGSize(width: 1160, height: 740)    // the window's size when it first opens
    /// Resizing goes no smaller than this: the preview, its caption and a row of the gallery.
    static let minWindowHeight: CGFloat = 600
    static let stagePadding: CGFloat = 20
    static let previewBox = CGSize(width: 680, height: 425)

    /// The box a gallery thumbnail fits in, and the stage gallery's column count. A wide screen
    /// gives a short preview, so the gallery takes the leftover height as four larger columns.
    static func gallery(for reference: CGSize) -> (box: CGSize, columns: Int) {
        fit(reference, in: previewBox).height < 340
            ? (CGSize(width: 162, height: 102), 4)
            : (CGSize(width: 128, height: 80), 5)
    }

    /// `size` scaled to fit inside `box`, keeping its aspect ratio.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        let aspect = size.width / max(size.height, 1)
        return aspect >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
    }
}

/// A group title in the inspector: small monospaced caps in the secondary label color.
struct GroupHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A group header that folds its group away.
struct CollapsibleHeader: View {
    let title: String
    @Binding var collapsed: Bool

    var body: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                GroupHeader(title: title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
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
