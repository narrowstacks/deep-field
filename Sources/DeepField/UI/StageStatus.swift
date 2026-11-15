import Foundation

/// A short-lived message for the caption under the preview. Events can be subtle and take
/// minutes to play out, so a Show Me button confirms the click did something.
final class StageStatus: ObservableObject {
    static let shared = StageStatus()
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
