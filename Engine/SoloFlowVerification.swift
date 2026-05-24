#if DEBUG
import Foundation

/// Lightweight sanity check for the solo path; run under a unit-test target or REPL.
enum SoloFlowVerification {
    static func run() -> Bool {
        var state = GameState()
        state.players = [Player(id: "solo", name: "Player", stack: 500, isReady: true)]
        state.heroID = "solo"

        var engine = PokerEngine()
        engine.startGame(&state)
        engine.startHand(&state)

        guard state.phase == .waiting || state.heroHoleCards.count == 2 else { return false }
        guard state.activePlayerID == "solo" else { return false }

        let streets: [BettingRound] = [.preFlop, .flop, .turn, .river]
        for expected in streets {
            guard state.bettingRound == expected else { return false }
            guard engine.applyAction(&state, playerID: "solo", action: .check) else { return false }
        }

        guard state.activePlayerID == nil else { return false }
        guard engine.shouldEndGame(state) else { return false }
        return true
    }
}
#endif
