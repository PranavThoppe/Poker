#if DEBUG
import Foundation

/// DEBUG pot-math checks. Wired into `PokerEngineVerification.runAll()`.
/// A dedicated XCTest target is not added: the Messages extension is a
/// synchronized folder with no importable module, so these run in-process.
enum PokerEnginePotVerification {
    static func runAll() -> Bool {
        twoWayChopSplitsEvenly()
            && threeWayChopSplitsEvenly()
            && oddChipGoesClockwiseOfButton()
            && sidePotAwardsOnlyEligibleWinners()
            && shortStackWinsOnlyMainPot()
            && foldedChipsStayInPot()
            && uncalledBetReturnsOnFoldOut()
            && chipsAreConservedOnShowdown()
            && chipsAreConservedOnFoldOut()
            && shouldEndGameAfterSplit()
            && showdownKeepsRevealsEmptyUntilShown()
            && lastAggressorShowsFirst()
            && showdownRevealIsIdempotent()
            && hostCardsOverrideGuestSpoof()
            && cannotRaiseBeyondOpponentEffectiveStack()
            && facingAllInOffersCallOnly()
            && headsUpAllInNeverCreatesSidePot()
            && uncalledBetReturnsWhenStreetCloses()
            && uncalledBetIsReturnedBeforePots()
            && splitPotLabelOnlyForActualChop()
            && bustedShowdownContenderStaysInReveal()
    }

    static func twoWayChopSplitsEvenly() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
            ],
            contributions: ["a": 50, "b": 50],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        return state.players[0].stack == 450
            && state.players[1].stack == 450
            && Set(state.handResult?.winnerIDs ?? []) == ["a", "b"]
            && state.pot == 0
            && state.handResult?.reveals.isEmpty == true
            && state.pendingRevealPlayerID != nil
    }

    static func threeWayChopSplitsEvenly() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                Player(id: "c", name: "C", stack: 400, avatarIndex: 2),
            ],
            contributions: ["a": 33, "b": 33, "c": 33],
            holes: boardPlayHoles(ids: ["a", "b", "c"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        let stacks = state.players.map(\.stack)
        return stacks == [433, 433, 433]
            && Set(state.handResult?.winnerIDs ?? []) == ["a", "b", "c"]
            && state.pot == 0
    }

    /// Pot 101, two-way chop, button is A. First seat left of the button (B) gets the extra chip.
    static func oddChipGoesClockwiseOfButton() -> Bool {
        var folded = Player(id: "c", name: "C", stack: 499, avatarIndex: 2)
        folded.isFolded = true
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                folded,
            ],
            contributions: ["a": 50, "b": 50, "c": 1],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        let a = state.players.first { $0.id == "a" }?.stack
        let b = state.players.first { $0.id == "b" }?.stack
        return a == 450 && b == 451
    }

    /// A all-in for 20 with the nuts, B and C put in 100. A takes 60; C takes the 160 side pot.
    static func sidePotAwardsOnlyEligibleWinners() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                Player(id: "c", name: "C", stack: 400, avatarIndex: 2),
            ],
            contributions: ["a": 20, "b": 100, "c": 100],
            holes: [
                "a": [Card(rank: .ace, suit: .hearts), Card(rank: .ace, suit: .diamonds)],
                "b": [Card(rank: .two, suit: .clubs), Card(rank: .three, suit: .clubs)],
                "c": [Card(rank: .king, suit: .hearts), Card(rank: .king, suit: .diamonds)],
            ],
            board: [
                Card(rank: .seven, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .two, suit: .hearts),
                Card(rank: .four, suit: .diamonds),
            ]
        )
        var engine = PokerEngine()
        let pots = engine.buildPots(state)
        guard pots.count == 2,
              pots[0].amount == 60, pots[0].isSidePot == false,
              pots[1].amount == 160, pots[1].isSidePot == true
        else { return false }

        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        let a = state.players.first { $0.id == "a" }
        let b = state.players.first { $0.id == "b" }
        let c = state.players.first { $0.id == "c" }
        return a?.stack == 60
            && b?.stack == 400
            && c?.stack == 560
            && state.handResult?.payouts["a"] == 60
            && state.handResult?.payouts["c"] == 160
    }

    static func shortStackWinsOnlyMainPot() -> Bool {
        sidePotAwardsOnlyEligibleWinners()
    }

    static func foldedChipsStayInPot() -> Bool {
        var folded = Player(id: "c", name: "C", stack: 480, avatarIndex: 2)
        folded.isFolded = true
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                folded,
            ],
            contributions: ["a": 20, "b": 20, "c": 20],
            holes: [
                "a": [Card(rank: .ace, suit: .hearts), Card(rank: .ace, suit: .diamonds)],
                "b": [Card(rank: .two, suit: .clubs), Card(rank: .three, suit: .clubs)],
                "c": [Card(rank: .king, suit: .hearts), Card(rank: .king, suit: .diamonds)],
            ],
            board: [
                Card(rank: .seven, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .two, suit: .hearts),
                Card(rank: .four, suit: .diamonds),
            ]
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        return state.players.first { $0.id == "a" }?.stack == 460
            && state.players.first { $0.id == "b" }?.stack == 400
            && state.players.first { $0.id == "c" }?.stack == 480
            && state.handResult?.reveals.contains(where: { $0.playerID == "c" }) == false
    }

    static func uncalledBetReturnsOnFoldOut() -> Bool {
        let folded = Player(id: "b", name: "B", stack: 490, isFolded: true, avatarIndex: 1)
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                folded,
            ],
            contributions: ["a": 100, "b": 10],
            holes: [:]
        )
        var engine = PokerEngine()
        engine.distributePots(&state, wentToShowdown: false)
        return state.players.first { $0.id == "a" }?.stack == 510
            && state.players.first { $0.id == "b" }?.stack == 490
            && state.handResult?.wentToShowdown == false
            && state.handResult?.reveals.isEmpty == true
            && state.pot == 0
    }

    static func chipsAreConservedOnShowdown() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                Player(id: "c", name: "C", stack: 400, avatarIndex: 2),
            ],
            contributions: ["a": 20, "b": 100, "c": 100],
            holes: [
                "a": [Card(rank: .ace, suit: .hearts), Card(rank: .ace, suit: .diamonds)],
                "b": [Card(rank: .two, suit: .clubs), Card(rank: .three, suit: .clubs)],
                "c": [Card(rank: .king, suit: .hearts), Card(rank: .king, suit: .diamonds)],
            ],
            board: [
                Card(rank: .seven, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .two, suit: .hearts),
                Card(rank: .four, suit: .diamonds),
            ]
        )
        return conservedAfterShowdown(&state)
    }

    static func chipsAreConservedOnFoldOut() -> Bool {
        let foldedB = Player(id: "b", name: "B", stack: 490, isFolded: true, avatarIndex: 1)
        let foldedC = Player(id: "c", name: "C", stack: 495, isFolded: true, avatarIndex: 2)
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                foldedB,
                foldedC,
            ],
            contributions: ["a": 100, "b": 10, "c": 5],
            holes: [:]
        )
        let before = chipTotal(state)
        var engine = PokerEngine()
        engine.distributePots(&state, wentToShowdown: false)
        return chipTotal(state) == before
    }

    /// A chopped pot that returns each player their contribution must not eliminate them.
    static func shouldEndGameAfterSplit() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 0, avatarIndex: 1),
            ],
            contributions: ["a": 50, "b": 50],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        return engine.shouldEndGame(state) == false
            && state.players.allSatisfy { !$0.isEliminated && $0.stack == 50 }
    }

    static func showdownKeepsRevealsEmptyUntilShown() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
            ],
            contributions: ["a": 50, "b": 50],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        let first = state.pendingRevealPlayerID
        guard state.handResult?.reveals.isEmpty == true, let first else { return false }
        guard engine.applyShowdownReveal(&state, playerID: first) else { return false }
        return state.handResult?.reveals.count == 1
            && state.handResult?.reveals.first?.playerID == first
            && state.pendingRevealPlayerID != first
    }

    static func lastAggressorShowsFirst() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                Player(id: "c", name: "C", stack: 400, avatarIndex: 2),
            ],
            contributions: ["a": 50, "b": 50, "c": 50],
            holes: boardPlayHoles(ids: ["a", "b", "c"])
        )
        state.lastAggressorID = "c"
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        return engine.showdownRevealOrder(state) == ["c", "a", "b"]
            && state.pendingRevealPlayerID == "c"
    }

    static func showdownRevealIsIdempotent() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
            ],
            contributions: ["a": 50, "b": 50],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        guard let first = state.pendingRevealPlayerID,
              engine.applyShowdownReveal(&state, playerID: first) else { return false }
        return engine.applyShowdownReveal(&state, playerID: first) == false
            && state.handResult?.reveals.count == 1
    }

    static func hostCardsOverrideGuestSpoof() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 400, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
            ],
            contributions: ["a": 50, "b": 50],
            holes: boardPlayHoles(ids: ["a", "b"])
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        guard let first = state.pendingRevealPlayerID else { return false }
        let real = state.holeCardsByPlayer[first] ?? []
        let spoof = [Card(rank: .ace, suit: .spades), Card(rank: .ace, suit: .hearts)]
        guard engine.applyShowdownReveal(&state, playerID: first, holeCards: spoof) else { return false }
        return state.handResult?.reveals.first?.holeCards == real
    }

    /// Heads-up raise must stop at the opponent's effective stack; over-betting is rejected.
    static func cannotRaiseBeyondOpponentEffectiveStack() -> Bool {
        var state = GameState()
        state.phase = .playing
        state.bettingRound = .flop
        state.players = [
            Player(id: "hero", name: "Hero", stack: 1925, isDealer: true, avatarIndex: 0),
            Player(id: "steve", name: "Steve", stack: 575, avatarIndex: 1),
        ]
        state.activePlayerID = "hero"
        state.streetBetLevel = 0
        state.lastRaiseSize = PokerEngine.bigBlind

        var engine = PokerEngine()
        let cap = engine.maxRaiseTotal(state, for: "hero")
        guard cap == 575 else { return false }

        let legal = engine.legalActions(for: state, playerID: "hero")
        let raiseTotals = legal.compactMap { action -> Int? in
            if case .raise(let amount) = action { return amount }
            return nil
        }
        guard raiseTotals.allSatisfy({ $0 <= 575 }) else { return false }
        guard engine.applyAction(&state, playerID: "hero", action: .raise(amount: 1925)) == false
        else { return false }
        return engine.applyAction(&state, playerID: "hero", action: .raise(amount: 575))
    }

    /// Facing an all-in for less than your stack, call and fold are offered; raise is not.
    static func facingAllInOffersCallOnly() -> Bool {
        var state = GameState()
        state.phase = .playing
        state.bettingRound = .flop
        state.players = [
            Player(id: "hero", name: "Hero", stack: 1000, isDealer: true, currentBet: 0, avatarIndex: 0),
            Player(id: "guest", name: "Guest", stack: 0, currentBet: 500, avatarIndex: 1),
        ]
        state.activePlayerID = "hero"
        state.streetBetLevel = 500
        state.lastRaiseSize = PokerEngine.bigBlind
        state.actedThisStreet = ["guest"]

        var engine = PokerEngine()
        let legal = engine.legalActions(for: state, playerID: "hero")
        let hasCall = legal.contains { if case .call = $0 { return true }; return false }
        let hasRaise = legal.contains { if case .raise = $0 { return true }; return false }
        let hasFold = legal.contains { if case .fold = $0 { return true }; return false }
        return hasCall && hasFold && !hasRaise
            && engine.maxRaiseTotal(state, for: "hero") == 500
    }

    /// Exact reported hand under the effective-stack cap: one pot, Steve alone wins.
    static func headsUpAllInNeverCreatesSidePot() -> Bool {
        var state = table(
            players: [
                Player(id: "hero", name: "Hero", stack: 1350, isDealer: true, avatarIndex: 0),
                Player(id: "steve", name: "Steve", stack: 0, avatarIndex: 1),
            ],
            contributions: ["hero": 575, "steve": 575],
            holes: [
                "hero": [Card(rank: .queen, suit: .clubs), Card(rank: .king, suit: .clubs)],
                "steve": [Card(rank: .three, suit: .spades), Card(rank: .ace, suit: .spades)],
            ],
            board: [
                Card(rank: .ace, suit: .clubs),
                Card(rank: .eight, suit: .hearts),
                Card(rank: .six, suit: .diamonds),
                Card(rank: .ace, suit: .hearts),
                Card(rank: .queen, suit: .diamonds),
            ]
        )
        state.handStats = [
            "hero": PlayerHandStats(handsWon: 0, handsPlayed: 1, biggestPot: 0),
            "steve": PlayerHandStats(handsWon: 0, handsPlayed: 1, biggestPot: 0),
        ]
        var engine = PokerEngine()
        let pots = engine.buildPots(state)
        guard pots.count == 1, pots[0].amount == 1150 else { return false }

        engine.resolveShowdown(&state)
        // Winner must not be visible on stacks until payouts are applied after the reveal.
        guard state.players.first { $0.id == "steve" }?.stack == 0,
              state.players.first { $0.id == "hero" }?.stack == 1350,
              state.pot == 1150,
              state.handResult?.payoutsApplied == false,
              state.handStats["hero"]?.handsWon == 0
        else { return false }

        engine.applyHandResultPayouts(&state)
        return Set(state.handResult?.winnerIDs ?? []) == ["steve"]
            && state.players.first { $0.id == "steve" }?.stack == 1150
            && state.players.first { $0.id == "hero" }?.stack == 1350
            && state.handStats["hero"]?.handsWon == 0
            && state.handStats["steve"]?.handsWon == 1
            && state.handResult?.pots.contains(where: { $0.winnerIDs.count > 1 }) != true
    }

    /// Multiway: covering opponent folds after a short stack calls all-in — excess returns
    /// before the next street is dealt.
    static func uncalledBetReturnsWhenStreetCloses() -> Bool {
        let folded = Player(id: "ann", name: "Ann", stack: 1000, isFolded: true, avatarIndex: 2)
        var state = GameState()
        state.phase = .playing
        state.bettingRound = .turn
        state.players = [
            Player(id: "hero", name: "Hero", stack: 400, isDealer: true, currentBet: 600, avatarIndex: 0),
            Player(id: "bob", name: "Bob", stack: 0, currentBet: 200, avatarIndex: 1),
            folded,
        ]
        state.contributions = ["hero": 600, "bob": 200, "ann": 0]
        state.pot = 800
        state.streetBetLevel = 600
        state.lastRaiseSize = PokerEngine.bigBlind
        state.actedThisStreet = ["hero", "bob", "ann"]
        state.activePlayerID = nil
        state.board = [
            Card(rank: .ace, suit: .spades),
            Card(rank: .king, suit: .hearts),
            Card(rank: .queen, suit: .clubs),
            Card(rank: .jack, suit: .diamonds),
            nil,
        ]
        state.remainingDeck = [
            Card(rank: .two, suit: .clubs),
            Card(rank: .three, suit: .clubs),
            Card(rank: .four, suit: .clubs),
            Card(rank: .five, suit: .clubs),
            Card(rank: .six, suit: .clubs),
        ]
        state.holeCardsByPlayer = boardPlayHoles(ids: ["hero", "bob", "ann"])

        var engine = PokerEngine()
        guard engine.resolvePendingBettingRound(&state) else { return false }
        let hero = state.players.first { $0.id == "hero" }
        return state.bettingRound == .river
            && state.pot == 400
            && hero?.stack == 800
            && (state.contributions?["hero"] ?? 0) == 200
            && (state.contributions?["bob"] ?? 0) == 200
    }

    /// Uncapped contributions still return the excess before pots are awarded.
    static func uncalledBetIsReturnedBeforePots() -> Bool {
        var state = table(
            players: [
                Player(id: "hero", name: "Hero", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "steve", name: "Steve", stack: 0, avatarIndex: 1),
            ],
            contributions: ["hero": 1925, "steve": 575],
            holes: [
                "hero": [Card(rank: .queen, suit: .clubs), Card(rank: .king, suit: .clubs)],
                "steve": [Card(rank: .three, suit: .spades), Card(rank: .ace, suit: .spades)],
            ],
            board: [
                Card(rank: .ace, suit: .clubs),
                Card(rank: .eight, suit: .hearts),
                Card(rank: .six, suit: .diamonds),
                Card(rank: .ace, suit: .hearts),
                Card(rank: .queen, suit: .diamonds),
            ]
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.applyHandResultPayouts(&state)
        return Set(state.handResult?.winnerIDs ?? []) == ["steve"]
            && state.players.first { $0.id == "steve" }?.stack == 1150
            && state.players.first { $0.id == "hero" }?.stack == 1350
            && state.handResult?.totalAwarded == 1150
            && state.handResult?.pots.count == 1
    }

    /// Two different pot winners is not a chopped pot — no single layer has multiple winners.
    static func splitPotLabelOnlyForActualChop() -> Bool {
        var state = table(
            players: [
                Player(id: "a", name: "A", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "b", name: "B", stack: 400, avatarIndex: 1),
                Player(id: "c", name: "C", stack: 400, avatarIndex: 2),
            ],
            contributions: ["a": 20, "b": 100, "c": 100],
            holes: [
                "a": [Card(rank: .ace, suit: .hearts), Card(rank: .ace, suit: .diamonds)],
                "b": [Card(rank: .two, suit: .clubs), Card(rank: .three, suit: .clubs)],
                "c": [Card(rank: .king, suit: .hearts), Card(rank: .king, suit: .diamonds)],
            ],
            board: [
                Card(rank: .seven, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .two, suit: .hearts),
                Card(rank: .four, suit: .diamonds),
            ]
        )
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        let winners = state.handResult?.winnerIDs ?? []
        let hasChoppedLayer = state.handResult?.pots.contains { $0.winnerIDs.count > 1 } ?? true
        // A and C each take a pot — two winners overall, but no chopped layer.
        return Set(winners) == ["a", "c"] && hasChoppedLayer == false
    }

    /// A player who loses an all-in showdown must still be in the reveal queue (and not yet
    /// eliminated) so they can show their cards before the hand summary.
    static func bustedShowdownContenderStaysInReveal() -> Bool {
        var state = table(
            players: [
                Player(id: "hero", name: "Hero", stack: 0, isDealer: true, avatarIndex: 0),
                Player(id: "steve", name: "Steve", stack: 0, avatarIndex: 1),
            ],
            contributions: ["hero": 500, "steve": 500],
            holes: [
                "hero": [Card(rank: .queen, suit: .clubs), Card(rank: .king, suit: .clubs)],
                "steve": [Card(rank: .three, suit: .spades), Card(rank: .ace, suit: .spades)],
            ],
            board: [
                Card(rank: .ace, suit: .clubs),
                Card(rank: .eight, suit: .hearts),
                Card(rank: .six, suit: .diamonds),
                Card(rank: .ace, suit: .hearts),
                Card(rank: .queen, suit: .diamonds),
            ]
        )
        state.heroID = "hero"
        state.heroHoleCards = state.holeCardsByPlayer["hero"] ?? []
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        engine.updateHeroDisplay(&state)

        let order = engine.showdownRevealOrder(state)
        let hero = state.players.first { $0.id == "hero" }
        let stillInReveal = Set(order) == ["hero", "steve"]
        let notEliminatedYet = hero?.isEliminated == false
            && state.players.first { $0.id == "steve" }?.isEliminated == false
        let cardsKept = state.heroHoleCards.count == 2
        let stacksHidden = state.players.allSatisfy { $0.stack == 0 }
            && state.pot == 1000
            && state.handResult?.payoutsApplied == false

        var shownHero = false
        while let pending = state.pendingRevealPlayerID {
            guard engine.applyShowdownReveal(&state, playerID: pending) else { return false }
            if pending == "hero" { shownHero = true }
        }

        // Stacks must still hide the winner after every hand is face up.
        guard stacksHidden,
              state.players.allSatisfy({ $0.stack == 0 }),
              state.handResult?.payoutsApplied == false
        else { return false }

        engine.applyHandResultPayouts(&state)
        engine.eliminateBrokePlayers(&state)
        let eliminatedAfter = state.players.first { $0.id == "hero" }?.isEliminated == true
        let stevePaid = state.players.first { $0.id == "steve" }?.stack == 1000

        return stillInReveal
            && notEliminatedYet
            && cardsKept
            && shownHero
            && stevePaid
            && eliminatedAfter
            && Set(state.handResult?.winnerIDs ?? []) == ["steve"]
    }

    // MARK: - Fixtures

    /// Both (or all) players miss the board and play the same five community cards.
    private static func boardPlayHoles(ids: [String]) -> [String: [Card]] {
        let leftovers = [
            [Card(rank: .two, suit: .hearts), Card(rank: .three, suit: .hearts)],
            [Card(rank: .two, suit: .diamonds), Card(rank: .three, suit: .diamonds)],
            [Card(rank: .two, suit: .clubs), Card(rank: .three, suit: .clubs)],
        ]
        var holes: [String: [Card]] = [:]
        for (index, id) in ids.enumerated() {
            holes[id] = leftovers[index % leftovers.count]
        }
        return holes
    }

    private static func broadwayBoard() -> [Card] {
        [
            Card(rank: .ace, suit: .spades),
            Card(rank: .king, suit: .hearts),
            Card(rank: .queen, suit: .clubs),
            Card(rank: .jack, suit: .diamonds),
            Card(rank: .nine, suit: .spades),
        ]
    }

    private static func table(
        players: [Player],
        contributions: [String: Int],
        holes: [String: [Card]],
        board: [Card]? = nil
    ) -> GameState {
        var state = GameState()
        state.phase = .playing
        state.bettingRound = .river
        state.players = players
        state.contributions = contributions
        state.pot = contributions.values.reduce(0, +)
        state.holeCardsByPlayer = holes
        let cards = board ?? broadwayBoard()
        state.board = cards.map { Optional($0) }
        return state
    }

    private static func chipTotal(_ state: GameState) -> Int {
        state.players.map(\.stack).reduce(0, +) + state.pot
    }

    private static func conservedAfterShowdown(_ state: inout GameState) -> Bool {
        let before = chipTotal(state)
        var engine = PokerEngine()
        engine.resolveShowdown(&state)
        // Contested chips remain in the pot until payouts are applied after the reveal.
        guard chipTotal(state) == before, state.pot > 0,
              state.handResult?.payoutsApplied == false else { return false }
        engine.applyHandResultPayouts(&state)
        return chipTotal(state) == before && state.pot == 0
            && state.handResult?.payoutsApplied == true
    }
}
#endif
