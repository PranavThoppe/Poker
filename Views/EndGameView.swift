import SwiftUI

struct EndGameView: View {
    @EnvironmentObject var store: GameStore

    private var stats: [PlayerStats] { store.state.endStats }
    private var winner: PlayerStats? { stats.first { $0.isWinner } }

    var body: some View {
        ResultsScreenView(
            stats: stats,
            winnerLabel: "Winner",
            winnerName: winner?.name ?? "—",
            winnerAvatarIndex: winner?.avatarIndex ?? 0,
            winnerSubtitle: "\(winner?.finalStack ?? 0)",
            statsSectionTitle: "Results",
            buttonTitle: "Play Again",
            onButton: { store.resetToWaiting() }
        )
    }
}

// MARK: - Preview

#Preview("End Screen") {
    EndGameView()
        .environmentObject(GameStore.mockEnded)
}
