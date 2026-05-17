import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: GameStore

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            Group {
                switch store.state.phase {
                case .waiting:
                    WaitingRoomView()
                        .transition(.opacity)
                case .playing:
                    GameView()
                        .transition(.opacity)
                case .ended:
                    EndGameView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.state.phase)
        }
    }
}

// MARK: - Preview (all three phases)

#Preview("Waiting") {
    RootView().environmentObject(GameStore.mockWaiting)
}

#Preview("Playing") {
    RootView().environmentObject(GameStore.mock)
}

#Preview("Ended") {
    RootView().environmentObject(GameStore.mockEnded)
}
