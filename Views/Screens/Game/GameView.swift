import SwiftUI

// MARK: - Root game screen

struct GameView: View {
    @EnvironmentObject var store: GameStore
    @State private var isBoardRevealing = false

    private var maximumRaiseAmount: Int {
        store.heroMaxRaise
    }

    private var canRaise: Bool {
        maximumRaiseAmount > store.state.streetBetLevel
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Leave a clear lane above the player row for the practice exit control.
                Spacer().frame(height: Theme.Spacing.xl + Theme.Spacing.xs)

                PlayersStripView(
                    players: store.state.players,
                    activePlayerID: store.state.activePlayerID
                )

                if store.isHeroSittingOut {
                    Text("Sitting out · Spectating this hand")
                        .font(Theme.Font.subhead)
                        .foregroundStyle(Theme.Color.secondary)
                }

                Spacer()

                BoardView(
                    board: store.state.board,
                    pot: store.state.pot,
                    streetLabel: store.state.bettingRound.displayName,
                    isRevealing: $isBoardRevealing,
                    onRevealFinished: { store.boardRevealFinished() }
                )
                .id("playing-board")

                Spacer()

                ActionBarView(
                    callAmount: store.state.callAmount,
                    raiseAmount: store.state.raiseAmount,
                    maximumRaiseAmount: maximumRaiseAmount,
                    raiseIncrement: store.tableSmallBlind,
                    canRaise: canRaise,
                    isHeroTurn: store.isHeroTurn && !isBoardRevealing && !store.isBoardRevealPending,
                    demoCheckCallPulse: store.marketingDemoCheckCallPulse,
                    demoRaisePulse: store.marketingDemoRaisePulse,
                    onCheck: { store.check() },
                    onCall: { store.call() },
                    onRaise: { store.raise($0) },
                    onFold: { store.fold() }
                )
                .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.md)

                HeroRow(
                    holeCards: store.state.heroHoleCards,
                    handRank: store.displayedHeroHandRank,
                    heroID: store.state.heroID,
                    players: store.state.players,
                    isDealing: store.isWaitingForHoleCards
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
    var highlightedCardIDs: Set<String>? = nil
    @Binding var isRevealing: Bool
    /// Fired when a flip cycle ends, or when new cards were already face-up (nothing to animate).
    var onRevealFinished: (() -> Void)? = nil

    /// Face-up flags lag the engine board so new cards can flip in.
    @State private var isFaceUp = Array(repeating: false, count: 5)
    @State private var hasSyncedInitialBoard = false

    private static let flipDuration: TimeInterval = 0.45
    private static let staggerDelay: TimeInterval = 0.22

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
                        FlippableBoardCard(card: card, isFaceUp: isFaceUp[i])
                            .opacity(boardCardOpacity(for: card))
                    } else {
                        CardBackView()
                    }
                }
            }

            RollingPotValue(value: pot)
                .padding(.trailing, Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.md)
        // Restart whenever the dealt board changes. Cancellation snaps any still-hidden
        // cards face-up so a mid-flip interrupt can never leave the street face-down.
        .task(id: boardSignature) {
            await syncBoardFaceUp()
        }
        .onDisappear {
            isRevealing = false
        }
    }

    /// Stable identity for board contents so the reveal task restarts when cards appear/clear.
    private var boardSignature: String {
        board.map { $0?.id ?? "_" }.joined(separator: "|")
    }

    private func boardCardOpacity(for card: Card) -> Double {
        guard let highlightedCardIDs else { return 1 }
        return highlightedCardIDs.contains(card.id) ? 1 : 0.35
    }

    @MainActor
    private func syncBoardFaceUp() async {
        for i in 0..<5 {
            if (board[safe: i] ?? nil) == nil {
                isFaceUp[i] = false
            }
        }

        let pending = (0..<5).filter { i in
            (board[safe: i] ?? nil) != nil && !isFaceUp[i]
        }

        let shouldAnimate = hasSyncedInitialBoard
        hasSyncedInitialBoard = true

        guard !pending.isEmpty else {
            isRevealing = false
            onRevealFinished?()
            return
        }

        // Cold start / rejoin: show already-dealt cards without replaying flips.
        guard shouldAnimate else {
            for i in pending { isFaceUp[i] = true }
            isRevealing = false
            onRevealFinished?()
            return
        }

        isRevealing = true
        defer {
            // Always finish face-up for every dealt seat — including when this task is
            // cancelled because a newer board signature arrived.
            for i in 0..<5 where (board[safe: i] ?? nil) != nil {
                isFaceUp[i] = true
            }
            isRevealing = false
            onRevealFinished?()
        }

        for (offset, index) in pending.enumerated() {
            if Task.isCancelled { return }
            if offset > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Self.staggerDelay * 1_000_000_000))
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: Self.flipDuration)) {
                isFaceUp[index] = true
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.flipDuration * 1_000_000_000))
    }
}

// MARK: - Pot counter

/// Counts a growing pot one chip at a time and rolls only the digits that change.
/// A large raise is still capped to a short duration so the table remains responsive.
private struct RollingPotValue: View {
    let value: Int

    @State private var displayedValue: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(String(displayedValue).enumerated()), id: \.offset) { _, digit in
                RollingPotDigit(digit: digit)
            }
        }
        .font(Theme.Font.pot.monospacedDigit())
        .foregroundStyle(Theme.Color.primary)
        .accessibilityLabel("Pot \(displayedValue)")
        .task(id: value) {
            await count(to: value)
        }
    }

    @MainActor
    private func count(to target: Int) async {
        // Pot decreases are hand transitions rather than chips entering the pot, so snap them.
        guard target >= displayedValue else {
            displayedValue = target
            return
        }

        let change = target - displayedValue
        guard change > 0 else { return }

        // Small bets visibly tick through every chip. Bigger pots use shorter ticks, capped
        // at roughly three quarters of a second overall.
        let tickDuration = min(0.02, max(0.001, 0.75 / Double(change)))
        let delay = UInt64(tickDuration * 1_000_000_000)
        let startingValue = displayedValue

        for nextValue in (startingValue + 1)...target {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            withAnimation(.linear(duration: min(0.06, tickDuration * 1.8))) {
                displayedValue = nextValue
            }
        }
    }
}

/// Swaps a single digit on a tiny vertical wheel, leaving unchanged digits still.
private struct RollingPotDigit: View {
    let digit: Character

    var body: some View {
        ZStack {
            Text(String(digit))
                .id(digit)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .animation(.linear(duration: 0.06), value: digit)
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
    var demoCheckCallPulse: Int = 0
    var demoRaisePulse: Int = 0
    let onCheck: () -> Void
    let onCall: () -> Void
    let onRaise: (Int) -> Void
    let onFold: () -> Void

    @State private var showRaiseCustomization = false
    /// `nil` means use the engine's current min-raise; set only while customizing this decision.
    @State private var raiseOverride: Int?
    @State private var checkCallPulse = 0
    @State private var raisePulse = 0

    private var actionsEnabled: Bool { isHeroTurn }
    private var raiseEnabled: Bool { actionsEnabled && canRaise }

    private var selectedAmount: Int {
        guard let raiseOverride else { return raiseAmount }
        return min(max(raiseOverride, raiseAmount), maximumRaiseAmount)
    }

    private var raiseAmountBinding: Binding<Int> {
        Binding(
            get: { selectedAmount },
            set: { raiseOverride = $0 }
        )
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if showRaiseCustomization && canRaise {
                RaiseCustomizationView(
                    amount: raiseAmountBinding,
                    minimumAmount: raiseAmount,
                    maximumAmount: maximumRaiseAmount,
                    increment: raiseIncrement
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: Theme.Spacing.sm) {
                ActionPill(
                    label: callAmount == 0 ? "Check" : "Call \(callAmount)",
                    action: {
                        checkCallPulse += 1
                        if callAmount == 0 {
                            onCheck()
                        } else {
                            onCall()
                        }
                    },
                    isEnabled: actionsEnabled,
                    pulseTrigger: checkCallPulse + demoCheckCallPulse
                )
                if canRaise {
                    RaiseSplitButton(
                        amount: selectedAmount,
                        maximumAmount: maximumRaiseAmount,
                        isEnabled: raiseEnabled,
                        pulseTrigger: raisePulse + demoRaisePulse,
                        onRaise: {
                            let amount = selectedAmount
                            raisePulse += 1
                            showRaiseCustomization = false
                            raiseOverride = nil
                            onRaise(amount)
                        },
                        onCustomize: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showRaiseCustomization.toggle()
                            }
                        }
                    )
                }
                foldButton
            }
            .frame(height: Theme.Size.actionPillH)
        }
        .onChange(of: raiseAmount) { _ in
            showRaiseCustomization = false
        }
        .onChange(of: isHeroTurn) { newValue in
            if newValue {
                raiseOverride = nil
            } else {
                showRaiseCustomization = false
            }
        }
    }

    private var foldButton: some View {
        Button(action: onFold) {
            Text("Fold")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Color.primary)
                .frame(width: Theme.Size.actionPillH, height: Theme.Size.actionPillH)
                .background(actionsEnabled ? Theme.Color.red : Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        }
        .disabled(!actionsEnabled)
        .opacity(actionsEnabled ? 1 : 0.4)
        .accessibilityLabel("Fold hand")
    }
}

private struct RaiseSplitButton: View {
    let amount: Int
    let maximumAmount: Int
    let isEnabled: Bool
    let pulseTrigger: Int
    let onRaise: () -> Void
    let onCustomize: () -> Void

    private var label: String {
        amount >= maximumAmount ? "All in \(amount)" : "Raise to \(amount)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRaise) {
                Text(label)
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
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                    .frame(width: 38, height: Theme.Size.actionPillH)
            }
        }
        .background(Theme.Color.surface)
        .clipShape(Capsule())
        .tapGlowRipple(trigger: pulseTrigger, color: Theme.Color.primary)
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
    let pulseTrigger: Int

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
        .tapGlowRipple(trigger: pulseTrigger, color: Theme.Color.primary)
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
    var isDealing: Bool = false

    private var hero: Player? {
        guard let id = heroID else { return nil }
        return players.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            HoleCardsView(cards: holeCards, isDealing: isDealing)
            if let hero {
                HandSummaryCard(player: hero, handRank: handRank)
                    .padding(.leading, 15)
            }
            Spacer(minLength: 0)
            HeroSideButtons()
        }
    }
}

// MARK: - Side buttons (info)

private struct HeroSideButtons: View {
    private let buttonSize: CGFloat = 44
    @State private var showHandRankings = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            sideButton(systemName: "info.circle.fill") {
                showHandRankings = true
            }
        }
        .sheet(isPresented: $showHandRankings) {
            HandRankingsView()
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.hidden)
                .presentationContentInteraction(.scrolls)
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
    var isDealing: Bool = false

    /// Horizontal offset so the back card’s center suit stays visible beside the front card.
    private let spread: CGFloat = 30

    var body: some View {
        ZStack {
            if isDealing && cards.isEmpty {
                CardBackView(width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -spread, y: 4)
                CardBackView(width: Theme.Size.holeCardW, height: Theme.Size.holeCardH)
                    .rotationEffect(.degrees(4))
                    .offset(x: spread, y: -4)
            } else {
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
