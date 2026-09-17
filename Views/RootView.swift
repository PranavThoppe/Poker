import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: GameStore
    var onExitPractice: (() -> Void)?

    @State private var isShowingLeaveConfirmation = false

    private var canExitPractice: Bool {
        store.state.gameMode == .practiceVsCPU
            && store.state.phase != .ended
            && onExitPractice != nil
    }

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
                case .showdown:
                    ShowdownRevealView()
                        .transition(.opacity)
                case .handSummary:
                    HandSummaryView()
                        .transition(.opacity)
                case .ended:
                    EndGameView(onDone: onExitPractice)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.state.phase)
        }
        .overlay(alignment: .topTrailing) {
            if canExitPractice {
                Button {
                    isShowingLeaveConfirmation = true
                } label: {
                        Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.primary)
                        .frame(width: 32, height: 32)
                        .background(Theme.Color.surface.opacity(0.92), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Theme.Color.secondary.opacity(0.3), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Spacing.xs)
                .padding(.trailing, Theme.Spacing.sm)
                .accessibilityLabel("Leave practice game")
            }
        }
        .alert("Leave this game?", isPresented: $isShowingLeaveConfirmation) {
            Button("Stay", role: .cancel) {}
            Button("Leave", role: .destructive) {
                store.resetToWaiting()
                onExitPractice?()
            }
        } message: {
            Text("Your current practice game will end.")
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

#Preview("Showdown") {
    RootView().environmentObject(GameStore.mockShowdown)
}

#Preview("Hand Summary") {
    RootView().environmentObject(GameStore.mockHandSummary)
}

#Preview("Ended") {
    RootView().environmentObject(GameStore.mockEnded)
}
