import Foundation
import Combine

@MainActor
final class GameStore: ObservableObject {
    @Published var state: GameState

    init(state: GameState = GameState()) {
        self.state = state
    }

    /// New waiting-room session; `gameID` is embedded in the iMessage bubble URL.
    static func createNew() -> GameState {
        var state = GameState()
        state.gameID = UUID()
        state.phase = .waiting
        return state
    }

    /// Reconstructs session identity from a tapped bubble URL.
    static func decode(from url: URL) -> GameState? {
        guard let (gameID, phase) = GameMessageURL.decode(from: url) else { return nil }
        var state = GameState()
        state.gameID = gameID
        state.phase = phase
        return state
    }

    func joinGame(playerID: String, name: String) {
        if let existing = state.players.firstIndex(where: { $0.id == playerID }) {
            if state.heroID == nil {
                state.heroID = state.players[existing].id
            }
            return
        }
        state.players.append(Player(id: playerID, name: name, stack: 500))
        if state.heroID == nil {
            state.heroID = playerID
        }
    }

    // MARK: - Waiting room intents

    func toggleReady() {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        state.players[idx].isReady.toggle()
    }

    func startGame() {
        state.phase = .playing
    }

    var allReady: Bool {
        !state.players.isEmpty && state.players.allSatisfy { $0.isReady }
    }

    // MARK: - Gameplay intents

    func call() {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        let amount = min(state.callAmount, state.players[idx].stack)
        state.players[idx].stack -= amount
        state.players[idx].currentBet += amount
        state.pot += amount
    }

    func raise(_ total: Int) {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        let amount = min(total, state.players[idx].stack)
        state.players[idx].stack -= amount
        state.players[idx].currentBet += amount
        state.pot += amount
    }

    func fold() {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        state.players[idx].isFolded = true
    }

    // MARK: - End game / navigation

    func endGame() {
        state.phase = .ended
        state.endStats = buildStats()
    }

    func resetToWaiting() {
        var fresh = GameState()
        fresh.phase = .waiting
        fresh.players = state.players.enumerated().map { (i, p) in
            var np = p
            np.isReady = false
            np.isFolded = false
            np.isEliminated = false
            np.currentBet = 0
            np.stack = 500
            return np
        }
        fresh.heroID = state.heroID
        state = fresh
    }

    private func buildStats() -> [PlayerStats] {
        state.players.map { p in
            PlayerStats(
                id: p.id,
                name: p.name,
                avatarIndex: p.avatarIndex,
                handsWon: Int.random(in: 2...10),
                handsPlayed: Int.random(in: 10...20),
                biggestPot: Int.random(in: 40...200),
                finalStack: p.stack,
                isWinner: !p.isEliminated && p.stack > 0
            )
        }
    }
}

// MARK: - Mock fixture (matches screenshot)

extension GameStore {
    static var mock: GameStore {
        var state = GameState()
        state.phase = .playing

        let jane  = Player(id: "jane",  name: "Jane",  stack: 480, isReady: true,  isDealer: false, avatarIndex: 0)
        let eli   = Player(id: "eli",   name: "Eli",   stack: 480, isReady: true,  isDealer: false, avatarIndex: 1)
        let gina  = Player(id: "gina",  name: "Gina",  stack: 500, isReady: true,  isDealer: true,  avatarIndex: 2)
        let steve = Player(id: "steve", name: "Steve", stack: 480, isReady: true,  isDealer: false, avatarIndex: 3)
        let rose  = Player(id: "rose",  name: "Rose",  stack: 488, isReady: true,  isDealer: false, avatarIndex: 4)

        state.players = [jane, eli, gina, steve, rose]

        state.board = [
            Card(rank: .four,  suit: .diamonds),
            Card(rank: .eight, suit: .spades),
            Card(rank: .five,  suit: .clubs),
            nil,
            nil
        ]

        state.pot = 92
        state.heroID = "rose"
        state.heroHoleCards = [Card(rank: .four, suit: .hearts), Card(rank: .ten, suit: .hearts)]
        state.heroHandRank = .pair
        state.activePlayerID = "rose"
        state.callAmount = 4
        state.raiseAmount = 8

        // Steve and Rose have posted bets this street
        state.players[3].currentBet = 2
        state.players[4].currentBet = 4

        return GameStore(state: state)
    }

    static var mockWaiting: GameStore {
        var state = GameState()
        state.phase = .waiting
        state.players = [
            Player(id: "jane",  name: "Jane",  stack: 500, isReady: true,  avatarIndex: 0),
            Player(id: "eli",   name: "Eli",   stack: 500, isReady: false, avatarIndex: 1),
            Player(id: "gina",  name: "Gina",  stack: 500, isReady: false, avatarIndex: 2),
            Player(id: "steve", name: "Steve", stack: 500, isReady: false, avatarIndex: 3),
            Player(id: "rose",  name: "Rose",  stack: 500, isReady: false, avatarIndex: 4),
        ]
        state.heroID = "rose"
        return GameStore(state: state)
    }

    static var mockEnded: GameStore {
        var state = GameState()
        state.phase = .ended
        state.players = [
            Player(id: "jane",  name: "Jane",  stack: 0,    isEliminated: true,  avatarIndex: 0),
            Player(id: "eli",   name: "Eli",   stack: 0,    isEliminated: true,  avatarIndex: 1),
            Player(id: "gina",  name: "Gina",  stack: 0,    isEliminated: true,  avatarIndex: 2),
            Player(id: "steve", name: "Steve", stack: 0,    isEliminated: true,  avatarIndex: 3),
            Player(id: "rose",  name: "Rose",  stack: 2500, isEliminated: false, avatarIndex: 4),
        ]
        state.heroID = "rose"
        state.endStats = [
            PlayerStats(id: "rose",  name: "Rose",  avatarIndex: 4, handsWon: 9,  handsPlayed: 18, biggestPot: 320, finalStack: 2500, isWinner: true),
            PlayerStats(id: "jane",  name: "Jane",  avatarIndex: 0, handsWon: 4,  handsPlayed: 14, biggestPot: 180, finalStack: 0,    isWinner: false),
            PlayerStats(id: "eli",   name: "Eli",   avatarIndex: 1, handsWon: 3,  handsPlayed: 12, biggestPot: 140, finalStack: 0,    isWinner: false),
            PlayerStats(id: "gina",  name: "Gina",  avatarIndex: 2, handsWon: 2,  handsPlayed: 11, biggestPot: 95,  finalStack: 0,    isWinner: false),
            PlayerStats(id: "steve", name: "Steve", avatarIndex: 3, handsWon: 2,  handsPlayed: 10, biggestPot: 88,  finalStack: 0,    isWinner: false),
        ]
        return GameStore(state: state)
    }
}
