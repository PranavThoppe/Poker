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
        state.handID = UUID()
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
        // Blinds put everyone all-in, so there is nothing to bet — deal the board out.
        if state.activePlayerID == nil, activeCount >= 2 {
            resolveCompletedBettingRound(&state)
        }
        syncBettingUI(&state)
        updateHeroDisplay(&state)
    }

    // MARK: - Actions

    @discardableResult
    mutating func applyAction(
        _ state: inout GameState,
        playerID: String,
        action: BettingAction,
        canResolveBettingRound: Bool = true
    ) -> Bool {
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
            // A player short of the full amount calls all-in for less.
            let owed = min(toCall, state.players[idx].stack)
            guard toCall > 0, owed > 0, amount >= owed else { return false }
            postBet(&state, playerIndex: idx, amount: owed)
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
            if canResolveBettingRound {
                resolveCompletedBettingRound(&state)
            } else {
                state.activePlayerID = nil
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

        // Calling with a short stack is legal; the payment clamps to an all-in.
        if toCall > 0, player.stack > 0 {
            actions.append(.call(amount: toCall))
        }

        // When the minimum raise is unaffordable, shoving the rest of the stack still is.
        let maxTotal = player.currentBet + player.stack
        let minRaiseTo = state.streetBetLevel + max(state.lastRaiseSize, Self.bigBlind)
        if maxTotal > state.streetBetLevel {
            actions.append(.raise(amount: min(minRaiseTo, maxTotal)))
        }

        return actions
    }

    /// Resolves a betting round that a guest completed without access to the host-owned deck.
    /// Returns `true` only when the state represented a complete, pending round.
    @discardableResult
    mutating func resolvePendingBettingRound(_ state: inout GameState) -> Bool {
        guard state.activePlayerID == nil,
              state.lastHandWinnerID == nil,
              isBettingRoundComplete(&state) else { return false }

        resolveCompletedBettingRound(&state)
        syncBettingUI(&state)
        updateHeroDisplay(&state)
        return true
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

    /// Seats posting the blinds. Heads-up the button posts the small blind; otherwise the
    /// small blind is left of the button and the big blind left of that.
    private func blindIndices(_ state: GameState) -> (smallBlind: Int, bigBlind: Int)? {
        let dealer = dealerIndex(state)
        let activeCount = state.players.filter { !$0.isEliminated }.count
        guard activeCount >= 2 else { return nil }

        if activeCount == 2 {
            guard let other = nextActiveIndex(from: dealer, in: state) else { return nil }
            return (smallBlind: dealer, bigBlind: other)
        }
        guard let sb = nextActiveIndex(from: dealer, in: state),
              let bb = nextActiveIndex(from: sb, in: state) else { return nil }
        return (smallBlind: sb, bigBlind: bb)
    }

    private mutating func postBlinds(_ state: inout GameState) {
        guard let blinds = blindIndices(state) else { return }
        let sbIdx = blinds.smallBlind
        let bbIdx = blinds.bigBlind

        postBet(&state, playerIndex: sbIdx, amount: min(Self.smallBlind, state.players[sbIdx].stack))
        postBet(&state, playerIndex: bbIdx, amount: min(Self.bigBlind, state.players[bbIdx].stack))

        state.streetBetLevel = max(state.players[sbIdx].currentBet, state.players[bbIdx].currentBet)
        state.lastRaiseSize = Self.bigBlind
        state.actedThisStreet = []
        markAllInPlayersActed(&state)
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

    /// True when the player still has a decision to make: in the hand and holding chips.
    private func canAct(_ index: Int, _ state: GameState) -> Bool {
        let player = state.players[index]
        return !player.isEliminated && !player.isFolded && player.stack > 0
    }

    /// First seat from `index` that can still act, or nil when everyone left is all-in.
    /// Exclusive scans never wrap back onto `index`, so the turn cannot return to the
    /// player who just acted.
    private func actorIndex(from index: Int, in state: GameState, inclusive: Bool) -> Int? {
        let count = state.players.count
        guard count > 0 else { return nil }
        let offsets = inclusive ? Array(0..<count) : Array(1..<count)
        for offset in offsets {
            let i = (index + offset) % count
            if canAct(i, state) { return i }
        }
        return nil
    }

    private mutating func setFirstToAct(_ state: inout GameState, preFlop: Bool) {
        let count = state.players.count
        guard count > 0 else { return }
        let dealer = dealerIndex(state)

        let startFrom: Int
        if preFlop, let blinds = blindIndices(state) {
            // Heads-up the button opens; otherwise UTG, the seat left of the big blind.
            startFrom = state.players.filter { !$0.isEliminated }.count == 2
                ? blinds.smallBlind
                : (blinds.bigBlind + 1) % count
        } else {
            // Post-flop the first live seat left of the button opens.
            startFrom = (dealer + 1) % count
        }

        state.activePlayerID = actorIndex(from: startFrom, in: state, inclusive: true)
            .map { state.players[$0].id }
    }

    private mutating func advanceToNextPlayer(_ state: inout GameState) {
        guard let current = state.players.firstIndex(where: { $0.id == state.activePlayerID }) else { return }
        state.activePlayerID = actorIndex(from: current, in: state, inclusive: false)
            .map { state.players[$0].id }
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

        // Everyone left is all-in, so there is no decision to wait on.
        if !active.contains(where: { canAct($0, state) }) { return true }

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
        markAllInPlayersActed(&state)
    }

    /// All-in players have no decision left, so a raise must not put them back on the clock.
    private mutating func markAllInPlayersActed(_ state: inout GameState) {
        let allInIDs = state.players
            .filter { !$0.isEliminated && !$0.isFolded && $0.stack == 0 }
            .map(\.id)
        for id in allInIDs {
            markActed(&state, playerID: id)
        }
    }

    private mutating func resolveCompletedBettingRound(_ state: inout GameState) {
        if state.bettingRound == .river {
            resolveShowdown(&state)
        } else {
            advanceStreet(&state)
        }
    }

    /// Rebuilds the deck from cards not already in play. Recovers hands where the host lost
    /// `remainingDeck` (an extension relaunch wipes it); otherwise the board silently stays
    /// blank for the rest of the hand while betting continues street by street.
    private mutating func replenishDeckIfNeeded(_ state: inout GameState, minimumCards: Int) {
        guard state.remainingDeck.count < minimumCards else { return }

        var inPlay = Set(state.board.compactMap { $0?.id })
        for cards in state.holeCardsByPlayer.values {
            inPlay.formUnion(cards.map(\.id))
        }
        inPlay.formUnion(state.heroHoleCards.map(\.id))

        var replacement = Deck()
        var available: [Card] = []
        while let card = replacement.draw() {
            if !inPlay.contains(card.id) { available.append(card) }
        }
        state.remainingDeck = available
    }

    private mutating func advanceStreet(_ state: inout GameState) {
        clearStreetBets(&state)
        markAllInPlayersActed(&state)
        // Burn card plus up to three community cards.
        replenishDeckIfNeeded(&state, minimumCards: 4)
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

        // Nobody can act (all remaining players are all-in): run the rest of the board out
        // rather than leaving the table with no active player.
        if state.activePlayerID == nil {
            resolveCompletedBettingRound(&state)
        }
    }

    /// Restores a hand whose active player was lost — a dropped sync write or a client that
    /// was relaunched mid-hand. Resolves the round if it is genuinely complete, otherwise
    /// hands the action to a player who still owes one so the table can never freeze.
    @discardableResult
    mutating func recoverStalledHand(_ state: inout GameState) -> Bool {
        guard state.activePlayerID == nil, state.lastHandWinnerID == nil else { return false }

        if resolvePendingBettingRound(&state) { return true }

        let count = state.players.count
        guard count > 0 else { return false }
        let start = (dealerIndex(state) + 1) % count

        var candidate: Int? = nil
        for offset in 0..<count {
            let i = (start + offset) % count
            guard canAct(i, state) else { continue }
            if candidate == nil { candidate = i }
            if !state.actedThisStreet.contains(state.players[i].id) {
                candidate = i
                break
            }
        }
        guard let seat = candidate else { return false }

        state.activePlayerID = state.players[seat].id
        syncBettingUI(&state)
        updateHeroDisplay(&state)
        return true
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
        // Guests never have `holeCardsByPlayer`; keep cards they fetched into `heroHoleCards`.
        if let dealt = state.holeCardsByPlayer[heroID], dealt.count == 2 {
            state.heroHoleCards = dealt
        }
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
