import SwiftUI

struct HandSummaryView: View {
    @EnvironmentObject var store: GameStore

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
        if requiresReadyUp {
            return isHeroReady ? "Cancel" : "Ready Up"
        }
        return store.sessionEndsAfterHandSummary ? "See Final Results" : "Next Hand"
    }

    private var requiresReadyUp: Bool {
        store.state.gameMode == .classicPoker && !store.sessionEndsAfterHandSummary
    }

    private var isHeroReady: Bool {
        guard let heroID = store.state.heroID else { return false }
        return store.state.players.first(where: { $0.id == heroID })?.isReady ?? false
    }

    private var activePlayers: [Player] {
        store.state.players.filter { !$0.isEliminated && $0.stack > 0 }
    }

    private var readyCountDetail: String? {
        guard requiresReadyUp, !activePlayers.isEmpty else { return nil }
        let readyCount = activePlayers.filter(\.isReady).count
        return "\(readyCount)/\(activePlayers.count)"
    }

    private var readyStatusByPlayerID: [String: PlayerReadyStatus] {
        guard requiresReadyUp else { return [:] }
        return Dictionary(uniqueKeysWithValues: store.state.players.map { player in
            let status: PlayerReadyStatus
            if player.isEliminated || player.stack <= 0 {
                status = .out
            } else {
                status = player.isReady ? .ready : .waiting
            }
            return (player.id, status)
        })
    }

    var body: some View {
        let canStartNextHand = store.canStartNextHand
        return ResultsScreenView(
            stats: stats,
            winnerLabel: winners.count > 1 ? "Split Pot" : "Hand Winner",
            winners: winners,
            winnerSubtitle: winnerSubtitle,
            statsSectionTitle: "Leaderboard",
            buttonTitle: buttonTitle,
            onButton: primaryAction,
            buttonDetail: readyCountDetail,
            secondaryButtonTitle: canStartNextHand ? "Next Hand" : nil,
            onSecondaryButton: { continueIfNeeded() },
            tertiaryButtonTitle: "Finish Game",
            onTertiaryButton: { store.requestManualEndGame() },
            readyStatusByPlayerID: readyStatusByPlayerID,
            buttonFillColor: Theme.Color.green,
            buttonTrackColor: Theme.Color.green.opacity(0.25),
            buttonTextColor: Theme.Color.primary
        )
        .alert("There can only be 1 winner", isPresented: $store.showManualFinishTieWarning) {
            Button("Continue", role: .cancel) {
                store.dismissManualFinishTieWarning()
            }
        } message: {
            Text("Players are tied for the most chips. Keep playing to break the tie.")
        }
    }

    private func primaryAction() {
        if requiresReadyUp {
            store.toggleReady()
        } else {
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
