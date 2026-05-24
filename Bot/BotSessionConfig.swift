import Foundation

enum BotDifficulty: String, Codable, Equatable {
    case easy, medium, hard
}

struct BotSessionConfig: Equatable {
    var botCount: Int
    var difficulty: BotDifficulty

    static let `default` = BotSessionConfig(botCount: 4, difficulty: .easy)
}

func makeStrategy(for config: BotSessionConfig) -> BotStrategy {
    switch config.difficulty {
    case .easy, .medium, .hard:
        return RandomLegalBotStrategy()
    }
}
