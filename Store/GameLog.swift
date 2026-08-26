import Foundation

/// Multiplayer debug logging. Filter the Xcode console with `[Game]`.
/// Classic Poker events are also appended to `game_rooms.debug_log` via Supabase RPC.
enum GameLog {
    private static var sequence = 0
    private static var handNumber = 0
    private static var gameID: UUID?
    private static var isHost = false
    private static var remoteEnabled = false

    // MARK: - Configuration

    static func configure(gameID: UUID, isHost: Bool, classicMultiplayer: Bool) {
        sequence = 0
        handNumber = 0
        self.gameID = gameID
        self.isHost = isHost
        remoteEnabled = classicMultiplayer
    }

    static func clearConfiguration() {
        gameID = nil
        remoteEnabled = false
    }

    // MARK: - Room / session

    static func roomCreated(state: GameState) {
        record("roomCreated", state: state)
    }

    static func roomOpened(state: GameState) {
        record("roomOpened", state: state)
    }

    static func playerJoined(playerID: String, state: GameState) {
        record("playerJoined", state: state, playerID: playerID)
    }

    static func readyChanged(playerID: String, isReady: Bool, state: GameState) {
        record("readyChanged", state: state, playerID: playerID, isReady: isReady)
    }

    static func gameStarted(state: GameState) {
        record("gameStarted", state: state)
    }

    static func phaseChanged(from: GamePhase, to: GamePhase, state: GameState) {
        record("phaseChanged", state: state, phaseFrom: from, phaseTo: to)
        console("phase \(from) → \(to)")
    }

    static func gameEnded(state: GameState) {
        record("gameEnded", state: state)
    }

    static func gameReset(state: GameState) {
        record("gameReset", state: state)
    }

    // MARK: - Hand lifecycle

    static func logHandStarted(state: GameState) {
        handNumber += 1
        record("handStarted", state: state)

        if let dealerID = state.players.first(where: { $0.isDealer })?.id {
            record("dealerAssigned", state: state, playerID: dealerID)
        }

        for player in state.players where !player.isEliminated {
            record("holeCardsDealt", state: state, playerID: player.id, cardCount: 2)
        }

        let blindPlayers = state.players
            .filter { !$0.isEliminated && $0.currentBet > 0 }
            .sorted { $0.currentBet < $1.currentBet }

        if let sb = blindPlayers.first {
            record(
                "smallBlindPosted",
                state: state,
                playerID: sb.id,
                amount: sb.currentBet,
                betAfter: sb.currentBet,
                stackAfter: sb.stack
            )
        }
        if blindPlayers.count >= 2 {
            let bb = blindPlayers[1]
            record(
                "bigBlindPosted",
                state: state,
                playerID: bb.id,
                amount: bb.currentBet,
                betAfter: bb.currentBet,
                stackAfter: bb.stack,
                betToMatch: state.streetBetLevel
            )
        }

        if let activeID = state.activePlayerID {
            record("turnStarted", state: state, playerID: activeID)
        }

        console(handSnapshot(state, label: "handStarted"))
    }

    static func nextHandStarted(state: GameState) {
        record("nextHandStarted", state: state)
        logHandStarted(state: state)
    }

    // MARK: - Player actions

    static func actionRejected(
        playerID: String,
        action: BettingAction,
        reason: String,
        state: GameState
    ) {
        record(
            "actionRejected",
            state: state,
            playerID: playerID,
            reason: reason,
            attempted: action.logKey
        )
        console("rejected \(playerID) \(action.logKey) (\(reason))")
    }

    static func logAcceptedAction(
        playerID: String,
        action: BettingAction,
        before: ActionSnapshot,
        after: GameState
    ) {
        guard let player = after.players.first(where: { $0.id == playerID }) else { return }

        let eventName: String
        let amount: Int?
        switch action {
        case .fold:
            eventName = "playerFolded"
            amount = nil
        case .check:
            eventName = "playerChecked"
            amount = nil
        case .call(let callAmount):
            eventName = "playerCalled"
            amount = callAmount
        case .raise:
            eventName = "playerRaised"
            amount = player.currentBet - before.playerCurrentBet
        }

        record(
            eventName,
            state: after,
            playerID: playerID,
            amount: amount,
            betAfter: player.currentBet,
            stackAfter: player.stack,
            betToMatch: after.streetBetLevel
        )

        if case .raise = action, after.streetBetLevel > before.streetBetLevel {
            record("bettingReopened", state: after, playerID: playerID, betToMatch: after.streetBetLevel)
        }

        logTransitions(before: before, after: after)
        console("\(playerID) → \(action.logKey)")
    }

    /// Street transitions that no player action produced: the host dealing a street after
    /// merging a peer's closing action, or stalled-hand recovery. Without this those deals
    /// were invisible in the log, so a healthy `turn` → `river` looked like a skipped street.
    static func logStreetResolved(before: ActionSnapshot, state: GameState) {
        logTransitions(before: before, after: state)
    }

    /// A hand that cannot be closed because no pot was awarded. Finalizing here would
    /// abandon a live hand into the summary screen with no winner.
    static func handFinalizeBlocked(state: GameState) {
        record("handFinalizeBlocked", state: state)
        console(handSnapshot(state, label: "handFinalizeBlocked"))
    }

    static func logHandResolution(before: ActionSnapshot, state: GameState) {
        let result = state.handResult
        let contenders = state.players.filter { !$0.isEliminated && !$0.isFolded }

        if result?.wentToShowdown == false, let winnerID = state.lastHandWinnerID {
            record("handWonByFold", state: state, playerID: winnerID, winnerID: winnerID)
        } else if contenders.count > 1 || result?.wentToShowdown == true {
            if before.bettingRound == .river {
                record(
                    "streetAdvanced",
                    state: state,
                    streetFrom: .river,
                    streetToLabel: "showdown"
                )
            }
            record("showdownStarted", state: state)
            let board = state.board.compactMap { $0 }
            for player in contenders {
                let hole = state.holeCardsByPlayer[player.id] ?? []
                guard hole.count == 2 else { continue }
                let rank = HandEvaluator.evaluateBest(from: hole + board).rank.logKey
                record("handRankEvaluated", state: state, playerID: player.id, handRank: rank)
            }
            for winnerID in result?.winnerIDs ?? [] {
                record("handWonAtShowdown", state: state, playerID: winnerID, winnerID: winnerID)
            }
        }

        if let pots = result?.pots {
            for pot in pots {
                let potLabel = pot.isSidePot ? "sidePot" : "mainPot"
                if pot.winnerIDs.count > 1 {
                    record(
                        "splitPot",
                        state: state,
                        amount: pot.amount,
                        reason: potLabel,
                        winnerID: pot.winnerIDs.first
                    )
                }
                for winnerID in pot.winnerIDs {
                    record(
                        "potAwarded",
                        state: state,
                        playerID: winnerID,
                        amount: pot.shares[winnerID] ?? 0,
                        reason: potLabel,
                        winnerID: winnerID
                    )
                }
            }
        } else if state.lastPotAwarded > 0, let winnerID = state.lastHandWinnerID {
            record(
                "potAwarded",
                state: state,
                playerID: winnerID,
                amount: state.lastPotAwarded,
                winnerID: winnerID
            )
        }

        for player in state.players where player.isEliminated {
            record("playerEliminated", state: state, playerID: player.id, stackAfter: 0)
        }

        record("handCompleted", state: state, winnerID: state.lastHandWinnerID)
        logTransitions(before: before, after: state)
        console(handSnapshot(state, label: "handCompleted"))
    }

    static func handSummaryOpened(state: GameState) {
        record("handSummaryOpened", state: state)
    }

    // MARK: - Sync

    static func subscriptionStarted(roomID: String) {
        recordSync("subscriptionStarted", roomID: roomID)
    }

    static func subscriptionStopped(roomID: String) {
        recordSync("subscriptionStopped", roomID: roomID)
    }

    static func statePublishStarted(state: GameState) {
        record("statePublishStarted", state: state)
    }

    static func statePublishSucceeded(state: GameState) {
        record("statePublishSucceeded", state: state)
    }

    static func statePublishFailed(state: GameState) {
        record("statePublishFailed", state: state)
    }

    static func remoteStateReceived(state: GameState) {
        record("remoteStateReceived", state: state, activePlayerID: state.activePlayerID)
    }

    static func remoteStateMerged(state: GameState, heroRestored: Bool) {
        record("remoteStateMerged", state: state)
        if heroRestored {
            record("localPlayerRestored", state: state, playerID: state.heroID)
        }
    }

    static func holeCardsStored(playerID: String, cardCount: Int, state: GameState) {
        record("holeCardsStored", state: state, playerID: playerID, cardCount: cardCount)
    }

    static func holeCardsStoreFailed(playerID: String, state: GameState) {
        record("holeCardsStoreFailed", state: state, playerID: playerID)
    }

    static func holeCardsFetched(playerID: String, cardCount: Int, state: GameState) {
        record("holeCardsFetched", state: state, playerID: playerID, cardCount: cardCount)
    }

    static func holeCardsFetchEmpty(playerID: String, state: GameState) {
        record("holeCardsFetchEmpty", state: state, playerID: playerID, cardCount: 0)
    }

    static func holeCardsFetchFailed(playerID: String, state: GameState) {
        record("holeCardsFetchFailed", state: state, playerID: playerID)
    }

    static func showdownDeferredToHost(state: GameState) {
        record("showdownDeferredToHost", state: state)
    }

    static func showdownResolvedByHost(state: GameState) {
        record("showdownResolvedByHost", state: state, winnerID: state.lastHandWinnerID)
    }

    static func cardsShown(playerID: String, state: GameState) {
        record("cardsShown", state: state, playerID: playerID)
    }

    static func showdownAutoShown(playerID: String, state: GameState) {
        record("showdownAutoShown", state: state, playerID: playerID)
    }

    static func showdownAdvanced(playerID: String?, auto: Bool, state: GameState) {
        record(
            auto ? "showdownAutoAdvanced" : "showdownAdvancedByWinner",
            state: state,
            playerID: playerID,
            winnerID: state.lastHandWinnerID
        )
    }

    static func guestContinueBlocked(state: GameState) {
        record("guestContinueBlocked", state: state, playerID: state.heroID)
    }

    // MARK: - Legacy console helpers (practice mode)

    static func snapshot(_ state: GameState, event: String) {
        console(handSnapshot(state, label: event))
    }

    static func potAwarded(amount: Int, winnerID: String) {
        console("pot awarded \(amount) → \(winnerID)")
    }

    static func heroAction(_ action: BettingAction, state: GameState) {
        guard let heroID = state.heroID else { return }
        console("hero \(heroID) → \(action.logKey)")
        console(handSnapshot(state, label: "after hero action"))
    }

    static func playerAction(playerID: String, action: BettingAction, state: GameState) {
        let kind = state.players.first(where: { $0.id == playerID })?.isBot == true ? "bot" : "player"
        console("\(kind) \(playerID) → \(action.logKey)")
    }

    static func phaseChange(from: GamePhase, to: GamePhase, mode: GameMode) {
        console("phase \(from) → \(to) (mode=\(mode.rawValue))")
    }

    // MARK: - Snapshots

    struct ActionSnapshot {
        let bettingRound: BettingRound
        let activePlayerID: String?
        let streetBetLevel: Int
        let pot: Int
        let playerCurrentBet: Int
        let boardCount: Int

        static func capture(from state: GameState, playerID: String) -> ActionSnapshot {
            let bet = state.players.first(where: { $0.id == playerID })?.currentBet ?? 0
            return ActionSnapshot(
                bettingRound: state.bettingRound,
                activePlayerID: state.activePlayerID,
                streetBetLevel: state.streetBetLevel,
                pot: state.pot,
                playerCurrentBet: bet,
                boardCount: state.board.compactMap { $0 }.count
            )
        }
    }

    // MARK: - Private

    private static func logTransitions(before: ActionSnapshot, after: GameState) {
        if before.bettingRound != after.bettingRound {
            record(
                "bettingRoundCompleted",
                state: after,
                streetFrom: before.bettingRound,
                streetTo: after.bettingRound
            )
            record(
                "streetAdvanced",
                state: after,
                streetFrom: before.bettingRound,
                streetTo: after.bettingRound
            )

            let cardsDealt = after.board.compactMap { $0 }.count - before.boardCount
            if cardsDealt > 0 {
                record("communityCardsDealt", state: after, cardCount: cardsDealt)
            }
        }

        if before.activePlayerID != after.activePlayerID, let nextID = after.activePlayerID {
            let event = before.activePlayerID == nil ? "turnStarted" : "turnAdvanced"
            record(event, state: after, playerID: nextID)
        }
    }

    private static func record(
        _ event: String,
        state: GameState,
        playerID: String? = nil,
        amount: Int? = nil,
        betAfter: Int? = nil,
        stackAfter: Int? = nil,
        betToMatch: Int? = nil,
        reason: String? = nil,
        attempted: String? = nil,
        cardCount: Int? = nil,
        handRank: String? = nil,
        winnerID: String? = nil,
        isReady: Bool? = nil,
        phaseFrom: GamePhase? = nil,
        phaseTo: GamePhase? = nil,
        streetFrom: BettingRound? = nil,
        streetTo: BettingRound? = nil,
        streetToLabel: String? = nil,
        activePlayerID: String? = nil
    ) {
        #if DEBUG
        sequence += 1
        let payload = DebugLogEvent(
            event: event,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: sequence,
            game_id: (gameID ?? state.gameID).uuidString,
            device_id: ProfileService.deviceID,
            device_role: isHost ? "host" : "guest",
            player_id: playerID,
            hand_number: handNumber,
            street: streetKey(state.bettingRound),
            pot: state.pot,
            phase: phaseKey(state.phase),
            active_player_id: activePlayerID ?? state.activePlayerID,
            amount: amount,
            bet_after: betAfter,
            stack_after: stackAfter,
            bet_to_match: betToMatch ?? state.streetBetLevel,
            reason: reason,
            attempted: attempted,
            card_count: cardCount,
            hand_rank: handRank,
            winner_id: winnerID,
            is_ready: isReady,
            phase_from: phaseFrom.map(phaseKey),
            phase_to: phaseTo.map(phaseKey),
            street_from: streetFrom.map(streetKey),
            street_to: streetToLabel ?? streetTo.map(streetKey)
        )

        console("\(event) seq=\(sequence) hand=\(handNumber) street=\(payload.street) pot=\(state.pot)")

        guard remoteEnabled, state.gameMode == .classicPoker else { return }
        appendRemote(payload)
        #endif
    }

    private static func recordSync(_ event: String, roomID: String) {
        #if DEBUG
        sequence += 1
        let payload = DebugLogEvent(
            event: event,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: sequence,
            game_id: roomID,
            device_id: ProfileService.deviceID,
            device_role: isHost ? "host" : "guest",
            player_id: nil,
            hand_number: handNumber,
            street: "preFlop",
            pot: 0,
            phase: nil,
            active_player_id: nil,
            amount: nil,
            bet_after: nil,
            stack_after: nil,
            bet_to_match: nil,
            reason: nil,
            attempted: nil,
            card_count: nil,
            hand_rank: nil,
            winner_id: nil,
            is_ready: nil,
            phase_from: nil,
            phase_to: nil,
            street_from: nil,
            street_to: nil
        )
        console("\(event) seq=\(sequence)")
        guard remoteEnabled else { return }
        appendRemote(payload)
        #endif
    }

    private static func appendRemote(_ payload: DebugLogEvent) {
        struct RPCBody: Encodable {
            let p_room_id: String
            let p_event: DebugLogEvent
        }
        let body = RPCBody(p_room_id: payload.game_id, p_event: payload)
        Task {
            try? await SupabaseClient.shared.rpc("append_debug_event", body: body)
        }
    }

    private static func console(_ message: String) {
        #if DEBUG
        print("[Game] \(message)")
        #endif
    }

    private static func handSnapshot(_ state: GameState, label: String) -> String {
        let active = state.activePlayerID ?? "nil"
        let dealer = state.players.first(where: { $0.isDealer })?.id ?? "nil"
        var line =
            "\(label) | players=\(state.players.count) pot=\(state.pot) "
            + "street=\(state.bettingRound.displayName) active=\(active) "
            + "phase=\(state.phase) dealer=\(dealer)"
        if let result = state.handResult, result.totalAwarded > 0 {
            line += " lastPot=\(result.totalAwarded) winners=\(result.winnerIDs.joined(separator: ","))"
        }
        return line
    }

    private static func streetKey(_ round: BettingRound) -> String {
        switch round {
        case .preFlop: return "preFlop"
        case .flop: return "flop"
        case .turn: return "turn"
        case .river: return "river"
        }
    }

    private static func phaseKey(_ phase: GamePhase) -> String {
        switch phase {
        case .waiting: return "waiting"
        case .playing: return "playing"
        case .showdown: return "showdown"
        case .handSummary: return "handSummary"
        case .ended: return "ended"
        }
    }
}

// MARK: - Remote payload

private struct DebugLogEvent: Encodable {
    let event: String
    let timestamp: String
    let sequence: Int
    let game_id: String
    let device_id: String
    let device_role: String
    let player_id: String?
    let hand_number: Int
    let street: String
    let pot: Int
    let phase: String?
    let active_player_id: String?
    let amount: Int?
    let bet_after: Int?
    let stack_after: Int?
    let bet_to_match: Int?
    let reason: String?
    let attempted: String?
    let card_count: Int?
    let hand_rank: String?
    let winner_id: String?
    let is_ready: Bool?
    let phase_from: String?
    let phase_to: String?
    let street_from: String?
    let street_to: String?
}

private extension HandRank {
    var logKey: String {
        switch self {
        case .highCard: return "highCard"
        case .pair: return "pair"
        case .twoPair: return "twoPair"
        case .threeOfAKind: return "threeOfAKind"
        case .straight: return "straight"
        case .flush: return "flush"
        case .fullHouse: return "fullHouse"
        case .fourOfAKind: return "fourOfAKind"
        case .straightFlush: return "straightFlush"
        case .royalFlush: return "royalFlush"
        }
    }
}

private extension BettingAction {
    var logKey: String {
        switch self {
        case .fold: return "fold"
        case .check: return "check"
        case .call: return "call"
        case .raise: return "raise"
        }
    }
}
