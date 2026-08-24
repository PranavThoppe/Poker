import SwiftUI

/// Synced showdown table: live players in reveal order, Show with an 8s countdown, then the
/// winner decides when to move the table on to the hand summary. Practice skips the Continue
/// countdown and always lets the human advance.
struct ShowdownRevealView: View {
    @EnvironmentObject var store: GameStore

    private static let autoShowSeconds: TimeInterval = 8
    private static let flipDuration: TimeInterval = 0.45

    @State private var countdownStartedAt: Date?
    @State private var advanceStartedAt: Date?
    @State private var isBoardRevealing = false
    @State private var faceUpPlayerIDs: Set<String> = []

    private var isPractice: Bool { store.state.gameMode == .practiceVsCPU }
    private var canHeroContinue: Bool {
        store.isHeroShowdownDecider || (isPractice && store.state.heroID != nil)
    }

    private var result: HandResult? { store.state.handResult }
    private var winnerIDs: Set<String> { Set(result?.winnerIDs ?? []) }
    private var allShown: Bool {
        store.state.pendingRevealPlayerID == nil && !(result?.reveals.isEmpty ?? true)
    }

    private var livePlayers: [Player] {
        let order = store.showdownRevealOrder
        let byID = Dictionary(uniqueKeysWithValues: store.state.players.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }

    private var pendingName: String {
        name(of: store.state.pendingRevealPlayerID)
    }

    private var deciderName: String {
        name(of: store.showdownDeciderID)
    }

    private func name(of playerID: String?) -> String {
        guard let playerID else { return "" }
        return store.state.players.first { $0.id == playerID }?.name ?? ""
    }

    private var highlightedCardIDs: Set<String>? {
        guard allShown, let result else { return nil }
        let ids = result.reveals
            .filter { winnerIDs.contains($0.playerID) }
            .flatMap(\.bestFive)
            .map(\.id)
        return ids.isEmpty ? nil : Set(ids)
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Spacing.lg)

                ShowdownPlayersRow(
                    players: livePlayers,
                    pendingID: store.state.pendingRevealPlayerID,
                    reveals: result?.reveals ?? [],
                    faceUpPlayerIDs: faceUpPlayerIDs,
                    winnerIDs: allShown ? winnerIDs : []
                )

                Spacer()

                BoardView(
                    board: store.state.board,
                    pot: store.state.lastPotAwarded,
                    streetLabel: "Showdown",
                    highlightedCardIDs: highlightedCardIDs,
                    isRevealing: $isBoardRevealing
                )

                if allShown {
                    rankCaption
                        .padding(.top, Theme.Spacing.md)
                }

                Spacer()

                showdownAction
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.md)

                HeroRow(
                    holeCards: store.state.heroHoleCards,
                    handRank: store.state.heroHandRank,
                    heroID: store.state.heroID,
                    players: store.state.players
                )
                .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.lg)
            }
        }
        .onAppear {
            faceUpPlayerIDs = Set((result?.reveals ?? []).map(\.playerID))
        }
        .onChange(of: revealedPlayerIDs) { _, newIDs in
            let added = newIDs.subtracting(faceUpPlayerIDs)
            guard !added.isEmpty else { return }
            withAnimation(.easeInOut(duration: Self.flipDuration)) {
                faceUpPlayerIDs.formUnion(added)
            }
        }
        .task(id: store.state.pendingRevealPlayerID) {
            countdownStartedAt = store.isHeroTurn ? Date() : nil
            guard store.isHeroTurn else { return }
            try? await Task.sleep(for: .seconds(Self.autoShowSeconds))
            guard !Task.isCancelled else { return }
            guard store.state.phase == .showdown, store.isHeroTurn else { return }
            store.showCards()
        }
        .task(id: store.isHeroShowdownDecider) {
            guard !isPractice, store.isHeroShowdownDecider else {
                advanceStartedAt = nil
                return
            }
            advanceStartedAt = Date()
            try? await Task.sleep(for: .seconds(GameStore.showdownAdvanceSeconds))
            guard !Task.isCancelled else { return }
            guard store.state.phase == .showdown, store.isHeroShowdownDecider else { return }
            store.advanceToHandSummary(auto: true)
        }
    }

    private var revealedPlayerIDs: Set<String> {
        Set((result?.reveals ?? []).map(\.playerID))
    }

    private var rankCaption: some View {
        let ranks = (result?.reveals ?? [])
            .filter { winnerIDs.contains($0.playerID) }
            .map(\.rank.rawValue)
        let label = ranks.isEmpty ? "Showdown" : Set(ranks).sorted().joined(separator: " · ")
        return Text(label)
            .font(Theme.Font.subhead)
            .foregroundStyle(Theme.Color.secondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    @ViewBuilder
    private var showdownAction: some View {
        if allShown {
            if canHeroContinue {
                countdownButton(
                    title: "Continue",
                    startedAt: isPractice ? nil : advanceStartedAt,
                    duration: GameStore.showdownAdvanceSeconds,
                    action: { store.advanceToHandSummary() }
                )
            } else if deciderName.isEmpty {
                Color.clear.frame(height: Theme.Size.actionPillH)
            } else {
                waitingLabel("Waiting for \(deciderName)…")
            }
        } else if store.isHeroTurn {
            countdownButton(
                title: "Show",
                startedAt: countdownStartedAt,
                duration: Self.autoShowSeconds,
                action: { store.showCards() }
            )
        } else {
            waitingLabel(pendingName.isEmpty ? "Waiting…" : "Waiting for \(pendingName)…")
        }
    }

    private func countdownButton(
        title: String,
        startedAt: Date?,
        duration: TimeInterval,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if let startedAt {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let elapsed = context.date.timeIntervalSince(startedAt)
                        CountdownCapsuleFill(
                            progress: min(1, elapsed / duration),
                            trackColor: Theme.Color.green.opacity(0.25),
                            fillColor: Theme.Color.green
                        )
                    }
                } else {
                    Capsule().fill(Theme.Color.green)
                }

                Text(title)
                    .font(Theme.Font.actionLabel)
                    .foregroundStyle(Theme.Color.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
            .clipShape(Capsule())
        }
    }

    private func waitingLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.actionLabel)
            .foregroundStyle(Theme.Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
    }
}

private struct ShowdownPlayersRow: View {
    let players: [Player]
    let pendingID: String?
    let reveals: [RevealedHand]
    let faceUpPlayerIDs: Set<String>
    let winnerIDs: Set<String>

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tiles
                .frame(maxWidth: .infinity)

            ScrollView(.horizontal, showsIndicators: false) {
                tiles
            }
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            ForEach(players) { player in
                ShowdownPlayerTile(
                    player: player,
                    isPending: player.id == pendingID,
                    reveal: reveals.first(where: { $0.playerID == player.id }),
                    isFaceUp: faceUpPlayerIDs.contains(player.id),
                    isWinner: winnerIDs.contains(player.id)
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

private struct ShowdownPlayerTile: View {
    let player: Player
    let isPending: Bool
    let reveal: RevealedHand?
    let isFaceUp: Bool
    let isWinner: Bool

    private var cardWidth: CGFloat { Theme.Size.cardW * 0.85 }
    private var cardHeight: CGFloat { Theme.Size.cardH * 0.85 }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            holeCards
                .frame(height: cardHeight)

            AvatarView(player: player, size: Theme.Size.avatarMD)
                .overlay {
                    if isWinner {
                        Circle()
                            .stroke(Theme.Color.green, lineWidth: 2)
                    }
                }

            Text(player.name)
                .font(Theme.Font.playerName)
                .foregroundStyle(Theme.Color.primary)

            Text("\(player.stack)")
                .font(Theme.Font.playerStack)
                .foregroundStyle(Theme.Color.secondary)

            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Color.green)
                .opacity(isPending ? 1 : 0)
                .frame(height: 8)
        }
        .frame(minWidth: 72)
    }

    @ViewBuilder
    private var holeCards: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<2, id: \.self) { index in
                if let reveal, reveal.holeCards.indices.contains(index), isFaceUp {
                    FlippableBoardCard(
                        card: reveal.holeCards[index],
                        isFaceUp: true,
                        width: cardWidth,
                        height: cardHeight
                    )
                } else {
                    Color.clear
                        .frame(width: cardWidth, height: cardHeight)
                }
            }
        }
    }
}

#Preview("Showdown Reveal") {
    ShowdownRevealView()
        .environmentObject(GameStore.mockShowdown)
}

#if DEBUG
#Preview("Pot math checks") {
    Text(PokerEnginePotVerification.runAll() ? "Pot math OK" : "Pot math FAILED")
        .font(Theme.Font.headline)
        .foregroundStyle(Theme.Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.background)
}
#endif
