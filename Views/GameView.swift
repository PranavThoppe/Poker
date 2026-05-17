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
                    pot: store.state.pot
                )

                Spacer()

                ActionBarView(
                    callAmount: store.state.callAmount,
                    raiseAmount: store.state.raiseAmount,
                    onCall: { store.call() },
                    onRaise: { store.raise(store.state.raiseAmount) },
                    onFold: { store.fold() }
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

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
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
    let onCall: () -> Void
    let onRaise: () -> Void
    let onFold: () -> Void

    @State private var showOptions = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ActionPill(label: "Call \(callAmount)", action: onCall)
            ActionPill(label: "Raise \(raiseAmount)", action: onRaise)
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
        .confirmationDialog("More Options", isPresented: $showOptions, titleVisibility: .hidden) {
            Button("Fold", role: .destructive) { onFold() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ActionPill: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.actionLabel)
                .foregroundStyle(Theme.Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
        }
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
