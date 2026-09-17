import SwiftUI

struct EndGameView: View {
    @EnvironmentObject var store: GameStore
    var onDone: (() -> Void)?

    private var stats: [PlayerStats] { store.state.endStats }
    private var winner: PlayerStats? { stats.first { $0.isWinner } }
    private var hasWinner: Bool { stats.contains(where: \.isWinner) }
    private var isPractice: Bool { store.state.gameMode == .practiceVsCPU }

    var body: some View {
        ResultsScreenView(
            stats: stats,
            winnerLabel: hasWinner ? "Winner" : "No Winner",
            winners: hasWinner
                ? (winner.map {
                    [ResultsWinner(id: $0.id, name: $0.name, avatarIndex: $0.avatarIndex)]
                } ?? [])
                : [],
            winnerSubtitle: hasWinner ? "\(winner?.finalStack ?? 0)" : "No winner — tie stands",
            statsSectionTitle: "Results",
            buttonTitle: isPractice && onDone != nil ? "Done" : "Play Again",
            onButton: {
                if isPractice, let onDone {
                    onDone()
                } else {
                    store.resetToWaiting()
                }
            },
            secondaryButtonTitle: isPractice && onDone != nil ? "Play Again" : nil,
            onSecondaryButton: isPractice && onDone != nil ? { store.resetToWaiting() } : nil
        )
    }
}

// MARK: - Preview

#Preview("End Screen") {
    EndGameView()
        .environmentObject(GameStore.mockEnded)
}
