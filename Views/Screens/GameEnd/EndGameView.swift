import SwiftUI

struct EndGameView: View {
    @EnvironmentObject var store: GameStore

    private var stats: [PlayerStats] { store.state.endStats }
    private var winner: PlayerStats? { stats.first { $0.isWinner } }
    private var hasWinner: Bool { stats.contains(where: \.isWinner) }

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
