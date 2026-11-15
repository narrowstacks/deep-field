import SwiftUI

/// The scene picker: a grid of baked thumbnails, square-cornered and drawn nearest-neighbor so
/// they keep the wallpaper's pixels.
struct SceneGallery: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var thumbnails: SceneThumbnails
    /// 5 on the normal stage, 2 beside the phone preview.
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Theme.thumbBox.width), spacing: 10), count: columns),
                  alignment: .leading, spacing: 10) {
            ForEach(SceneKind.listed, id: \.self) { kind in
                Cell(kind: kind, image: thumbnails.images[kind], selected: store.config.scene == kind) {
                    store.config.scene = kind
                }
            }
        }
    }

    private struct Cell: View {
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
                    .overlay {
                        if selected {
                            Rectangle().stroke(Color.accentColor, lineWidth: 2)
                        } else {
                            Rectangle().stroke(Color.white.opacity(hovered ? 0.4 : 0.14), lineWidth: 1)
                        }
                    }
                    Text(kind.title)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
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
