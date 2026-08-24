import SwiftUI

struct HandSummaryView: View {
    @EnvironmentObject var store: GameStore

    private static let autoAdvanceSeconds: TimeInterval = 5

    @State private var countdownStartedAt: Date?
    @State private var didContinue = false

    private var stats: [PlayerStats] { store.state.endStats }

    private var winners: [ResultsWinner] {
        let ids = store.state.handResult?.winnerIDs ?? []
        return ids.compactMap { id in
            guard let player = store.state.players.first(where: { $0.id == id }) else { return nil }
            let share = store.state.handResult?.payouts[id] ?? 0
            return ResultsWinner(
                id: id,
                name: player.name,
                avatarIndex: player.avatarIndex,
                subtitle: share > 0 ? "+\(share)" : "\(player.stack)"
            )
        }
    }

    private var winnerSubtitle: String {
        if winners.count > 1 {
            return winners.map(\.subtitle).joined(separator: " · ")
        }
        if let share = winners.first?.subtitle, !share.isEmpty {
            return share
        }
        if store.state.lastPotAwarded > 0 {
            return "+\(store.state.lastPotAwarded)"
        }
        return "0"
    }

    private var buttonTitle: String {
        store.sessionEndsAfterHandSummary ? "See Final Results" : "Next Hand"
    }

    private var handSummaryTaskID: String {
        let winnersKey = (store.state.handResult?.winnerIDs ?? []).joined(separator: ",")
        return "\(store.state.handID?.uuidString ?? "")-\(winnersKey)"
    }

    var body: some View {
        ResultsScreenView(
            stats: stats,
            winnerLabel: winners.count > 1 ? "Split Pot" : "Hand Winner",
            winners: winners,
            winnerSubtitle: winnerSubtitle,
            statsSectionTitle: "Leaderboard",
            buttonTitle: buttonTitle,
            onButton: continueIfNeeded,
            countdownStartedAt: countdownStartedAt,
            countdownDuration: Self.autoAdvanceSeconds,
            buttonFillColor: Theme.Color.green,
            buttonTrackColor: Theme.Color.green.opacity(0.25),
            buttonTextColor: Theme.Color.primary
        )
        .task(id: handSummaryTaskID) {
            guard store.state.phase == .handSummary else { return }
            didContinue = false
            // Practice waits for a tap; classic keeps the short auto-advance countdown.
            guard store.state.gameMode != .practiceVsCPU else {
                countdownStartedAt = nil
                return
            }
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
