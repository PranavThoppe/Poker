#if DEBUG
import Foundation

/// DEBUG sanity checks for betting rules and end-game stats. Call from LLDB or a test hook.
enum PokerEngineVerification {
    @MainActor
    static func runAll() -> Bool {
        preflopFirstActorIsUTG()
            && blindsNotInActedInitially()
            && bbOptionOnLimp()
            && bettingUIIsLocalToHero()
            && guestDefersHostDealsFlop()
            && guestKeepsFetchedHoleCards()
            && chipLeaderOnManualEnd()
    }

    /// UTG (seat after BB) opens preflop, not BB.
    static func preflopFirstActorIsUTG() -> Bool {
        var state = fivePlayerState(dealerIndex: 0)
        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard let sbIdx = seatAfter(state, from: 0),
              let bbIdx = seatAfter(state, from: sbIdx),
              let utgIdx = seatAfter(state, from: bbIdx) else { return false }
        let bbID = state.players[bbIdx].id
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

        guard let sbIdx = seatAfter(state, from: 0),
              let bbIdx = seatAfter(state, from: sbIdx) else { return false }
        let bbID = state.players[bbIdx].id

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
