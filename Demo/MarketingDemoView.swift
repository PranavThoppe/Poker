#if DEBUG
import SwiftUI
import Combine

/// Internal-only recording session. The lobby arrivals are staged for the camera; from the
/// first deal onward the normal practice-mode engine, betting, board reveals and showdown run.
@MainActor
final class MarketingDemoController: ObservableObject {
    let store = GameStore()
    private var hasStarted = false
    private var timelineTask: Task<Void, Never>?

    deinit { timelineTask?.cancel() }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        var state = GameStore.createNew(mode: .practiceVsCPU)
        state.heroID = "demo-you"
        state.players = [
            Player(id: "demo-you", name: "Pranav", stack: PokerEngine.startingStack, isReady: false, avatarIndex: 0)
        ]
        store.state = state
        store.enableMarketingDemoAutoplay()

        timelineTask = Task { [weak self] in
            guard let self else { return }
            await self.addPlayer(id: "demo-maya", name: "doggo", avatar: 18, after: 1)
            await self.addPlayer(id: "demo-jordan", name: "lambJam", avatar: 4, after: 1)
            await self.addPlayer(id: "demo-chris", name: "Branau", avatar: 3, after: 1)
            await self.readyPlayer(id: "demo-jordan", after: 1)
            await self.readyPlayer(id: "demo-chris", after: 1)
            await self.readyPlayer(id: "demo-maya", after: 1)
            await self.readyPlayer(id: "demo-you", after: 1)
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.store.startGame()
        }
    }

    private func addPlayer(id: String, name: String, avatar: Int, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        store.state.players.append(
            Player(id: id, name: name, stack: PokerEngine.startingStack, isReady: false, avatarIndex: avatar, isBot: true)
        )
    }

    private func readyPlayer(id: String, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        guard let index = store.state.players.firstIndex(where: { $0.id == id }) else { return }
        store.state.players[index].isReady = true
    }
}

struct MarketingDemoView: View {
    @StateObject private var demo = MarketingDemoController()

    var body: some View {
        RootView()
            .environmentObject(demo.store)
            .onAppear { demo.start() }
    }
}
#endif
