import Foundation

@MainActor
final class BotTurnScheduler {
    private var workItem: DispatchWorkItem?

    func schedule(delay: TimeInterval = 0.4, action: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
