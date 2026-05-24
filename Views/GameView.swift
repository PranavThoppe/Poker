import SwiftUI

// MARK: - Root game screen

struct GameView: View {
    @EnvironmentObject var store: GameStore

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Spacing.lg)

                PlayersStripView(players: store.state.players)

                Spacer()

                BoardView(
                    board: store.state.board,
                    pot: store.state.pot,
                    streetLabel: store.state.bettingRound.displayName
                )

                Spacer()

                ActionBarView(
                    callAmount: store.state.callAmount,
                    raiseAmount: store.state.raiseAmount,
                    isHeroTurn: store.isHeroTurn,
                    onCheck: { store.check() },
                    onCall: { store.call() },
                    onRaise: { store.raise(store.state.raiseAmount) },
                    onFold: { store.fold() },
                    onFinishGame: { store.endGame() }
                )
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
    }
}

// MARK: - Players strip (top row)

struct PlayersStripView: View {
    let players: [Player]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                ForEach(players) { player in
                    PlayerTileView(player: player)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

private struct PlayerTileView: View {
    let player: Player

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            AvatarView(player: player, size: Theme.Size.avatarMD)
                .opacity(player.isFolded ? 0.35 : 1.0)

            Text(player.name)
                .font(Theme.Font.playerName)
                .foregroundStyle(player.isFolded ? Theme.Color.secondary : Theme.Color.primary)

            Text("\(player.stack)")
                .font(Theme.Font.playerStack)
                .foregroundStyle(Theme.Color.secondary)

            if player.currentBet > 0 {
                BetChip(amount: player.currentBet)
            } else {
                Spacer().frame(height: 20)
            }
        }
        .frame(width: 56)
    }
}

// MARK: - Board

struct BoardView: View {
    let board: [Card?]
    let pot: Int
    var streetLabel: String? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            if let streetLabel {
                Text(streetLabel)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(0..<5, id: \.self) { i in
                    if let card = board[safe: i] ?? nil {
                        CardView(card: card)
                    } else {
                        CardBackView()
                    }
                }
            }

            Text("\(pot)")
                .font(Theme.Font.pot)
                .foregroundStyle(Theme.Color.primary)
                .padding(.trailing, Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

// MARK: - Action bar

struct ActionBarView: View {
    let callAmount: Int
    let raiseAmount: Int
    let isHeroTurn: Bool
    let onCheck: () -> Void
    let onCall: () -> Void
    let onRaise: () -> Void
    let onFold: () -> Void
    let onFinishGame: () -> Void

    @State private var showOptions = false

    private var actionsEnabled: Bool { isHeroTurn }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if callAmount == 0 {
                ActionPill(label: "Check", action: onCheck, isEnabled: actionsEnabled)
            } else {
                ActionPill(label: "Call \(callAmount)", action: onCall, isEnabled: actionsEnabled)
            }
            ActionPill(label: "Raise \(raiseAmount)", action: onRaise, isEnabled: actionsEnabled)
            moreButton
        }
        .frame(height: Theme.Size.actionPillH)
    }

    private var moreButton: some View {
        Button(action: { showOptions.toggle() }) {
            Image(systemName: showOptions ? "chevron.down" : "chevron.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Color.primary)
                .frame(width: Theme.Size.actionPillH, height: Theme.Size.actionPillH)
                .background(Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        }
        .disabled(!actionsEnabled)
        .opacity(actionsEnabled ? 1 : 0.4)
        .confirmationDialog("More Options", isPresented: $showOptions, titleVisibility: .hidden) {
            Button("Fold", role: .destructive) { onFold() }
            Button("Finish game (test)") { onFinishGame() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ActionPill: View {
    let label: String
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.actionLabel)
                .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Hero row (hole cards + hand summary)

struct HeroRow: View {
    let holeCards: [Card]
    let handRank: HandRank?
    let heroID: String?
    let players: [Player]

    private var hero: Player? {
        guard let id = heroID else { return nil }
        return players.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            HoleCardsView(cards: holeCards)
            if let hero {
                HandSummaryCard(player: hero, handRank: handRank)
            }
        }
    }
}

// MARK: - Hole cards (overlapping)

struct HoleCardsView: View {
    let cards: [Card]

    var body: some View {
        ZStack {
            if cards.count > 0 {
                CardView(card: cards[0], width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -14, y: 4)
            }
            if cards.count > 1 {
                CardView(card: cards[1], width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(4))
                    .offset(x: 14, y: -4)
            }
        }
        .frame(height: Theme.Size.holeCardH + 16)
    }
}

// MARK: - Hand summary tile

struct HandSummaryCard: View {
    let player: Player
    let handRank: HandRank?

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let rank = handRank {
                Text(rank.rawValue)
                    .font(Theme.Font.handRank)
                    .foregroundStyle(Theme.Color.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            AvatarView(player: player, size: Theme.Size.avatarMD)

            Text("\(player.stack)")
                .font(Theme.Font.heroStack)
                .foregroundStyle(Theme.Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }
}

// MARK: - Safe subscript helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview("Game Screen") {
    GameView()
        .environmentObject(GameStore.mock)
}

#Preview("Solo Game") {
    GameView()
        .environmentObject(GameStore.mockSoloPlaying)
}
