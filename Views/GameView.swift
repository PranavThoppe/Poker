import SwiftUI

// MARK: - Root game screen

struct GameView: View {
    @EnvironmentObject var store: GameStore

    private var hero: Player? {
        guard let heroID = store.state.heroID else { return nil }
        return store.state.players.first { $0.id == heroID }
    }

    private var maximumRaiseAmount: Int {
        guard let hero else { return store.state.raiseAmount }
        return hero.currentBet + hero.stack
    }

    private var canRaise: Bool {
        maximumRaiseAmount > store.state.streetBetLevel
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Spacing.lg)

                PlayersStripView(
                    players: store.state.players,
                    activePlayerID: store.state.activePlayerID
                )

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
                    maximumRaiseAmount: maximumRaiseAmount,
                    raiseIncrement: PokerEngine.smallBlind,
                    canRaise: canRaise,
                    isHeroTurn: store.isHeroTurn,
                    onCheck: { store.check() },
                    onCall: { store.call() },
                    onRaise: { store.raise($0) },
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
    let activePlayerID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                ForEach(players) { player in
                    PlayerTileView(
                        player: player,
                        isActiveTurn: player.id == activePlayerID
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

private struct PlayerTileView: View {
    let player: Player
    let isActiveTurn: Bool

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

            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Color.green)
                .opacity(isActiveTurn ? 1 : 0)
                .frame(height: 8)

            if player.currentBet > 0 {
                BetChip(amount: player.currentBet)
            } else {
                Spacer().frame(height: 20)
            }
        }
        .frame(width: 56)
        .animation(.easeInOut(duration: 0.2), value: isActiveTurn)
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
    let maximumRaiseAmount: Int
    let raiseIncrement: Int
    let canRaise: Bool
    let isHeroTurn: Bool
    let onCheck: () -> Void
    let onCall: () -> Void
    let onRaise: (Int) -> Void
    let onFold: () -> Void
    let onFinishGame: () -> Void

    @State private var showOptions = false
    @State private var showRaiseCustomization = false
    @State private var selectedRaiseAmount = 0

    private var actionsEnabled: Bool { isHeroTurn }
    private var raiseEnabled: Bool { actionsEnabled && canRaise }

    private var selectedAmount: Int {
        min(max(selectedRaiseAmount, raiseAmount), maximumRaiseAmount)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if showRaiseCustomization {
                RaiseCustomizationView(
                    amount: $selectedRaiseAmount,
                    minimumAmount: raiseAmount,
                    maximumAmount: maximumRaiseAmount,
                    increment: raiseIncrement
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: Theme.Spacing.sm) {
                if callAmount == 0 {
                    ActionPill(label: "Check", action: onCheck, isEnabled: actionsEnabled)
                } else {
                    ActionPill(label: "Call \(callAmount)", action: onCall, isEnabled: actionsEnabled)
                }
                RaiseSplitButton(
                    amount: selectedAmount,
                    isExpanded: showRaiseCustomization,
                    isEnabled: raiseEnabled,
                    onRaise: {
                        showRaiseCustomization = false
                        onRaise(selectedAmount)
                    },
                    onCustomize: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showRaiseCustomization.toggle()
                        }
                    }
                )
                moreButton
            }
            .frame(height: Theme.Size.actionPillH)
        }
        .onAppear {
            selectedRaiseAmount = raiseAmount
        }
        .onChange(of: raiseAmount) { newValue in
            selectedRaiseAmount = newValue
            showRaiseCustomization = false
        }
        .onChange(of: maximumRaiseAmount) { newValue in
            selectedRaiseAmount = min(selectedAmount, newValue)
        }
        .onChange(of: isHeroTurn) { newValue in
            if !newValue {
                showRaiseCustomization = false
            }
        }
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

private struct RaiseSplitButton: View {
    let amount: Int
    let isExpanded: Bool
    let isEnabled: Bool
    let onRaise: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRaise) {
                Text("Raise to \(amount)")
                    .font(Theme.Font.actionLabel)
                    .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Size.actionPillH)
            }

            Rectangle()
                .fill(Theme.Color.background.opacity(0.8))
                .frame(width: 1, height: 24)

            Button(action: onCustomize) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                    .frame(width: 38, height: Theme.Size.actionPillH)
            }
        }
        .background(Theme.Color.surface)
        .clipShape(Capsule())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct RaiseCustomizationView: View {
    @Binding var amount: Int
    let minimumAmount: Int
    let maximumAmount: Int
    let increment: Int

    private var canDecrease: Bool { amount > minimumAmount }
    private var canIncrease: Bool { amount < maximumAmount }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            presetButton("Min") {
                amount = minimumAmount
            }

            adjustmentButton(systemName: "minus", isEnabled: canDecrease) {
                amount = max(minimumAmount, amount - increment)
            }

            Text("\(amount)")
                .font(Theme.Font.actionLabel)
                .foregroundStyle(Theme.Color.primary)
                .monospacedDigit()
                .frame(minWidth: 44)

            adjustmentButton(systemName: "plus", isEnabled: canIncrease) {
                amount = min(maximumAmount, amount + increment)
            }

            presetButton("All-in") {
                amount = maximumAmount
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Color.surfaceDeep)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
    }

    private func presetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.primary)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(height: 34)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
        }
    }

    private func adjustmentButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                .frame(width: 34, height: 34)
                .background(Theme.Color.surface)
                .clipShape(Circle())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
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
                    .padding(.leading, 15)
            }
            Spacer(minLength: 0)
            HeroSideButtons()
        }
    }
}

// MARK: - Side buttons (chat + info)

private struct HeroSideButtons: View {
    private let buttonSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            sideButton(systemName: "bubble.left.fill") {}
            sideButton(systemName: "info.circle.fill") {}
        }
    }

    private func sideButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Color.primary)
                .frame(width: buttonSize, height: buttonSize)
                .background(Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        }
    }
}

// MARK: - Hole cards (overlapping)

struct HoleCardsView: View {
    let cards: [Card]

    /// Horizontal offset so the back card’s center suit stays visible beside the front card.
    private let spread: CGFloat = 30

    var body: some View {
        ZStack {
            if cards.count > 0 {
                CardView(card: cards[0], width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -spread, y: 4)
            }
            if cards.count > 1 {
                CardView(card: cards[1], width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(4))
                    .offset(x: spread, y: -4)
            }
        }
        .frame(
            width: Theme.Size.holeCardW + spread * 2,
            height: Theme.Size.holeCardH + 16
        )
    }
}

// MARK: - Hand summary tile

struct HandSummaryCard: View {
    let player: Player
    let handRank: HandRank?

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            rankLabel

            AvatarView(player: player, size: Theme.Size.avatarMD)

            Text("\(player.stack)")
                .font(Theme.Font.heroStack)
                .foregroundStyle(Theme.Color.primary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }

    /// Sized to the widest rank label so the tile width stays stable across hands.
    private var rankLabel: some View {
        ZStack {
            ForEach(HandRank.allCases, id: \.self) { rank in
                Text(rank.rawValue)
                    .font(Theme.Font.handRank)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .hidden()
            }

            Text(handRank?.rawValue ?? "")
                .font(Theme.Font.handRank)
                .foregroundStyle(Theme.Color.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .opacity(handRank == nil ? 0 : 1)
        }
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
