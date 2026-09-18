import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: GameStore
    var onExitPractice: (() -> Void)?
    var onExitClassic: (() -> Void)?

    @State private var isShowingLeaveConfirmation = false

    private var canExitPractice: Bool {
        store.state.gameMode == .practiceVsCPU
            && store.state.phase != .ended
            && onExitPractice != nil
    }

    private var canExitClassic: Bool {
        store.state.gameMode == .classicPoker
            && store.state.phase != .ended
            && onExitClassic != nil
    }

    private var canExit: Bool { canExitPractice || canExitClassic }

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
                    EndGameView(onDone: store.state.gameMode == .classicPoker ? onExitClassic : onExitPractice)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.state.phase)
        }
        .overlay(alignment: .topTrailing) {
            if canExit {
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
                .accessibilityLabel(canExitClassic ? "Sit out of game" : "Leave practice game")
            }
        }
        .alert(canExitClassic ? "Sit out?" : "Leave this game?", isPresented: $isShowingLeaveConfirmation) {
            Button("Stay", role: .cancel) {}
            Button(canExitClassic ? "Sit Out" : "Leave", role: .destructive) {
                if canExitClassic {
                    store.sitOutLocalPlayer()
                    onExitClassic?()
                } else {
                    store.resetToWaiting()
                    onExitPractice?()
                }
            }
        } message: {
            Text(canExitClassic
                ? "Other players can continue. You can rejoin before a later hand."
                : "Your current practice game will end.")
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
