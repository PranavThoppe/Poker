import Foundation

struct BotPreset: Equatable {
    let id: String
    let name: String
    let avatarIndex: Int
}

enum BotCatalog {
    private static let presets: [BotPreset] = [
        BotPreset(id: "bot-jane", name: "Jane", avatarIndex: 0),
        BotPreset(id: "bot-eli", name: "Eli", avatarIndex: 1),
        BotPreset(id: "bot-gina", name: "Gina", avatarIndex: 2),
        BotPreset(id: "bot-steve", name: "Steve", avatarIndex: 3),
        BotPreset(id: "bot-rose", name: "Rose", avatarIndex: 4),
    ]

    static func makeBots(count: Int) -> [Player] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let preset = presets[i % presets.count]
            return Player(
                id: preset.id,
                name: preset.name,
                stack: PokerEngine.startingStack,
                isReady: true,
                avatarIndex: preset.avatarIndex,
                isBot: true
            )
        }
    }
}
