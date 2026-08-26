#if DEBUG
import Foundation

/// DEBUG sanity checks for betting rules and end-game stats. Call from LLDB or a test hook.
enum PokerEngineVerification {
    @MainActor
    static func runAll() -> Bool {
        preflopFirstActorIsUTG()
            && blindsNotInActedInitially()
            && bbOptionOnLimp()
            && headsUpButtonPostsSmallBlind()
            && shortStackCanCallAllIn()
            && allInPlayerIsNotAskedToAct()
            && streetsDealtWithoutStoredDeck()
            && stalledHandIsRecoverable()
            && bettingUIIsLocalToHero()
            && guestDefersHostDealsFlop()
            && guestKeepsFetchedHoleCards()
            && chipLeaderOnManualEnd()
            && betweenHandReadyGate()
            && riverOpensBettingAfterTurn()
            && guestClosesTurnHostOpensRiver()
            && riverRequiresABettingRound()
            && postflopOpenerIsLeftOfButton()
            && foldClosingTurnOpensLiveActor()
            && allInCallOnTurnRunsOutTheBoard()
            && PokerEnginePotVerification.runAll()
    }

    /// UTG (seat after BB) opens preflop, not BB.
    static func preflopFirstActorIsUTG() -> Bool {
        var state = fivePlayerState(dealerIndex: 0)
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let seats = blindSeats(state),
              let utgIdx = seatAfter(state, from: seats.bigBlind) else { return false }
        let bbID = state.players[seats.bigBlind].id
        let utgID = state.players[utgIdx].id
        return state.activePlayerID == utgID && state.activePlayerID != bbID
    }

    static func blindsNotInActedInitially() -> Bool {
        var state = fivePlayerState(dealerIndex: 0)
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)
        return state.actedThisStreet.isEmpty && state.pot == 15
    }

    /// After a limp to the big blind, BB still has action (e.g. can raise).
    static func bbOptionOnLimp() -> Bool {
        var state = fivePlayerState(dealerIndex: 0)
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let seats = blindSeats(state) else { return false }
        let bbID = state.players[seats.bigBlind].id

        var safety = 0
        while state.bettingRound == .preFlop, state.activePlayerID != bbID, safety < 20 {
            safety += 1
            guard let active = state.activePlayerID else { return false }
            let legal = engine.legalActions(for: state, playerID: active)
            let action: BettingAction
            if let callAction = legal.first(where: { if case .call = $0 { return true }; return false }) {
                action = callAction
            } else if legal.contains(where: { if case .check = $0 { return true }; return false }) {
                action = .check
            } else {
                return false
            }
            guard engine.applyAction(&state, playerID: active, action: action) else { return false }
        }

        guard state.activePlayerID == bbID else { return false }
        let bbLegal = engine.legalActions(for: state, playerID: bbID)
        let canRaise = bbLegal.contains { action in
            if case .raise = action { return true }
            return false
        }
        let canCheck = bbLegal.contains(where: { if case .check = $0 { return true }; return false })
        return canRaise || canCheck
    }

    /// Heads-up the button posts the small blind and opens the preflop action.
    static func headsUpButtonPostsSmallBlind() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let button = state.players.first(where: { $0.isDealer }),
              let other = state.players.first(where: { !$0.isDealer }) else { return false }
        return button.currentBet == PokerEngine.smallBlind
            && other.currentBet == PokerEngine.bigBlind
            && state.activePlayerID == button.id
    }

    /// A stack too short to cover the bet can still call all-in instead of only folding.
    static func shortStackCanCallAllIn() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let shortID = state.activePlayerID,
              let shortIdx = state.players.firstIndex(where: { $0.id == shortID }),
              let otherID = state.players.first(where: { $0.id != shortID })?.id else { return false }

        // Leave the opener too short to cover the raise it is about to face.
        state.players[shortIdx].stack = 30

        let toCall = state.streetBetLevel - state.players[shortIdx].currentBet
        guard engine.applyAction(&state, playerID: shortID, action: .call(amount: toCall)),
              state.activePlayerID == otherID,
              engine.applyAction(&state, playerID: otherID, action: .raise(amount: 300)),
              state.activePlayerID == shortID else { return false }

        let legal = engine.legalActions(for: state, playerID: shortID)
        guard legal.contains(where: { if case .call = $0 { return true }; return false }) else { return false }

        guard engine.applyAction(&state, playerID: shortID, action: .call(amount: state.streetBetLevel)) else { return false }
        return state.players.first(where: { $0.id == shortID })?.stack == 0
    }

    /// An opponent's raise must not put an all-in player back on the clock.
    static func allInPlayerIsNotAskedToAct() -> Bool {
        var state = GameState()
        state.phase = .playing
        state.bettingRound = .flop
        state.players = [
            Player(id: "raiser", name: "Raiser", stack: 400, currentBet: 30, avatarIndex: 0),
            Player(id: "allin",  name: "All-in", stack: 0,   currentBet: 30, avatarIndex: 1),
            Player(id: "caller", name: "Caller", stack: 400, currentBet: 30, avatarIndex: 2),
        ]
        state.players[0].isDealer = true
        state.streetBetLevel = 30
        state.lastRaiseSize = PokerEngine.bigBlind
        state.actedThisStreet = ["raiser", "allin", "caller"]
        state.activePlayerID = "raiser"

        var engine = PokerEngine()
        guard engine.applyAction(&state, playerID: "raiser", action: .raise(amount: 80)) else { return false }
        return state.activePlayerID == "caller" && state.actedThisStreet.contains("allin")
    }

    /// A host that lost `remainingDeck` must still deal a real board, not silently blank streets.
    static func streetsDealtWithoutStoredDeck() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)
        state.remainingDeck = []

        var safety = 0
        while state.bettingRound != .flop, safety < 12, let active = state.activePlayerID {
            safety += 1
            let toCall = state.streetBetLevel - (state.players.first { $0.id == active }?.currentBet ?? 0)
            let action: BettingAction = toCall > 0 ? .call(amount: toCall) : .check
            guard engine.applyAction(&state, playerID: active, action: action) else { return false }
        }
        let board = state.board.compactMap { $0 }
        let hole = state.holeCardsByPlayer.values.flatMap { $0 }
        return board.count == 3 && !board.contains(where: { hole.contains($0) })
    }

    /// A dropped sync write leaves nobody on the clock; recovery must hand the action back.
    static func stalledHandIsRecoverable() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        // Simulate the lost publish: the round is unfinished but the pointer is gone.
        state.activePlayerID = nil
        guard engine.recoverStalledHand(&state) else { return false }
        guard let restored = state.activePlayerID else { return false }
        return engine.legalActions(for: state, playerID: restored).isEmpty == false
    }

    static func bettingUIIsLocalToHero() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let firstID = state.activePlayerID,
              let bigBlindID = state.players.first(where: { $0.currentBet == PokerEngine.bigBlind })?.id
        else { return false }

        state.heroID = firstID
        engine.syncBettingUI(&state)
        guard state.callAmount == PokerEngine.smallBlind else { return false }

        state.heroID = bigBlindID
        engine.syncBettingUI(&state)
        return state.callAmount == 0
    }

    static func guestDefersHostDealsFlop() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        let hostDeck = state.remainingDeck
        guard let guestID = state.activePlayerID,
              let hostID = state.players.first(where: { $0.id != guestID })?.id,
              engine.applyAction(
                &state,
                playerID: guestID,
                action: .call(amount: PokerEngine.smallBlind),
                canResolveBettingRound: false
              ),
              engine.applyAction(
                &state,
                playerID: hostID,
                action: .raise(amount: 20)
              )
        else { return false }

        state.remainingDeck = []
        guard engine.applyAction(
            &state,
            playerID: guestID,
            action: .call(amount: 10),
            canResolveBettingRound: false
        ) else { return false }

        guard state.activePlayerID == nil,
              state.bettingRound == .preFlop,
              state.board.compactMap({ $0 }).isEmpty else { return false }

        state.remainingDeck = hostDeck
        guard engine.resolvePendingBettingRound(&state) else { return false }
        return state.bettingRound == .flop
            && state.board.compactMap({ $0 }).count == 3
            && state.activePlayerID != nil
    }

    /// Guests store hole cards only in `heroHoleCards`. Display refresh must not wipe them.
    static func guestKeepsFetchedHoleCards() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        let guestID = "guest"
        guard let dealt = state.holeCardsByPlayer[guestID], dealt.count == 2 else { return false }

        state.heroID = guestID
        state.heroHoleCards = dealt
        state.holeCardsByPlayer = [:]

        engine.updateHeroDisplay(&state)
        engine.syncBettingUI(&state)

        return state.heroHoleCards == dealt && state.heroHandRank != nil
    }

    @MainActor
    static func chipLeaderOnManualEnd() -> Bool {
        let store = GameStore()
        store.state.players = [
            Player(id: "hero", name: "Player", stack: 520, avatarIndex: 0),
            Player(id: "bot-jane", name: "Jane", stack: 480, avatarIndex: 1, isBot: true),
            Player(id: "bot-eli", name: "Eli", stack: 500, avatarIndex: 2, isBot: true),
        ]
        store.state.phase = .playing
        store.endGame()

        let stats = store.state.endStats
        guard let winner = stats.first(where: { $0.isWinner }) else { return false }
        return winner.id == "hero" && winner.finalStack == 520
            && stats.allSatisfy { $0.finalStack > 0 }
    }

    @MainActor
    static func betweenHandReadyGate() -> Bool {
        var state = twoPlayerState()
        state.gameMode = .classicPoker
        state.players[0].isReady = true
        state.players[1].isReady = true

        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)
        state.phase = .playing
        guard let activeID = state.activePlayerID else { return false }
        state.heroID = activeID

        let store = GameStore(state: state)
        store.isHost = true
        store.fold()

        guard store.state.phase == .handSummary,
              store.state.players.allSatisfy({ !$0.isReady }),
              !store.canStartNextHand else { return false }

        store.toggleReady()
        guard !store.canStartNextHand else { return false }

        guard let otherIndex = store.state.players.firstIndex(where: { $0.id != activeID }) else {
            return false
        }
        store.state.players[otherIndex].isReady = true
        guard store.canStartNextHand else { return false }

        store.continueAfterHandSummary()
        return store.state.phase == .playing
    }

    /// After turn checks, the river card is dealt and a player must still be able to act —
    /// the hand must not jump straight to showdown.
    static func riverOpensBettingAfterTurn() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        var safety = 0
        while state.bettingRound != .river, safety < 40 {
            safety += 1
            guard checkOrCall(&engine, &state) else { return false }
        }

        return isOpenRiver(state)
    }

    /// Classic: the guest closes the turn without the deck; the host must deal the river
    /// and leave a player to bet, not run showdown in that same step.
    static func guestClosesTurnHostOpensRiver() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        var safety = 0
        while state.bettingRound != .turn, safety < 40 {
            safety += 1
            guard checkOrCall(&engine, &state) else { return false }
        }

        guard state.bettingRound == .turn,
              checkOrCall(&engine, &state),
              state.bettingRound == .turn,
              let lastID = state.activePlayerID
        else { return false }

        let hostDeck = state.remainingDeck
        state.remainingDeck = []
        let toCall = state.streetBetLevel
            - (state.players.first { $0.id == lastID }?.currentBet ?? 0)
        let action: BettingAction = toCall > 0 ? .call(amount: toCall) : .check
        guard engine.applyAction(
            &state,
            playerID: lastID,
            action: action,
            canResolveBettingRound: false
        ) else { return false }

        guard state.bettingRound == .turn,
              state.activePlayerID == nil,
              state.board.compactMap({ $0 }).count == 4,
              state.handResult == nil
        else { return false }

        state.remainingDeck = hostDeck
        guard engine.resolvePendingBettingRound(&state) else { return false }
        return isOpenRiver(state)
    }

    /// Both players must still get a river decision. Showdown only after that street closes.
    static func riverRequiresABettingRound() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        var safety = 0
        while state.bettingRound != .river, safety < 40 {
            safety += 1
            guard checkOrCall(&engine, &state) else { return false }
        }
        guard isOpenRiver(state) else { return false }

        guard checkOrCall(&engine, &state),
              state.handResult == nil,
              state.bettingRound == .river
        else { return false }
        guard checkOrCall(&engine, &state) else { return false }
        return state.handResult?.wentToShowdown == true
    }

    /// Every post-flop street opens on the first live seat left of the button — heads-up
    /// that is the big blind, on every street. A street must not inherit the pointer from
    /// the seat that closed the previous one.
    static func postflopOpenerIsLeftOfButton() -> Bool {
        var state = twoPlayerState()
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let bigBlindID = state.players.first(where: { !$0.isDealer })?.id else { return false }

        for street in [BettingRound.flop, .turn, .river] {
            var safety = 0
            while state.bettingRound != street, safety < 12 {
                safety += 1
                guard checkOrCall(&engine, &state) else { return false }
            }
            guard state.bettingRound == street,
                  state.activePlayerID == bigBlindID else { return false }
        }
        return true
    }

    /// A fold that closes the turn must not leave the folded player on the clock for the
    /// river: they have no legal action, so the table would sit there with nobody able to
    /// bet and no pointer for recovery to notice.
    static func foldClosingTurnOpensLiveActor() -> Bool {
        var state = turnState(
            players: [
                Player(id: "button", name: "Button", stack: 360, currentBet: 40, avatarIndex: 0),
                Player(id: "sb",     name: "SB",     stack: 360, currentBet: 40, avatarIndex: 1),
                Player(id: "bb",     name: "BB",     stack: 400, currentBet: 0,  avatarIndex: 2),
            ],
            streetBetLevel: 40,
            actedThisStreet: ["button", "sb"],
            activePlayerID: "bb",
            contributions: ["button": 40, "sb": 40]
        )

        var engine = PokerEngine()
        guard engine.applyAction(&state, playerID: "bb", action: .fold) else { return false }

        guard state.bettingRound == .river,
              state.board.compactMap({ $0 }).count == 5,
              state.handResult == nil,
              state.activePlayerID == "sb" else { return false }
        return !engine.legalActions(for: state, playerID: "sb").isEmpty
    }

    /// An all-in call that closes the turn leaves nobody with chips, so the board runs out
    /// and the hand reaches showdown instead of stalling on a player who cannot act.
    static func allInCallOnTurnRunsOutTheBoard() -> Bool {
        var state = turnState(
            players: [
                Player(id: "shover", name: "Shover", stack: 0,   currentBet: 200, avatarIndex: 0),
                Player(id: "caller", name: "Caller", stack: 120, currentBet: 0,   avatarIndex: 1),
            ],
            streetBetLevel: 200,
            actedThisStreet: ["shover"],
            activePlayerID: "caller",
            contributions: ["shover": 200]
        )
        state.holeCardsByPlayer = [
            "shover": [Card(rank: .queen, suit: .hearts), Card(rank: .queen, suit: .spades)],
            "caller": [Card(rank: .jack,  suit: .diamonds), Card(rank: .jack, suit: .clubs)],
        ]

        var engine = PokerEngine()
        guard engine.applyAction(&state, playerID: "caller", action: .call(amount: 200)) else { return false }

        return state.bettingRound == .river
            && state.board.compactMap({ $0 }).count == 5
            && state.handResult?.wentToShowdown == true
    }

    private static func checkOrCall(_ engine: inout PokerEngine, _ state: inout GameState) -> Bool {
        guard let active = state.activePlayerID else { return false }
        let toCall = state.streetBetLevel
            - (state.players.first { $0.id == active }?.currentBet ?? 0)
        let action: BettingAction = toCall > 0 ? .call(amount: toCall) : .check
        return engine.applyAction(&state, playerID: active, action: action)
    }

    private static func isOpenRiver(_ state: GameState) -> Bool {
        state.bettingRound == .river
            && state.board.compactMap({ $0 }).count == 5
            && state.activePlayerID != nil
            && state.handResult == nil
            && state.phase != .showdown
    }

    // MARK: - Fixtures

    private static func fivePlayerState(dealerIndex: Int) -> GameState {
        var state = GameState()
        state.phase = .playing
        state.players = [
            Player(id: "p0", name: "P0", stack: 500, avatarIndex: 0),
            Player(id: "p1", name: "P1", stack: 500, avatarIndex: 1),
            Player(id: "p2", name: "P2", stack: 500, avatarIndex: 2),
            Player(id: "p3", name: "P3", stack: 500, avatarIndex: 3),
            Player(id: "p4", name: "P4", stack: 500, avatarIndex: 4),
        ]
        for i in state.players.indices {
            state.players[i].isDealer = i == dealerIndex
        }
        return state
    }

    /// A hand already on the turn, seat 0 on the button. `remainingDeck` is left empty so
    /// the engine rebuilds it from the cards not already in play.
    private static func turnState(
        players: [Player],
        streetBetLevel: Int,
        actedThisStreet: [String],
        activePlayerID: String,
        contributions: [String: Int]
    ) -> GameState {
        var state = GameState()
        state.phase = .playing
        state.players = players
        state.players[0].isDealer = true
        state.bettingRound = .turn
        state.board = [
            Card(rank: .ace,   suit: .hearts),
            Card(rank: .king,  suit: .diamonds),
            Card(rank: .seven, suit: .clubs),
            Card(rank: .two,   suit: .spades),
            nil,
        ]
        state.pot = contributions.values.reduce(0, +)
        state.contributions = contributions
        state.streetBetLevel = streetBetLevel
        state.lastRaiseSize = max(streetBetLevel, PokerEngine.bigBlind)
        state.actedThisStreet = actedThisStreet
        state.activePlayerID = activePlayerID
        state.remainingDeck = []
        return state
    }

    private static func twoPlayerState() -> GameState {
        var state = GameState()
        state.phase = .playing
        state.players = [
            Player(id: "host", name: "Host", stack: 500, avatarIndex: 0),
            Player(id: "guest", name: "Guest", stack: 500, avatarIndex: 1),
        ]
        state.players[0].isDealer = true
        return state
    }

    /// Blind seats read from the *current* button. `startHand` rotates the dealer, so a
    /// fixture's seeded dealer index is stale by the time the hand is live.
    private static func blindSeats(_ state: GameState) -> (smallBlind: Int, bigBlind: Int)? {
        guard let dealer = state.players.firstIndex(where: { $0.isDealer }) else { return nil }
        if state.players.filter({ !$0.isEliminated }).count == 2 {
            guard let other = seatAfter(state, from: dealer) else { return nil }
            return (smallBlind: dealer, bigBlind: other)
        }
        guard let sb = seatAfter(state, from: dealer),
              let bb = seatAfter(state, from: sb) else { return nil }
        return (smallBlind: sb, bigBlind: bb)
    }

    private static func seatAfter(_ state: GameState, from index: Int) -> Int? {
        let count = state.players.count
        guard count > 0 else { return nil }
        var i = (index + 1) % count
        for _ in 0..<count {
            if !state.players[i].isEliminated && !state.players[i].isFolded {
                return i
            }
            i = (i + 1) % count
        }
        return nil
    }
}
#endif
