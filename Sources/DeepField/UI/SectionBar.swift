import SwiftUI

/// The inspector's section switcher. A custom bar rather than a TabView, so it carries the theme
/// and its labels show up in `--capture-ui` images.
struct SectionBar: View {
    @Binding var selection: CustomizeSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CustomizeSection.allCases) { section in
                let isSelected = section == selection
                Button { selection = section } label: {
                    Label(section.title.uppercased(), systemImage: section.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(Theme.header)
                        .tracking(1)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 3).fill(Theme.accentDim.opacity(0.4))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if isSelected { Rectangle().fill(Theme.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
