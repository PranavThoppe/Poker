#if DEBUG
import Foundation

/// Console logging for game lifecycle debugging. Filter Xcode console with `[Game]`.
enum GameLog {
    static func log(_ message: String) {
        print("[Game] \(message)")
    }

    static func phaseChange(from: GamePhase, to: GamePhase, mode: GameMode) {
        log("phase \(from) → \(to) (mode=\(mode.rawValue))")
    }

    static func snapshot(_ state: GameState, event: String) {
        let humanCount = state.players.filter { !$0.isBot }.count
        let botCount = state.players.filter { $0.isBot }.count
        let active = state.activePlayerID ?? "nil"
        let street = state.bettingRound.displayName
        let dealer = state.players.first(where: { $0.isDealer })?.id ?? "nil"
        var line =
            "\(event) | players=\(state.players.count) (human=\(humanCount) bot=\(botCount)) "
            + "pot=\(state.pot) street=\(street) active=\(active) phase=\(state.phase) "
            + "dealer=\(dealer)"

        if event == "hand complete" || event == "endGame" {
            if let winnerID = state.lastHandWinnerID, state.lastPotAwarded > 0 {
                line += " lastPot=\(state.lastPotAwarded) winner=\(winnerID)"
            }
            line += " " + stacksSummary(state)
        }

        log(line)
    }

    static func potAwarded(amount: Int, winnerID: String) {
        log("pot awarded \(amount) → \(winnerID)")
    }

    static func heroAction(_ action: BettingAction, state: GameState) {
        guard let heroID = state.heroID else { return }
        let name = state.players.first(where: { $0.id == heroID })?.name ?? heroID
        log("hero \(name) (\(heroID)) → \(action.logLabel)")
        snapshot(state, event: "after hero action")
    }

    static func playerAction(playerID: String, action: BettingAction, state: GameState) {
        let name = state.players.first(where: { $0.id == playerID })?.name ?? playerID
        let kind = state.players.first(where: { $0.id == playerID })?.isBot == true ? "bot" : "player"
        log("\(kind) \(name) (\(playerID)) → \(action.logLabel)")
    }

    private static func stacksSummary(_ state: GameState) -> String {
        let parts = state.players.map { p in
            let key = p.isBot ? p.id.replacingOccurrences(of: "bot-", with: "") : "hero"
            return "\(key):\(p.stack)"
        }
        return "stacks=" + parts.joined(separator: ",")
    }
}

private extension BettingAction {
    var logLabel: String {
        switch self {
        case .fold: return "fold"
        case .check: return "check"
        case .call(let amount): return "call(\(amount))"
        case .raise(let amount): return "raise(\(amount))"
        }
    }
}
#endif
