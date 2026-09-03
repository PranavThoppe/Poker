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
        state.contributions = [:]
        state.handResult = nil
        state.lastAggressorID = nil
        state.pendingRevealPlayerID = nil
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
        state.contributions = [:]
        state.handResult = nil
        state.lastAggressorID = nil
        state.pendingRevealPlayerID = nil
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
                state.lastAggressorID = playerID
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

        if soleRemainingPlayerIndex(&state) != nil {
            distributePots(&state, wentToShowdown: false)
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
            // Nobody else can put chips in (typically only all-ins remain). Close the
            // street instead of leaving `activePlayerID` nil mid-hand.
            if state.activePlayerID == nil {
                if canResolveBettingRound {
                    if anyoneCanAct(state) {
                        recoverStalledHand(&state)
                    } else {
                        resolveCompletedBettingRound(&state)
                    }
                }
            }
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

        distributePots(&state, wentToShowdown: true)
        updateHeroDisplay(&state)
    }

    // MARK: - Pots

    /// Layers the pot at each distinct contribution. Folded players still fund a layer but
    /// are not eligible to win it. Adjacent layers with the same eligible set are merged so
    /// a no-all-in hand is a single pot.
    func buildPots(_ state: GameState) -> [PotAward] {
        let contributions = state.contributions ?? [:]
        if contributions.values.allSatisfy({ $0 <= 0 }), state.pot > 0 {
            let eligible = state.players
                .filter { !$0.isEliminated && !$0.isFolded }
                .map(\.id)
            return [PotAward(
                amount: state.pot,
                eligibleIDs: eligible,
                winnerIDs: [],
                shares: [:],
                isSidePot: false
            )]
        }

        let levels = Set(contributions.values.filter { $0 > 0 }).sorted()
        var layers: [(amount: Int, eligible: [String])] = []
        var previous = 0
        for level in levels {
            let increment = level - previous
            previous = level
            let contributors = contributions.keys.filter { (contributions[$0] ?? 0) >= level }
            let amount = increment * contributors.count
            guard amount > 0 else { continue }
            let eligible = contributors.filter { id in
                guard let player = state.players.first(where: { $0.id == id }) else { return false }
                return !player.isFolded && !player.isEliminated
            }
            layers.append((amount: amount, eligible: eligible))
        }

        var merged: [(amount: Int, eligible: [String])] = []
        for layer in layers {
            if let last = merged.last, Set(last.eligible) == Set(layer.eligible) {
                merged[merged.count - 1].amount += layer.amount
            } else {
                merged.append(layer)
            }
        }

        return merged.enumerated().map { index, layer in
            PotAward(
                amount: layer.amount,
                eligibleIDs: layer.eligible,
                winnerIDs: [],
                shares: [:],
                isSidePot: index > 0
            )
        }
    }

    /// Awards every pot layer, splitting exact ties and giving leftover chips clockwise
    /// from the seat left of the button. Fold-outs skip evaluation and show no cards.
    mutating func distributePots(_ state: inout GameState, wentToShowdown: Bool) {
        let potBefore = state.pot
        let boardCards = state.board.compactMap { $0 }
        var payouts: [String: Int] = [:]
        var awarded: [PotAward] = []

        for layer in buildPots(state) {
            var eligible = layer.eligibleIDs.filter { id in
                guard let player = state.players.first(where: { $0.id == id }) else { return false }
                return !player.isFolded && !player.isEliminated
            }
            if eligible.isEmpty {
                eligible = state.players.filter { !$0.isEliminated && !$0.isFolded }.map(\.id)
            }
            guard !eligible.isEmpty, layer.amount > 0 else { continue }

            let winnerIDs: [String]
            if wentToShowdown, eligible.count > 1 {
                winnerIDs = tiedWinners(eligibleIDs: eligible, board: boardCards, state: state)
            } else {
                winnerIDs = eligible
            }

            let shares = splitAmount(layer.amount, among: winnerIDs, in: state)
            for (id, share) in shares {
                payouts[id, default: 0] += share
            }
            awarded.append(PotAward(
                amount: layer.amount,
                eligibleIDs: layer.eligibleIDs,
                winnerIDs: winnerIDs,
                shares: shares,
                isSidePot: layer.isSidePot
            ))
        }

        #if DEBUG
        let distributed = payouts.values.reduce(0, +)
        assert(distributed == potBefore, "pot leaked: awarded \(distributed) of \(potBefore)")
        #endif

        for (id, share) in payouts {
            if let idx = state.players.firstIndex(where: { $0.id == id }) {
                state.players[idx].stack += share
            }
            var stats = state.handStats[id, default: PlayerHandStats()]
            stats.handsWon += 1
            stats.biggestPot = max(stats.biggestPot, share)
            state.handStats[id] = stats
        }

        var reveals: [RevealedHand] = []

        state.handResult = HandResult(
            pots: awarded,
            payouts: payouts,
            reveals: reveals,
            wentToShowdown: wentToShowdown
        )
        state.pot = 0
        clearStreetBets(&state)

        for i in state.players.indices where state.players[i].stack <= 0 && !state.players[i].isEliminated {
            state.players[i].isEliminated = true
            state.players[i].stack = 0
        }

        if wentToShowdown {
            beginShowdownReveal(&state)
        } else {
            state.pendingRevealPlayerID = nil
            state.activePlayerID = nil
        }
    }

    /// Last aggressor first if they are still in, otherwise first live seat left of the button,
    /// then clockwise among players who did not fold.
    func showdownRevealOrder(_ state: GameState) -> [String] {
        let live = state.players.filter { !$0.isEliminated && !$0.isFolded }.map(\.id)
        guard !live.isEmpty else { return [] }

        let liveSet = Set(live)
        let startID: String
        if let aggressor = state.lastAggressorID, liveSet.contains(aggressor) {
            startID = aggressor
        } else {
            let count = state.players.count
            let dealer = dealerIndex(state)
            startID = (0..<count).compactMap { offset -> String? in
                let id = state.players[(dealer + 1 + offset) % count].id
                return liveSet.contains(id) ? id : nil
            }.first ?? live[0]
        }

        guard let startIndex = state.players.firstIndex(where: { $0.id == startID }) else { return live }
        var ordered: [String] = []
        for offset in 0..<state.players.count {
            let id = state.players[(startIndex + offset) % state.players.count].id
            if liveSet.contains(id) {
                ordered.append(id)
            }
        }
        return ordered
    }

    mutating func beginShowdownReveal(_ state: inout GameState) {
        guard state.handResult?.wentToShowdown == true else {
            state.pendingRevealPlayerID = nil
            state.activePlayerID = nil
            return
        }
        let shown = Set(state.handResult?.reveals.map(\.playerID) ?? [])
        let next = showdownRevealOrder(state).first { !shown.contains($0) }
        state.pendingRevealPlayerID = next
        state.activePlayerID = next
    }

    /// Copies `playerID`'s hole cards into public `handResult.reveals` and advances the queue.
    /// Prefers the host-owned `holeCardsByPlayer` map so a guest cannot spoof a hand.
    @discardableResult
    mutating func applyShowdownReveal(
        _ state: inout GameState,
        playerID: String,
        holeCards: [Card] = []
    ) -> Bool {
        guard state.pendingRevealPlayerID == playerID,
              var result = state.handResult,
              result.wentToShowdown,
              !result.reveals.contains(where: { $0.playerID == playerID })
        else { return false }

        let hole: [Card]
        if let real = state.holeCardsByPlayer[playerID], !real.isEmpty {
            hole = real
        } else if !holeCards.isEmpty {
            hole = holeCards
        } else {
            return false
        }

        let board = state.board.compactMap { $0 }
        let evaluation = HandEvaluator.evaluateBest(from: hole + board)
        result.reveals.append(RevealedHand(
            playerID: playerID,
            holeCards: hole,
            rank: evaluation.rank,
            bestFive: evaluation.bestFive
        ))
        state.handResult = result

        let shown = Set(result.reveals.map(\.playerID))
        let next = showdownRevealOrder(state).first { !shown.contains($0) }
        state.pendingRevealPlayerID = next
        state.activePlayerID = next
        updateHeroDisplay(&state)
        return true
    }

    /// Replaces guest-published hole cards with the host's dealt cards.
    @discardableResult
    mutating func correctShowdownReveals(_ state: inout GameState) -> Bool {
        guard var result = state.handResult, !result.reveals.isEmpty else { return false }
        let board = state.board.compactMap { $0 }
        var changed = false
        for i in result.reveals.indices {
            let id = result.reveals[i].playerID
            guard let real = state.holeCardsByPlayer[id], !real.isEmpty else { continue }
            if result.reveals[i].holeCards != real {
                let evaluation = HandEvaluator.evaluateBest(from: real + board)
                result.reveals[i] = RevealedHand(
                    playerID: id,
                    holeCards: real,
                    rank: evaluation.rank,
                    bestFive: evaluation.bestFive
                )
                changed = true
            }
        }
        if changed {
            state.handResult = result
        }
        return changed
    }

    // MARK: - Private helpers

    private func handScore(for playerID: String, board: [Card], state: GameState) -> HandScore {
        let hole = state.holeCardsByPlayer[playerID] ?? []
        return HandEvaluator.evaluateBest(from: hole + board).score
    }

    private func tiedWinners(eligibleIDs: [String], board: [Card], state: GameState) -> [String] {
        var bestScore: HandScore?
        var winners: [String] = []
        for id in eligibleIDs {
            let score = handScore(for: id, board: board, state: state)
            if let best = bestScore {
                if score > best {
                    bestScore = score
                    winners = [id]
                } else if score == best {
                    winners.append(id)
                }
            } else {
                bestScore = score
                winners = [id]
            }
        }
        return winners
    }

    private func splitAmount(_ amount: Int, among winnerIDs: [String], in state: GameState) -> [String: Int] {
        guard !winnerIDs.isEmpty else { return [:] }
        let base = amount / winnerIDs.count
        var remainder = amount % winnerIDs.count
        var shares = Dictionary(uniqueKeysWithValues: winnerIDs.map { ($0, base) })
        guard remainder > 0 else { return shares }

        for id in clockwiseFromButton(winnerIDs: winnerIDs, in: state) {
            guard remainder > 0 else { break }
            shares[id, default: 0] += 1
            remainder -= 1
        }
        return shares
    }

    /// First live winner left of the button, then clockwise — standard odd-chip order.
    private func clockwiseFromButton(winnerIDs: [String], in state: GameState) -> [String] {
        let winners = Set(winnerIDs)
        let count = state.players.count
        guard count > 0 else { return winnerIDs }
        let start = (dealerIndex(state) + 1) % count
        var ordered: [String] = []
        for offset in 0..<count {
            let id = state.players[(start + offset) % count].id
            if winners.contains(id) {
                ordered.append(id)
            }
        }
        return ordered
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
        var contributions = state.contributions ?? [:]
        contributions[state.players[playerIndex].id, default: 0] += pay
        state.contributions = contributions
        if state.players[playerIndex].currentBet > state.streetBetLevel {
            state.streetBetLevel = state.players[playerIndex].currentBet
        }
    }

    /// Resets everything that is scoped to a single street, including the turn pointer:
    /// a new street always recomputes its own opener rather than inheriting the seat that
    /// closed the previous one (which may have folded or moved all-in).
    private mutating func clearStreetBets(_ state: inout GameState) {
        for i in state.players.indices {
            state.players[i].currentBet = 0
        }
        state.streetBetLevel = 0
        state.actedThisStreet = []
        state.activePlayerID = nil
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

        // Only seats that can still put chips in need to act. All-in players must not
        // keep the round open if they were never copied into `actedThisStreet`.
        let actors = active.filter { canAct($0, state) }
        if actors.isEmpty { return true }

        let level = state.streetBetLevel
        for idx in actors {
            if state.players[idx].currentBet < level { return false }
        }

        let actorIDs = Set(actors.map { state.players[$0].id })
        return actorIDs.isSubset(of: Set(state.actedThisStreet))
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

    private func anyoneCanAct(_ state: GameState) -> Bool {
        state.players.indices.contains { canAct($0, state) }
    }

    /// Puts the action on the opening seat for a street: first live seat left of the button,
    /// falling back to any seat that can still bet. Nil only when everyone left is all-in.
    private mutating func openStreet(_ state: inout GameState) {
        state.activePlayerID = nil
        setFirstToAct(&state, preFlop: false)
        if state.activePlayerID == nil,
           let idx = state.players.indices.first(where: { canAct($0, state) }) {
            state.activePlayerID = state.players[idx].id
        }
    }

    /// Recovery only: re-opens a street whose pointer was lost (a dropped sync write or a
    /// client relaunched mid-hand). Never takes the turn away from a live actor.
    private mutating func ensureStreetHasActor(_ state: inout GameState) {
        guard state.activePlayerID == nil else { return }
        openStreet(&state)
    }

    private mutating func resolveCompletedBettingRound(_ state: inout GameState) {
        guard state.bettingRound == .river else {
            advanceStreet(&state)
            return
        }

        // The river gets a betting round like every other street. Cards are only compared
        // once it closes, or when nobody left has chips to put in.
        if anyoneCanAct(state), !isBettingRoundComplete(&state) {
            ensureStreetHasActor(&state)
            return
        }

        #if DEBUG
        assert(
            state.board.compactMap { $0 }.count == 5,
            "showdown with an incomplete board"
        )
        let owed = state.players.indices.filter {
            canAct($0, state) && !state.actedThisStreet.contains(state.players[$0].id)
        }
        assert(
            owed.isEmpty,
            "showdown while \(owed.count) player(s) still owe a river action: "
                + owed.map { state.players[$0].id }.joined(separator: ",")
        )
        #endif

        resolveShowdown(&state)
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
        guard state.bettingRound != .river else { return }
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
        openStreet(&state)

        // Every remaining player is all-in, so there is no decision left: run the rest of
        // the board out. Keyed on chips rather than on the pointer, so a stale pointer can
        // neither suppress the runout nor stand in for a real betting round.
        if !anyoneCanAct(state) {
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
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        if state.players[idx].isEliminated || state.players[idx].stack <= 0 {
            state.heroHoleCards = []
            state.heroHandRank = nil
            return
        }
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
