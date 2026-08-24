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
        return state.players.first { $0.id == "a" }?.stack == 460
            && state.players.first { $0.id == "b" }?.stack == 400
            && state.players.first { $0.id == "c" }?.stack == 480
            && state.handResult?.reveals.contains(where: { $0.playerID == "c" }) == false
    }

    static func uncalledBetReturnsOnFoldOut() -> Bool {
        var folded = Player(id: "b", name: "B", stack: 490, isFolded: true, avatarIndex: 1)
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
        var foldedB = Player(id: "b", name: "B", stack: 490, isFolded: true, avatarIndex: 1)
        var foldedC = Player(id: "c", name: "C", stack: 495, isFolded: true, avatarIndex: 2)
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
        return chipTotal(state) == before && state.pot == 0
    }
}
#endif
