import Foundation

struct RandomLegalBotStrategy: BotStrategy {
    func chooseAction(
        state: GameState,
        playerID: String,
        legalActions: [BettingAction]
    ) -> BettingAction {
        legalActions.randomElement() ?? .fold
    }
}
