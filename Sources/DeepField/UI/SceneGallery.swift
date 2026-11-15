import SwiftUI

/// The scene picker: a grid of baked thumbnails. Square corners throughout, the pixel motif.
struct SceneGallery: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var thumbnails: SceneThumbnails
    /// 5 on the normal stage, 2 beside the phone preview.
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Theme.thumbBox.width), spacing: 10), count: columns),
                  alignment: .leading, spacing: 10) {
            ForEach(Array(SceneKind.listed.enumerated()), id: \.element) { i, kind in
                Cell(index: i, kind: kind, image: thumbnails.images[kind], selected: store.config.scene == kind) {
                    store.config.scene = kind
                }
            }
        }
    }

    private struct Cell: View {
        let index: Int
        let kind: SceneKind
        let image: CGImage?
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack {
                        Color.black
                        if let image {
                            Image(decorative: image, scale: 1)
                                .interpolation(.none)
                                .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                        }
                    }
                    .frame(width: Theme.thumbBox.width, height: Theme.thumbBox.height)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%02d", index + 1))
                            .font(Theme.thumbnail)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 2).padding(.vertical, 1)
                            .background(Color.black.opacity(0.6))
                    }
                    .overlay {
                        if selected {
                            Rectangle().stroke(Theme.accent, lineWidth: 2)
                            CornerBrackets().stroke(Theme.accent, lineWidth: 2).padding(-4)
                        } else {
                            Rectangle().stroke(Color.white.opacity(hovered ? 0.4 : 0.14), lineWidth: 1)
                        }
                    }
                    Text(kind.title)
                        .font(Theme.thumbnail)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        .frame(width: Theme.thumbBox.width, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(kind.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .help(kind.blurb)
        }
    }
}
