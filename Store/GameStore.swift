import Foundation
import Combine

@MainActor
final class GameStore: ObservableObject {
    @Published var state: GameState

    private var engine = PokerEngine()
    private let botScheduler = BotTurnScheduler()
    private var botSessionConfig = BotSessionConfig.default
    private var botStrategy: BotStrategy = makeStrategy(for: .default)

    init(state: GameState = GameState()) {
        self.state = state
    }

    /// New waiting-room session; `gameID` is embedded in the iMessage bubble URL.
    static func createNew(mode: GameMode = .classicPoker) -> GameState {
        var state = GameState()
        state.gameID = UUID()
        state.gameMode = mode
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
        state.players.append(Player(id: playerID, name: name, stack: PokerEngine.startingStack))
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
        guard !state.players.isEmpty else { return }
        if state.gameMode == .practiceVsCPU {
            seedBots()
        }
        engine.startGame(&state)
        engine.startHand(&state)
        let previousPhase = state.phase
        state.phase = .playing
        #if DEBUG
        GameLog.phaseChange(from: previousPhase, to: .playing, mode: state.gameMode)
        GameLog.snapshot(state, event: "startGame")
        #endif
        scheduleBotTurnIfNeeded()
    }

    var allReady: Bool {
        !state.players.isEmpty && state.players.allSatisfy { $0.isReady }
    }

    var isHeroTurn: Bool {
        guard let heroID = state.heroID else { return false }
        return state.activePlayerID == heroID
    }

    // MARK: - Gameplay intents

    func check() {
        apply(.check)
    }

    func call() {
        apply(.call(amount: state.callAmount))
    }

    func raise(_ targetTotal: Int) {
        apply(.raise(amount: targetTotal))
    }

    func fold() {
        apply(.fold)
    }

    // MARK: - End game / navigation

    func endGame() {
        let previousPhase = state.phase
        state.phase = .ended
        state.endStats = buildStats()
        #if DEBUG
        GameLog.phaseChange(from: previousPhase, to: .ended, mode: state.gameMode)
        GameLog.snapshot(state, event: "endGame")
        #endif
    }

    func continueAfterHandSummary() {
        guard state.phase == .handSummary else { return }
        if engine.shouldEndGame(state) {
            endGame()
        } else {
            engine.startHand(&state)
            let previousPhase = state.phase
            state.phase = .playing
            #if DEBUG
            GameLog.phaseChange(from: previousPhase, to: .playing, mode: state.gameMode)
            GameLog.snapshot(state, event: "next hand")
            #endif
            scheduleBotTurnIfNeeded()
        }
    }

    var sessionEndsAfterHandSummary: Bool {
        engine.shouldEndGame(state)
    }

    func resetToWaiting() {
        botScheduler.cancel()
        let previousPhase = state.phase
        var fresh = GameState()
        fresh.phase = .waiting
        fresh.gameID = state.gameID
        fresh.gameMode = state.gameMode
        fresh.players = state.players
            .filter { !$0.isBot }
            .map { p in
                var np = p
                np.isReady = false
                np.isFolded = false
                np.isEliminated = false
                np.isDealer = false
                np.currentBet = 0
                np.stack = PokerEngine.startingStack
                return np
            }
        fresh.heroID = state.heroID
        state = fresh
        #if DEBUG
        GameLog.phaseChange(from: previousPhase, to: .waiting, mode: state.gameMode)
        GameLog.snapshot(state, event: "resetToWaiting")
        #endif
    }

    // MARK: - Private

    private func apply(_ action: BettingAction) {
        guard let heroID = state.heroID else { return }
        applyAction(for: heroID, action: action)
    }

    private func applyAction(for playerID: String, action: BettingAction) {
        guard state.phase == .playing else { return }
        guard engine.applyAction(&state, playerID: playerID, action: action) else { return }

        #if DEBUG
        if playerID == state.heroID {
            GameLog.heroAction(action, state: state)
        } else {
            GameLog.playerAction(playerID: playerID, action: action, state: state)
            GameLog.snapshot(state, event: "after bot action")
        }
        #endif

        if state.activePlayerID == nil {
            finalizeHandIfNeeded()
        } else {
            scheduleBotTurnIfNeeded()
        }
    }

    private func finalizeHandIfNeeded() {
        #if DEBUG
        if state.lastPotAwarded > 0, let winnerID = state.lastHandWinnerID {
            GameLog.potAwarded(amount: state.lastPotAwarded, winnerID: winnerID)
        }
        GameLog.snapshot(state, event: "hand complete")
        #endif
        botScheduler.cancel()
        state.endStats = buildHandSummaryStats()
        let previousPhase = state.phase
        state.phase = .handSummary
        #if DEBUG
        GameLog.phaseChange(from: previousPhase, to: .handSummary, mode: state.gameMode)
        #endif
    }

    private func scheduleBotTurnIfNeeded() {
        guard state.gameMode == .practiceVsCPU,
              let id = state.activePlayerID,
              isBot(id) else { return }
        botScheduler.schedule { [weak self] in
            self?.performBotTurn(playerID: id)
        }
    }

    private func performBotTurn(playerID: String) {
        guard state.phase == .playing,
              state.activePlayerID == playerID,
              isBot(playerID) else { return }
        let legal = engine.legalActions(for: state, playerID: playerID)
        guard !legal.isEmpty else { return }
        let action = botStrategy.chooseAction(
            state: state,
            playerID: playerID,
            legalActions: legal
        )
        applyAction(for: playerID, action: action)
    }

    private func seedBots() {
        state.players.removeAll { $0.isBot }
        state.players.append(contentsOf: BotCatalog.makeBots(count: botSessionConfig.botCount))
        botStrategy = makeStrategy(for: botSessionConfig)
    }

    private func isBot(_ playerID: String) -> Bool {
        state.players.first(where: { $0.id == playerID })?.isBot == true
    }

    private func buildHandSummaryStats() -> [PlayerStats] {
        let winnerID = state.lastHandWinnerID
        return state.players.map { p in
            let tracked = state.handStats[p.id] ?? PlayerHandStats()
            return PlayerStats(
                id: p.id,
                name: p.name,
                avatarIndex: p.avatarIndex,
                handsWon: tracked.handsWon,
                handsPlayed: tracked.handsPlayed,
                biggestPot: tracked.biggestPot,
                finalStack: p.stack,
                isWinner: p.id == winnerID
            )
        }
        .sorted { $0.finalStack > $1.finalStack }
    }

    private func buildStats() -> [PlayerStats] {
        let survivors = state.players.filter { !$0.isEliminated && $0.stack > 0 }
        let winnerID: String?
        if survivors.count == 1 {
            winnerID = survivors[0].id
        } else if let leader = state.players.max(by: { $0.stack < $1.stack }) {
            let topStack = leader.stack
            let tied = state.players.filter { $0.stack == topStack }
            if tied.count > 1, let heroID = state.heroID, tied.contains(where: { $0.id == heroID }) {
                winnerID = heroID
            } else {
                winnerID = leader.id
            }
        } else {
            winnerID = nil
        }

        return state.players.map { p in
            let tracked = state.handStats[p.id] ?? PlayerHandStats()
            return PlayerStats(
                id: p.id,
                name: p.name,
                avatarIndex: p.avatarIndex,
                handsWon: tracked.handsWon,
                handsPlayed: tracked.handsPlayed,
                biggestPot: tracked.biggestPot,
                finalStack: p.stack,
                isWinner: p.id == winnerID
            )
        }
        .sorted { $0.finalStack > $1.finalStack }
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
        state.bettingRound = .flop

        state.players[3].currentBet = 2
        state.players[4].currentBet = 4

        return GameStore(state: state)
    }

    /// Single-player session after `startGame()` — use for solo flow testing.
    static var mockSoloPlaying: GameStore {
        let store = GameStore()
        store.state.players = [Player(id: "solo", name: "Player", stack: 500, isReady: true, avatarIndex: 0)]
        store.state.heroID = "solo"
        store.startGame()
        return store
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

    static var mockHandSummary: GameStore {
        var state = GameState()
        state.phase = .handSummary
        state.players = [
            Player(id: "hero", name: "You", stack: 520, avatarIndex: 0),
            Player(id: "bot-1", name: "CPU 1", stack: 480, avatarIndex: 1, isBot: true),
        ]
        state.heroID = "hero"
        state.lastHandWinnerID = "hero"
        state.lastPotAwarded = 40
        state.handStats = [
            "hero": PlayerHandStats(handsWon: 2, handsPlayed: 3, biggestPot: 40),
            "bot-1": PlayerHandStats(handsWon: 1, handsPlayed: 3, biggestPot: 20),
        ]
        state.endStats = [
            PlayerStats(id: "hero", name: "You", avatarIndex: 0, handsWon: 2, handsPlayed: 3, biggestPot: 40, finalStack: 520, isWinner: true),
            PlayerStats(id: "bot-1", name: "CPU 1", avatarIndex: 1, handsWon: 1, handsPlayed: 3, biggestPot: 20, finalStack: 480, isWinner: false),
        ]
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
