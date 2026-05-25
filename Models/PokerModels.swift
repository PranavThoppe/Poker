import Foundation

// MARK: - Card

enum Suit: String, CaseIterable, Codable, Identifiable {
    case hearts = "♥"
    case diamonds = "♦"
    case clubs = "♣"
    case spades = "♠"

    var id: String { rawValue }
    var isRed: Bool { self == .hearts || self == .diamonds }
}

enum Rank: String, CaseIterable, Codable, Identifiable {
    case two = "2", three = "3", four = "4", five = "5", six = "6"
    case seven = "7", eight = "8", nine = "9", ten = "10"
    case jack = "J", queen = "Q", king = "K", ace = "A"

    var id: String { rawValue }
}

struct Card: Identifiable, Codable, Equatable {
    let rank: Rank
    let suit: Suit
    var id: String { "\(rank.rawValue)\(suit.rawValue)" }
}

// MARK: - Player

struct Player: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var stack: Int
    var isReady: Bool = false
    var isDealer: Bool = false
    var isFolded: Bool = false
    var isEliminated: Bool = false
    var currentBet: Int = 0
    var avatarIndex: Int = 0
    var isBot: Bool = false
}

// MARK: - Game mode

enum GameMode: String, Codable, Equatable {
    case classicPoker    // iMessage; solo allowed
    case practiceVsCPU   // local; bots added in Phase 2
}

// MARK: - Game phases & actions

enum GamePhase: Codable, Equatable {
    case waiting
    case playing
    case ended
}

enum BettingRound: Codable, Equatable {
    case preFlop, flop, turn, river

    var displayName: String {
        switch self {
        case .preFlop: return "Pre-flop"
        case .flop: return "Flop"
        case .turn: return "Turn"
        case .river: return "River"
        }
    }
}

enum BettingAction: Codable {
    case fold
    case call(amount: Int)
    case raise(amount: Int)
    case check
}

// MARK: - Hand summary

enum HandRank: String, Codable {
    case highCard = "High Card"
    case pair = "Pair"
    case twoPair = "Two Pair"
    case threeOfAKind = "Three of a Kind"
    case straight = "Straight"
    case flush = "Flush"
    case fullHouse = "Full House"
    case fourOfAKind = "Four of a Kind"
    case straightFlush = "Straight Flush"
    case royalFlush = "Royal Flush"
}

// MARK: - Per-player hand tracking (session)

struct PlayerHandStats: Codable, Equatable {
    var handsWon: Int = 0
    var handsPlayed: Int = 0
    var biggestPot: Int = 0
}

// MARK: - Stats

struct PlayerStats: Identifiable, Codable {
    var id: String
    var name: String
    var avatarIndex: Int
    var handsWon: Int
    var handsPlayed: Int
    var biggestPot: Int
    var finalStack: Int
    var isWinner: Bool
}

// MARK: - Game state

struct GameState: Codable {
    /// Stable session identifier for this game; encoded in the iMessage bubble URL.
    var gameID: UUID = UUID()
    var gameMode: GameMode = .classicPoker
    var phase: GamePhase = .waiting
    var players: [Player] = []
    var board: [Card?] = Array(repeating: nil, count: 5)
    var pot: Int = 0
    var bettingRound: BettingRound = .preFlop
    var activePlayerID: String? = nil
    var heroID: String? = nil
    var heroHoleCards: [Card] = []
    var heroHandRank: HandRank? = nil
    var callAmount: Int = 0
    var raiseAmount: Int = 0
    var endStats: [PlayerStats] = []

    // Engine-owned fields (local session; not in message URL)
    var holeCardsByPlayer: [String: [Card]] = [:]
    var remainingDeck: [Card] = []
    var handStats: [String: PlayerHandStats] = [:]
    var streetBetLevel: Int = 0
    var lastRaiseSize: Int = 10
    var actedThisStreet: [String] = []
    var lastHandWinnerID: String? = nil
    var lastPotAwarded: Int = 0
}
