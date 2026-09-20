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
    /// A seated player who is temporarily excluded from future hands, but keeps their stack
    /// and history. Missing in pre-sit-out room payloads means `false`.
    var isSittingOut: Bool = false
    var currentBet: Int = 0
    var avatarIndex: Int = 0
    var isBot: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, stack, isReady, isDealer, isFolded, isEliminated, isSittingOut
        case currentBet, avatarIndex, isBot
    }

    init(
        id: String,
        name: String,
        stack: Int,
        isReady: Bool = false,
        isDealer: Bool = false,
        isFolded: Bool = false,
        isEliminated: Bool = false,
        isSittingOut: Bool = false,
        currentBet: Int = 0,
        avatarIndex: Int = 0,
        isBot: Bool = false
    ) {
        self.id = id
        self.name = name
        self.stack = stack
        self.isReady = isReady
        self.isDealer = isDealer
        self.isFolded = isFolded
        self.isEliminated = isEliminated
        self.isSittingOut = isSittingOut
        self.currentBet = currentBet
        self.avatarIndex = avatarIndex
        self.isBot = isBot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        stack = try values.decode(Int.self, forKey: .stack)
        isReady = try values.decodeIfPresent(Bool.self, forKey: .isReady) ?? false
        isDealer = try values.decodeIfPresent(Bool.self, forKey: .isDealer) ?? false
        isFolded = try values.decodeIfPresent(Bool.self, forKey: .isFolded) ?? false
        isEliminated = try values.decodeIfPresent(Bool.self, forKey: .isEliminated) ?? false
        isSittingOut = try values.decodeIfPresent(Bool.self, forKey: .isSittingOut) ?? false
        currentBet = try values.decodeIfPresent(Int.self, forKey: .currentBet) ?? 0
        avatarIndex = try values.decodeIfPresent(Int.self, forKey: .avatarIndex) ?? 0
        isBot = try values.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
    }
}

// MARK: - Game mode

enum GameMode: String, Codable, Equatable {
    case classicPoker    // iMessage; solo allowed
    case practiceVsCPU   // local; bots added in Phase 2
}

/// Why a session ended. Used for win credit and the manual-finish tie flow.
enum GameEndReason: String, Codable, Equatable {
    case autoLastStanding
    case manualFinish
    case manualFinishTieForfeit
}

// MARK: - Game phases & actions

enum GamePhase: Codable, Equatable {
    case waiting
    case playing
    case showdown
    case handSummary
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

enum HandRank: String, Codable, CaseIterable {
    case highCard = "High Card"
    case pair = "Pair"
    case twoPair = "2 Pair"
    case threeOfAKind = "3 of a Kind"
    case straight = "Straight"
    case flush = "Flush"
    case fullHouse = "Full House"
    case fourOfAKind = "4 of a Kind"
    case straightFlush = "Straight Flush"
    case royalFlush = "Royal Flush"
}

// MARK: - Showdown / pot result

struct RevealedHand: Codable, Equatable {
    let playerID: String
    let holeCards: [Card]
    let rank: HandRank
    let bestFive: [Card]
}

struct PotAward: Codable, Equatable {
    let amount: Int
    let eligibleIDs: [String]
    let winnerIDs: [String]
    let shares: [String: Int]
    let isSidePot: Bool
}

struct HandResult: Codable, Equatable {
    var pots: [PotAward] = []
    var payouts: [String: Int] = [:]
    var reveals: [RevealedHand] = []
    var wentToShowdown: Bool = false
    /// False while a showdown reveal is in progress — stacks have not received `payouts` yet.
    /// Defaults to true when decoding older payloads that credited stacks in `distributePots`.
    var payoutsApplied: Bool = true

    var winnerIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for id in pots.flatMap(\.winnerIDs) where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    var totalAwarded: Int { payouts.values.reduce(0, +) }

    enum CodingKeys: String, CodingKey {
        case pots, payouts, reveals, wentToShowdown, payoutsApplied
    }

    init(
        pots: [PotAward] = [],
        payouts: [String: Int] = [:],
        reveals: [RevealedHand] = [],
        wentToShowdown: Bool = false,
        payoutsApplied: Bool = true
    ) {
        self.pots = pots
        self.payouts = payouts
        self.reveals = reveals
        self.wentToShowdown = wentToShowdown
        self.payoutsApplied = payoutsApplied
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pots = try container.decodeIfPresent([PotAward].self, forKey: .pots) ?? []
        payouts = try container.decodeIfPresent([String: Int].self, forKey: .payouts) ?? [:]
        reveals = try container.decodeIfPresent([RevealedHand].self, forKey: .reveals) ?? []
        wentToShowdown = try container.decodeIfPresent(Bool.self, forKey: .wentToShowdown) ?? false
        payoutsApplied = try container.decodeIfPresent(Bool.self, forKey: .payoutsApplied) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pots, forKey: .pots)
        try container.encode(payouts, forKey: .payouts)
        try container.encode(reveals, forKey: .reveals)
        try container.encode(wentToShowdown, forKey: .wentToShowdown)
        try container.encode(payoutsApplied, forKey: .payoutsApplied)
    }
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

/// A one-time public announcement emitted when the host raises the blinds.
/// The event remains in the synced state so active clients can receive it reliably.
struct BlindIncreaseAnnouncement: Codable, Equatable {
    let id: UUID
    let smallBlind: Int
}

struct GameState: Codable {
    /// Stable session identifier for this game; encoded in the iMessage bubble URL.
    var gameID: UUID = UUID()
    /// Stable device ID of the room creator. Public metadata, never a display name.
    var hostID: String? = nil
    /// Changes for every hand so clients can discard private cards from the previous deal.
    var handID: UUID? = nil
    /// Bumped on every publish so clients can reject duplicate or out-of-order remote writes.
    /// Optional because rows written before this field existed must still decode.
    var stateVersion: Int? = nil
    var gameMode: GameMode = .classicPoker
    var phase: GamePhase = .waiting
    /// Chips assigned to every player before the first hand. `nil` preserves the
    /// original 500-chip stack for rooms created before lobby settings existed.
    var startingStack: Int? = nil
    /// The small blind for the next hand. `nil` preserves the original 5/10 level for rooms
    /// created before configurable blinds were introduced.
    var smallBlind: Int? = nil
    /// The most recent blind-change announcement. Optional for rooms written before this existed.
    var blindIncreaseAnnouncement: BlindIncreaseAnnouncement? = nil
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
    /// Completed hands this session (synced for win-floor gating).
    var completedHandCount: Int = 0
    /// Shared across devices when manual Finish is attempted while chip counts are tied.
    var manualFinishTieAttempts: Int = 0

    // Engine-owned fields (local session; not in message URL)
    var holeCardsByPlayer: [String: [Card]] = [:]
    var remainingDeck: [Card] = []
    var handStats: [String: PlayerHandStats] = [:]
    var streetBetLevel: Int = 0
    var lastRaiseSize: Int = 10
    var actedThisStreet: [String] = []
    /// Chips each player has put in this hand. Optional so older `game_rooms` rows still decode.
    var contributions: [String: Int]? = nil
    /// Outcome of the just-finished hand. Public `reveals` fill in as each player shows.
    var handResult: HandResult? = nil
    /// Last player who bet or raised this hand. Optional so older rows still decode.
    var lastAggressorID: String? = nil
    /// Whose turn it is to tap Show. Kept in sync with `activePlayerID` during `.showdown`.
    var pendingRevealPlayerID: String? = nil

    var lastHandWinnerID: String? { handResult?.winnerIDs.first }
    var lastPotAwarded: Int { handResult?.totalAwarded ?? 0 }

    var version: Int { stateVersion ?? 0 }
}
