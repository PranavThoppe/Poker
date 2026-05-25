import Foundation

struct PokerEngine {
    static let smallBlind = 5
    static let bigBlind = 10
    static let startingStack = 500

    // MARK: - Session / hand lifecycle

    mutating func startGame(_ state: inout GameState) {
        guard !state.players.isEmpty else { return }
        for i in state.players.indices {
            state.players[i].isFolded = false
            state.players[i].currentBet = 0
            if state.handStats[state.players[i].id] == nil {
                state.handStats[state.players[i].id] = PlayerHandStats()
            }
        }
        state.board = Array(repeating: nil, count: 5)
        state.pot = 0
        state.holeCardsByPlayer = [:]
        state.streetBetLevel = 0
        state.lastRaiseSize = Self.bigBlind
        state.actedThisStreet = []
    }

    mutating func startHand(_ state: inout GameState) {
        let activeCount = state.players.filter { !$0.isEliminated }.count
        guard activeCount > 0 else { return }

        for i in state.players.indices where !state.players[i].isEliminated {
            state.players[i].isFolded = false
            state.players[i].currentBet = 0
            state.handStats[state.players[i].id, default: PlayerHandStats()].handsPlayed += 1
        }

        state.board = Array(repeating: nil, count: 5)
        state.pot = 0
        state.holeCardsByPlayer = [:]
        state.streetBetLevel = 0
        state.lastRaiseSize = Self.bigBlind
        state.actedThisStreet = []
        state.lastHandWinnerID = nil
        state.lastPotAwarded = 0
        state.bettingRound = .preFlop

        rotateDealer(&state)

        var deck = Deck()
        for idx in state.players.indices where !state.players[idx].isEliminated {
            let id = state.players[idx].id
            state.holeCardsByPlayer[id] = deck.draw(2)
        }
        state.remainingDeck = deck.saveRemaining()

        if activeCount >= 2 {
            postBlinds(&state)
        }

        setFirstToAct(&state, preFlop: true)
        syncBettingUI(&state)
        updateHeroDisplay(&state)
    }

    // MARK: - Actions

    @discardableResult
    mutating func applyAction(_ state: inout GameState, playerID: String, action: BettingAction) -> Bool {
        guard state.activePlayerID == playerID,
              let idx = state.players.firstIndex(where: { $0.id == playerID }),
              !state.players[idx].isFolded,
              !state.players[idx].isEliminated else { return false }

        switch action {
        case .fold:
            state.players[idx].isFolded = true
        case .check:
            guard state.players[idx].currentBet == state.streetBetLevel else { return false }
        case .call(let amount):
            let toCall = state.streetBetLevel - state.players[idx].currentBet
            guard toCall > 0, amount >= toCall else { return false }
            postBet(&state, playerIndex: idx, amount: toCall)
        case .raise(let targetTotal):
            guard targetTotal > state.streetBetLevel else { return false }
            let needed = targetTotal - state.players[idx].currentBet
            guard needed > 0, needed <= state.players[idx].stack else { return false }
            let previousLevel = state.streetBetLevel
            postBet(&state, playerIndex: idx, amount: needed)
            if targetTotal > previousLevel {
                state.lastRaiseSize = targetTotal - previousLevel
                state.streetBetLevel = targetTotal
                resetActed(&state, except: playerID)
            }
        }

        markActed(&state, playerID: playerID)

        let stillActive = state.players.indices.filter {
            !state.players[$0].isEliminated && !state.players[$0].isFolded
        }
        if stillActive.isEmpty {
            state.activePlayerID = nil
            syncBettingUI(&state)
            return true
        }

        if let winnerIdx = soleRemainingPlayerIndex(&state) {
            awardPotToWinner(&state, winnerIndex: winnerIdx, wentToShowdown: false)
            return true
        }

        if isBettingRoundComplete(&state) {
            if state.bettingRound == .river {
                resolveShowdown(&state)
            } else {
                advanceStreet(&state)
            }
        } else {
            advanceToNextPlayer(&state)
        }

        syncBettingUI(&state)
        updateHeroDisplay(&state)
        return true
    }

    func legalActions(for state: GameState, playerID: String) -> [BettingAction] {
        guard state.activePlayerID == playerID,
              let idx = state.players.firstIndex(where: { $0.id == playerID }),
              !state.players[idx].isFolded,
              !state.players[idx].isEliminated else { return [] }

        var actions: [BettingAction] = [.fold]
        let player = state.players[idx]
        let toCall = state.streetBetLevel - player.currentBet

        if player.currentBet == state.streetBetLevel {
            actions.append(.check)
        }

        if toCall > 0, player.stack >= toCall {
            actions.append(.call(amount: toCall))
        }

        let minRaiseTo = state.streetBetLevel + max(state.lastRaiseSize, Self.bigBlind)
        let needed = minRaiseTo - player.currentBet
        if minRaiseTo > state.streetBetLevel, needed > 0, needed <= player.stack {
            actions.append(.raise(amount: minRaiseTo))
        }

        return actions
    }

    func shouldEndGame(_ state: GameState) -> Bool {
        state.players.filter { !$0.isEliminated && $0.stack > 0 }.count <= 1
    }

    func shouldStartNextHand(_ state: GameState) -> Bool {
        !shouldEndGame(state)
    }

    // MARK: - Showdown

    mutating func resolveShowdown(_ state: inout GameState) {
        let contenders = state.players.indices.filter {
            !state.players[$0].isEliminated && !state.players[$0].isFolded
        }
        guard !contenders.isEmpty else { return }

        let boardCards = state.board.compactMap { $0 }
        var bestIdx = contenders[0]
        var bestScore = handScore(for: state.players[bestIdx].id, board: boardCards, state: state)

        for idx in contenders.dropFirst() {
            let score = handScore(for: state.players[idx].id, board: boardCards, state: state)
            if score > bestScore {
                bestScore = score
                bestIdx = idx
            }
        }

        awardPotToWinner(&state, winnerIndex: bestIdx, wentToShowdown: true)
        updateHeroDisplay(&state)
    }

    // MARK: - Private helpers

    private func handScore(for playerID: String, board: [Card], state: GameState) -> HandScore {
        let hole = state.holeCardsByPlayer[playerID] ?? []
        return HandEvaluator.evaluateBest(from: hole + board).score
    }

    private mutating func awardPotToWinner(
        _ state: inout GameState,
        winnerIndex: Int,
        wentToShowdown: Bool
    ) {
        let winnerID = state.players[winnerIndex].id
        let potAmount = state.pot
        state.lastHandWinnerID = winnerID
        state.lastPotAwarded = potAmount
        if potAmount > 0 {
            state.players[winnerIndex].stack += potAmount
            var stats = state.handStats[winnerID, default: PlayerHandStats()]
            stats.handsWon += 1
            stats.biggestPot = max(stats.biggestPot, potAmount)
            state.handStats[winnerID] = stats
        }
        state.pot = 0
        clearStreetBets(&state)

        for i in state.players.indices where state.players[i].stack <= 0 && !state.players[i].isEliminated {
            state.players[i].isEliminated = true
            state.players[i].stack = 0
        }

        state.activePlayerID = nil
    }

    private mutating func postBlinds(_ state: inout GameState) {
        guard let sbIdx = nextActiveIndex(from: dealerIndex(state), in: state),
              let bbIdx = nextActiveIndex(from: sbIdx, in: state) else { return }

        postBet(&state, playerIndex: sbIdx, amount: min(Self.smallBlind, state.players[sbIdx].stack))
        postBet(&state, playerIndex: bbIdx, amount: min(Self.bigBlind, state.players[bbIdx].stack))

        state.streetBetLevel = state.players[bbIdx].currentBet
        state.lastRaiseSize = Self.bigBlind
        state.actedThisStreet = []
    }

    private mutating func postBet(_ state: inout GameState, playerIndex: Int, amount: Int) {
        let pay = min(amount, state.players[playerIndex].stack)
        guard pay > 0 else { return }
        state.players[playerIndex].stack -= pay
        state.players[playerIndex].currentBet += pay
        state.pot += pay
        if state.players[playerIndex].currentBet > state.streetBetLevel {
            state.streetBetLevel = state.players[playerIndex].currentBet
        }
    }

    private mutating func clearStreetBets(_ state: inout GameState) {
        for i in state.players.indices {
            state.players[i].currentBet = 0
        }
        state.streetBetLevel = 0
        state.actedThisStreet = []
    }

    private mutating func rotateDealer(_ state: inout GameState) {
        guard !state.players.isEmpty else { return }
        if let current = state.players.firstIndex(where: { $0.isDealer }) {
            state.players[current].isDealer = false
            if let next = nextActiveIndex(from: current, in: state) {
                state.players[next].isDealer = true
            }
        } else if let first = state.players.firstIndex(where: { !$0.isEliminated }) {
            state.players[first].isDealer = true
        }
    }

    private func dealerIndex(_ state: GameState) -> Int {
        state.players.firstIndex(where: { $0.isDealer }) ?? 0
    }

    private func nextActiveIndex(from index: Int, in state: GameState) -> Int? {
        let count = state.players.count
        guard count > 0 else { return nil }
        var i = (index + 1) % count
        for _ in 0..<count {
            if !state.players[i].isEliminated && !state.players[i].isFolded {
                return i
            }
            i = (i + 1) % count
        }
        return nil
    }

    private mutating func setFirstToAct(_ state: inout GameState, preFlop: Bool) {
        let dealer = dealerIndex(state)
        let startFrom: Int
        if preFlop, state.players.filter({ !$0.isEliminated }).count >= 2 {
            if let bb = nextActiveIndex(from: dealer, in: state),
               let afterBB = nextActiveIndex(from: bb, in: state) {
                startFrom = afterBB
            } else {
                startFrom = dealer
            }
        } else if let leftOfDealer = nextActiveIndex(from: dealer, in: state) {
            startFrom = leftOfDealer
        } else {
            startFrom = dealer
        }
        state.activePlayerID = state.players[startFrom].id
    }

    private mutating func advanceToNextPlayer(_ state: inout GameState) {
        guard let current = state.players.firstIndex(where: { $0.id == state.activePlayerID }) else { return }
        var i = (current + 1) % state.players.count
        for _ in 0..<state.players.count {
            if !state.players[i].isEliminated && !state.players[i].isFolded {
                state.activePlayerID = state.players[i].id
                return
            }
            i = (i + 1) % state.players.count
        }
        state.activePlayerID = nil
    }

    /// Non-nil when all but one player have folded (multi-player fold-out).
    private func soleRemainingPlayerIndex(_ state: inout GameState) -> Int? {
        let inHand = state.players.filter { !$0.isEliminated }
        guard inHand.count > 1 else { return nil }

        let remaining = state.players.indices.filter {
            !state.players[$0].isEliminated && !state.players[$0].isFolded
        }
        return remaining.count == 1 ? remaining[0] : nil
    }

    private func isBettingRoundComplete(_ state: inout GameState) -> Bool {
        let active = state.players.indices.filter {
            !state.players[$0].isEliminated && !state.players[$0].isFolded
        }
        if active.count <= 1 { return true }

        // Solo: one player acts and the street is done.
        if state.players.filter({ !$0.isEliminated }).count == 1 {
            return true
        }

        let level = state.streetBetLevel
        for idx in active {
            let p = state.players[idx]
            if p.currentBet < level && p.stack > 0 { return false }
        }

        let activeIDs = Set(active.map { state.players[$0].id })
        return activeIDs.isSubset(of: Set(state.actedThisStreet))
    }

    private mutating func markActed(_ state: inout GameState, playerID: String) {
        if !state.actedThisStreet.contains(playerID) {
            state.actedThisStreet.append(playerID)
        }
    }

    private mutating func resetActed(_ state: inout GameState, except playerID: String) {
        state.actedThisStreet = [playerID]
    }

    private mutating func advanceStreet(_ state: inout GameState) {
        clearStreetBets(&state)
        var deck = Deck(remainingCards: state.remainingDeck)

        switch state.bettingRound {
        case .preFlop:
            _ = deck.draw()
            let flop = deck.draw(3)
            if flop.count == 3 {
                state.board[0] = flop[0]
                state.board[1] = flop[1]
                state.board[2] = flop[2]
            }
            state.bettingRound = .flop
        case .flop:
            _ = deck.draw()
            if let card = deck.draw() { state.board[3] = card }
            state.bettingRound = .turn
        case .turn:
            _ = deck.draw()
            if let card = deck.draw() { state.board[4] = card }
            state.bettingRound = .river
        case .river:
            return
        }

        state.remainingDeck = deck.saveRemaining()
        setFirstToAct(&state, preFlop: false)
    }

    mutating func syncBettingUI(_ state: inout GameState) {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else {
            state.callAmount = 0
            state.raiseAmount = state.streetBetLevel + max(state.lastRaiseSize, Self.bigBlind)
            return
        }
        let heroBet = state.players[idx].currentBet
        state.callAmount = max(0, state.streetBetLevel - heroBet)
        let minRaiseTo = state.streetBetLevel + max(state.lastRaiseSize, Self.bigBlind)
        state.raiseAmount = min(minRaiseTo, heroBet + state.players[idx].stack)
        if state.raiseAmount <= state.streetBetLevel {
            state.raiseAmount = min(state.streetBetLevel + Self.bigBlind, heroBet + state.players[idx].stack)
        }
    }

    mutating func updateHeroDisplay(_ state: inout GameState) {
        guard let heroID = state.heroID else { return }
        state.heroHoleCards = state.holeCardsByPlayer[heroID] ?? []
        let boardCards = state.board.compactMap { $0 }
        guard state.heroHoleCards.count == 2 else {
            state.heroHandRank = nil
            return
        }
        if boardCards.isEmpty {
            let result = HandEvaluator.evaluateBest(from: state.heroHoleCards)
            state.heroHandRank = result.rank
        } else {
            let result = HandEvaluator.evaluateBest(from: state.heroHoleCards + boardCards)
            state.heroHandRank = result.rank
        }
    }
}
