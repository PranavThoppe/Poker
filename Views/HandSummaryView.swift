import SwiftUI

struct HandSummaryView: View {
    @EnvironmentObject var store: GameStore

    private static let autoAdvanceSeconds: TimeInterval = 5

    @State private var countdownStartedAt: Date?
    @State private var didContinue = false

    private var stats: [PlayerStats] { store.state.endStats }

    private var handWinner: Player? {
        guard let id = store.state.lastHandWinnerID else { return nil }
        return store.state.players.first { $0.id == id }
    }

    private var winnerSubtitle: String {
        if store.state.lastPotAwarded > 0 {
            return "+\(store.state.lastPotAwarded)"
        }
        return "\(handWinner?.stack ?? 0)"
    }

    private var buttonTitle: String {
        store.sessionEndsAfterHandSummary ? "See Final Results" : "Next Hand"
    }

    private var handSummaryTaskID: String {
        "\(store.state.lastHandWinnerID ?? "")-\(store.state.lastPotAwarded)"
    }

    var body: some View {
        ResultsScreenView(
            stats: stats,
            winnerLabel: "Hand Winner",
            winnerName: handWinner?.name ?? "—",
            winnerAvatarIndex: handWinner?.avatarIndex ?? 0,
            winnerSubtitle: winnerSubtitle,
            statsSectionTitle: "Leaderboard",
            buttonTitle: buttonTitle,
            onButton: continueIfNeeded,
            countdownStartedAt: countdownStartedAt,
            countdownDuration: Self.autoAdvanceSeconds
        )
        .task(id: handSummaryTaskID) {
            guard store.state.phase == .handSummary else { return }
            didContinue = false
            countdownStartedAt = Date()
            defer { countdownStartedAt = nil }

            try? await Task.sleep(for: .seconds(Self.autoAdvanceSeconds))
            guard !Task.isCancelled else { return }
            continueIfNeeded()
        }
    }

    private func continueIfNeeded() {
        guard !didContinue, store.state.phase == .handSummary else { return }
        didContinue = true
        store.continueAfterHandSummary()
    }
}

// MARK: - Preview

#Preview("Hand Summary") {
    HandSummaryView()
        .environmentObject(GameStore.mockHandSummary)
}
