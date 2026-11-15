import Foundation

/// Which of the pulsar's two lighthouse beams shine. "Top" is the one from the magnetic pole on
/// the same side as the north end of the spin axis.
enum PulsarBeams: String, Codable, CaseIterable, Identifiable {
    case both, top, bottom, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "Both poles"
        case .top: "Top only"
        case .bottom: "Bottom only"
        case .none: "None"
        }
    }
    /// Bit 0: the top beam, bit 1: the bottom one.
    var mask: Int {
        switch self {
        case .both: 3
        case .top: 1
        case .bottom: 2
        case .none: 0
        }
    }
}

enum PulsarFieldStyle: String, Codable, CaseIterable, Identifiable {
    case lines, magnetar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: "Field lines"
        case .magnetar: "Magnetar lobes"
        }
    }
}
