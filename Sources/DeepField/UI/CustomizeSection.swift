import Foundation

/// The inspector's sections. The raw value is what `-captureTab N` selects.
enum CustomizeSection: Int, CaseIterable, Identifiable {
    case scene, sky, image, system, phone
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .scene: "Scene"
        case .sky: "Sky"
        case .image: "Image"
        case .system: "System"
        case .phone: "Phone"
        }
    }

    var symbol: String {
        switch self {
        case .scene: "scope"
        case .sky: "sparkles"
        case .image: "camera.filters"
        case .system: "gearshape"
        case .phone: "iphone"
        }
    }
}
