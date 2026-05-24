import Foundation

protocol BotStrategy {
    func chooseAction(
        state: GameState,
        playerID: String,
        legalActions: [BettingAction]
    ) -> BettingAction
}
