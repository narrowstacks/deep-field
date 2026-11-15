import Foundation

/// A short-lived message for the stage's telemetry line. Events can be subtle and take minutes
/// to play out, so "Show me" confirms the click did something.
final class ConsoleStatus: ObservableObject {
    static let shared = ConsoleStatus()
    @Published private(set) var message: String?
    private var clear: DispatchWorkItem?

    func flash(_ text: String) {
        clear?.cancel()
        message = text
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        clear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
