#if DEBUG
import Foundation

/// DEBUG sanity checks for betting rules and end-game stats. Call from LLDB or a test hook.
enum PokerEngineVerification {
    @MainActor
    static func runAll() -> Bool {
        preflopFirstActorIsUTG()
            && blindsNotInActedInitially()
            && bbOptionOnLimp()
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
