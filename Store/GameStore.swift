import Foundation
import Combine

@MainActor
final class GameStore: ObservableObject {
    @Published var state: GameState

    /// Sync backend; replaced with `SupabaseSync()` for classic multiplayer sessions.
    var syncer: GameSyncing = MockSync()
    /// True on the device that created the game room (runs the engine authoritatively).
    var isHost: Bool = false

    private var engine = PokerEngine()
    private let botScheduler = BotTurnScheduler()
    private var botSessionConfig = BotSessionConfig.default
    private var botStrategy: BotStrategy = makeStrategy(for: .default)
    private var holeCardRetryTask: Task<Void, Never>?
    private var stalledHandTask: Task<Void, Never>?
    private var showdownTimeoutTask: Task<Void, Never>?
    private var showdownAdvanceTask: Task<Void, Never>?
    private var lastShowdownTimeoutID: String?
    private var isFetchingHoleCards = false
    private var isRestoringHostHoleCards = false
    /// Consecutive watchdog ticks with nobody on the clock.
    private var stalledPollTicks = 0

    /// How long the winner has to leave the showdown table up before it advances itself.
    static let showdownAdvanceSeconds: TimeInterval = 10

    init(state: GameState = GameState()) {
        self.state = state
    }

    deinit {
        holeCardRetryTask?.cancel()
        stalledHandTask?.cancel()
        showdownTimeoutTask?.cancel()
        showdownAdvanceTask?.cancel()
    }

    /// New waiting-room session; `gameID` is embedded in the iMessage bubble URL.
    static func createNew(mode: GameMode = .classicPoker) -> GameState {
        var state = GameState()
        state.gameID = UUID()
        state.gameMode = mode
        state.phase = .waiting
        if mode == .classicPoker {
            state.hostID = ProfileService.deviceID
        }
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

    func joinGame(playerID: String, name: String, avatarIndex: Int = 0) {
        if let existing = state.players.firstIndex(where: { $0.id == playerID }) {
            if state.heroID == nil {
                state.heroID = state.players[existing].id
            }
            return
        }
        state.players.append(Player(id: playerID, name: name, stack: PokerEngine.startingStack, avatarIndex: avatarIndex))
        if state.heroID == nil {
            state.heroID = playerID
        }
        GameLog.playerJoined(playerID: playerID, state: state)
        if isHost { publishCurrentState() }
    }

    // MARK: - Ready state

    func toggleReady() {
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        if state.phase == .handSummary {
            guard !state.players[idx].isEliminated, state.players[idx].stack > 0 else { return }
        }
        state.players[idx].isReady.toggle()
        GameLog.readyChanged(
            playerID: heroID,
            isReady: state.players[idx].isReady,
            state: state
        )
        publishCurrentState()
    }

    func startGame() {
        guard !state.players.isEmpty else { return }
        guard state.gameMode != .classicPoker || isHost else { return }
        if state.gameMode == .practiceVsCPU {
            seedBots()
        }
        let previousPhase = state.phase
        engine.startGame(&state)
        engine.startHand(&state)
        if previousPhase == .waiting {
            GameLog.gameStarted(state: state)
        }
        GameLog.logHandStarted(state: state)
        beginHandPhase(from: previousPhase)
        if state.gameMode == .classicPoker {
            Task { [weak self] in
                guard let self,
                      await self.writeHoleCardsToSupabase() else { return }
                self.publishCurrentState()
            }
        } else {
            publishCurrentState()
        }
        scheduleBotTurnIfNeeded()
        scheduleBotShowIfNeeded()
    }

    var allReady: Bool {
        !state.players.isEmpty && state.players.allSatisfy { $0.isReady }
    }

    var canStartGame: Bool {
        allReady && (state.gameMode != .classicPoker || isHost)
    }

    var playersRequiredToReadyForNextHand: [Player] {
        state.players.filter { !$0.isEliminated && $0.stack > 0 }
    }

    var allReadyForNextHand: Bool {
        let players = playersRequiredToReadyForNextHand
        return !players.isEmpty && players.allSatisfy(\.isReady)
    }

    var canStartNextHand: Bool {
        state.phase == .handSummary
            && !sessionEndsAfterHandSummary
            && allReadyForNextHand
            && (state.gameMode != .classicPoker || isHost)
    }

    var isHeroTurn: Bool {
        guard let heroID = state.heroID else { return false }
        return state.activePlayerID == heroID
    }

    var showdownRevealOrder: [String] {
        engine.showdownRevealOrder(state)
    }

    /// The player who closes the showdown table once every hand is face up. Taking the first
    /// winner keeps the choice on the same seat on every device, including split pots.
    var showdownDeciderID: String? {
        guard state.phase == .showdown,
              state.pendingRevealPlayerID == nil,
              !(state.handResult?.reveals.isEmpty ?? true) else { return nil }
        return state.handResult?.winnerIDs.first
    }

    var isHeroShowdownDecider: Bool {
        guard let deciderID = showdownDeciderID, let heroID = state.heroID else { return false }
        return deciderID == heroID
    }

    private func beginHandPhase(from previousPhase: GamePhase) {
        if state.handResult?.wentToShowdown == true {
            enterShowdown()
        } else if state.lastHandWinnerID != nil {
            finalizeHandIfNeeded()
        } else {
            state.phase = .playing
            GameLog.phaseChanged(from: previousPhase, to: .playing, state: state)
        }
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

    func showCards(for playerID: String? = nil, auto: Bool = false) {
        guard state.phase == .showdown else { return }
        guard let id = playerID ?? state.heroID else { return }
        // Classic guests may only show themselves. Practice owns every bot locally.
        if state.gameMode == .classicPoker, !isHost, id != state.heroID { return }

        let cards: [Card]
        if let real = state.holeCardsByPlayer[id], !real.isEmpty {
            cards = real
        } else if id == state.heroID {
            cards = state.heroHoleCards
        } else {
            cards = []
        }

        guard engine.applyShowdownReveal(&state, playerID: id, holeCards: cards) else { return }
        GameLog.cardsShown(playerID: id, state: state)
        if auto {
            GameLog.showdownAutoShown(playerID: id, state: state)
        }

        if state.pendingRevealPlayerID == nil {
            lastShowdownTimeoutID = nil
            publishCurrentState()
            showdownTimeoutTask?.cancel()
            scheduleShowdownAdvanceIfNeeded()
        } else {
            lastShowdownTimeoutID = nil
            scheduleBotShowIfNeeded()
            restartShowdownTimeout()
            publishCurrentState()
        }
    }

    /// Leaves the showdown table for the hand summary. In classic, only the winner may do this
    /// by hand; `auto` is the countdown fallback, a bot-won pot, or the host covering an absent
    /// winner. Practice always lets the human advance so they pace the table themselves.
    func advanceToHandSummary(auto: Bool = false) {
        guard state.phase == .showdown, showdownDeciderID != nil else { return }
        let practiceHeroMayAdvance = state.gameMode == .practiceVsCPU && state.heroID != nil
        guard auto || isHeroShowdownDecider || practiceHeroMayAdvance else { return }
        GameLog.showdownAdvanced(playerID: showdownDeciderID, auto: auto, state: state)
        finishShowdownToSummary()
    }

    // MARK: - End game / navigation

    func endGame() {
        let previousPhase = state.phase
        state.phase = .ended
        state.endStats = buildStats()
        GameLog.phaseChanged(from: previousPhase, to: .ended, state: state)
        GameLog.gameEnded(state: state)
        publishCurrentState()
    }

    func continueAfterHandSummary() {
        guard state.phase == .handSummary else { return }
        if state.gameMode == .classicPoker {
            guard isHost else {
                GameLog.guestContinueBlocked(state: state)
                return
            }
            guard sessionEndsAfterHandSummary || allReadyForNextHand else { return }
        }
        if engine.shouldEndGame(state) {
            endGame()
        } else {
            engine.startHand(&state)
            let previousPhase = state.phase
            GameLog.nextHandStarted(state: state)
            beginHandPhase(from: previousPhase)
            if state.gameMode == .classicPoker {
                Task { [weak self] in
                    guard let self,
                          await self.writeHoleCardsToSupabase() else { return }
                    self.publishCurrentState()
                }
            } else {
                publishCurrentState()
            }
            scheduleBotTurnIfNeeded()
            scheduleBotShowIfNeeded()
        }
    }

    var sessionEndsAfterHandSummary: Bool {
        engine.shouldEndGame(state)
    }

    func resetToWaiting() {
        botScheduler.cancel()
        showdownTimeoutTask?.cancel()
        cancelShowdownAdvance()
        let previousPhase = state.phase
        var fresh = GameState()
        fresh.phase = .waiting
        fresh.gameID = state.gameID
        fresh.hostID = state.hostID
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
        // Keep the counter climbing so peers do not reject the reset as a stale write.
        fresh.stateVersion = state.version
        state = fresh
        GameLog.phaseChanged(from: previousPhase, to: .waiting, state: state)
        GameLog.gameReset(state: state)
        publishCurrentState()
    }

    /// Configures remote debug logging for a Classic Poker room session.
    func configureDebugLogging() {
        guard state.gameMode == .classicPoker else { return }
        GameLog.configure(gameID: state.gameID, isHost: isHost, classicMultiplayer: true)
    }

    // MARK: - Multiplayer sync

    /// Starts the Supabase polling loop for the current game room.
    /// Call after setting `syncer` and `isHost`, once `state.gameID` is known.
    func subscribeToRoom() {
        configureDebugLogging()
        startRoomSubscription()
        startHoleCardRetryLoop()
        startStalledHandWatchdog()
    }

    /// (Re)starts the poll loop. Restarting clears the syncer's de-duplication state, so the
    /// next tick re-merges the server's current row even if we already saw that version.
    private func startRoomSubscription() {
        let roomID = state.gameID.uuidString
        syncer.subscribe(roomID: roomID) { [weak self] remoteState, remoteHostID in
            guard let self else { return }

            let heroAbsent: Bool
            if let heroID = self.state.heroID {
                heroAbsent = !remoteState.players.contains(where: { $0.id == heroID })
            } else {
                heroAbsent = false
            }

            self.mergeRemoteState(remoteState, remoteHostID: remoteHostID)

            if heroAbsent {
                self.publishCurrentState()
            }

            if self.isHost,
               self.state.phase == .playing,
               self.state.activePlayerID == nil {
                self.resolveHostPendingState()
            }

            self.stalledPollTicks = 0
        }
    }

    /// Fire-and-forget publish of the current state. No-op in practice mode.
    func publishCurrentState() {
        guard state.gameMode == .classicPoker else { return }
        guard state.hostID != nil else { return }
        state.stateVersion = state.version + 1
        syncer.publish(state: state, roomID: state.gameID.uuidString)
    }

    // MARK: - Private

    private func apply(_ action: BettingAction) {
        guard let heroID = state.heroID else { return }
        applyAction(for: heroID, action: action)
    }

    private func applyAction(for playerID: String, action: BettingAction) {
        guard state.phase == .playing else {
            GameLog.actionRejected(playerID: playerID, action: action, reason: "wrongPhase", state: state)
            return
        }

        let before = GameLog.ActionSnapshot.capture(from: state, playerID: playerID)
        let canResolveBettingRound = state.gameMode != .classicPoker || isHost
        guard engine.applyAction(
            &state,
            playerID: playerID,
            action: action,
            canResolveBettingRound: canResolveBettingRound
        ) else {
            let reason = rejectionReason(for: playerID, action: action)
            GameLog.actionRejected(playerID: playerID, action: action, reason: reason, state: state)
            return
        }

        if state.gameMode == .practiceVsCPU {
            if playerID == state.heroID {
                GameLog.heroAction(action, state: state)
            } else {
                GameLog.playerAction(playerID: playerID, action: action, state: state)
                GameLog.snapshot(state, event: "after bot action")
            }
        } else {
            GameLog.logAcceptedAction(playerID: playerID, action: action, before: before, after: state)
        }

        if let result = state.handResult, state.phase == .playing {
            if result.wentToShowdown {
                enterShowdown(before: before)
            } else {
                finalizeHandIfNeeded(before: before)
            }
        } else if state.activePlayerID == nil {
            finalizeHandIfNeeded(before: before)
        } else {
            scheduleBotTurnIfNeeded()
        }
        publishCurrentState()
    }

    private func finalizeHandIfNeeded(before: GameLog.ActionSnapshot? = nil, fromRemotePoll: Bool = false) {
        // Only guests defer. A host missing its card map (relaunched mid-hand) must still
        // close the hand, or the table sits forever with nobody on the clock.
        if state.gameMode == .classicPoker && !isHost && state.holeCardsByPlayer.isEmpty {
            GameLog.showdownDeferredToHost(state: state)
            return
        }

        if fromRemotePoll {
            GameLog.showdownResolvedByHost(state: state)
        }

        let snapshot = before ?? GameLog.ActionSnapshot.capture(
            from: state,
            playerID: state.activePlayerID ?? state.heroID ?? ""
        )
        GameLog.logHandResolution(before: snapshot, state: state)

        botScheduler.cancel()
        state.endStats = buildHandSummaryStats()
        let previousPhase = state.phase
        resetReadyStateForHandSummary()
        state.phase = .handSummary
        GameLog.phaseChanged(from: previousPhase, to: .handSummary, state: state)
        GameLog.handSummaryOpened(state: state)
    }

    private func enterShowdown(before: GameLog.ActionSnapshot? = nil, fromRemotePoll: Bool = false) {
        guard state.phase != .showdown else { return }
        if state.gameMode == .classicPoker && !isHost && state.holeCardsByPlayer.isEmpty {
            GameLog.showdownDeferredToHost(state: state)
            return
        }
        if fromRemotePoll {
            GameLog.showdownResolvedByHost(state: state)
        }

        let snapshot = before ?? GameLog.ActionSnapshot.capture(
            from: state,
            playerID: state.activePlayerID ?? state.heroID ?? ""
        )
        GameLog.logHandResolution(before: snapshot, state: state)

        engine.beginShowdownReveal(&state)
        botScheduler.cancel()
        cancelShowdownAdvance()
        state.endStats = buildHandSummaryStats()
        let previousPhase = state.phase
        state.phase = .showdown
        GameLog.phaseChanged(from: previousPhase, to: .showdown, state: state)
        scheduleBotShowIfNeeded()
        restartShowdownTimeout()
    }

    /// Arms the fallback that closes the showdown table if the winner never taps Continue.
    /// Practice waits indefinitely for the human. Classic: a bot winner advances on its think
    /// delay; a human winner's device runs the countdown, and the host waits a little longer
    /// in case that winner has dropped.
    private func scheduleShowdownAdvanceIfNeeded() {
        guard state.gameMode != .practiceVsCPU else { return }
        guard let deciderID = showdownDeciderID else { return }

        if isBot(deciderID) {
            botScheduler.schedule { [weak self] in
                self?.advanceToHandSummary(auto: true)
            }
            return
        }

        let isHeroDecider = deciderID == state.heroID
        guard isHeroDecider || isHost else { return }
        guard showdownAdvanceTask == nil else { return }

        let delay = isHeroDecider ? Self.showdownAdvanceSeconds : Self.showdownAdvanceSeconds + 4
        showdownAdvanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.showdownAdvanceTask = nil
            self.advanceToHandSummary(auto: true)
        }
    }

    private func cancelShowdownAdvance() {
        showdownAdvanceTask?.cancel()
        showdownAdvanceTask = nil
    }

    private func finishShowdownToSummary() {
        guard state.phase == .showdown else { return }
        showdownTimeoutTask?.cancel()
        cancelShowdownAdvance()
        botScheduler.cancel()
        let previousPhase = state.phase
        resetReadyStateForHandSummary()
        state.phase = .handSummary
        GameLog.phaseChanged(from: previousPhase, to: .handSummary, state: state)
        GameLog.handSummaryOpened(state: state)
        publishCurrentState()
    }

    private func resetReadyStateForHandSummary() {
        guard state.gameMode == .classicPoker else { return }
        for index in state.players.indices {
            state.players[index].isReady = false
        }
    }

    private func rejectionReason(for playerID: String, action: BettingAction) -> String {
        guard state.phase == .playing else { return "wrongPhase" }
        guard state.activePlayerID == playerID else { return "notPlayersTurn" }
        guard let idx = state.players.firstIndex(where: { $0.id == playerID }) else { return "notPlayersTurn" }
        let player = state.players[idx]
        if player.isFolded { return "playerFolded" }
        if player.isEliminated { return "playerEliminated" }

        switch action {
        case .check:
            if player.currentBet != state.streetBetLevel { return "checkFacingBet" }
        case .call(let amount):
            let toCall = state.streetBetLevel - player.currentBet
            if toCall <= 0 { return "callNotRequired" }
            if player.stack <= 0 { return "playerAllIn" }
            if amount < min(toCall, player.stack) { return "callTooSmall" }
        case .raise(let targetTotal):
            if targetTotal <= state.streetBetLevel { return "raiseNotHigher" }
            let needed = targetTotal - player.currentBet
            if needed <= 0 || needed > player.stack { return "raiseExceedsStack" }
        case .fold:
            break
        }
        return "illegal"
    }

    private func scheduleBotTurnIfNeeded() {
        guard state.gameMode == .practiceVsCPU,
              let id = state.activePlayerID,
              isBot(id) else { return }
        botScheduler.schedule { [weak self] in
            self?.performBotTurn(playerID: id)
        }
    }

    private func scheduleBotShowIfNeeded() {
        guard state.phase == .showdown,
              let id = state.pendingRevealPlayerID,
              isBot(id) else { return }
        botScheduler.schedule { [weak self] in
            self?.showCards(for: id)
        }
    }

    private func restartShowdownTimeout() {
        let id = state.pendingRevealPlayerID
        if id == lastShowdownTimeoutID, showdownTimeoutTask != nil { return }
        lastShowdownTimeoutID = id
        showdownTimeoutTask?.cancel()
        guard state.phase == .showdown,
              let id,
              !isBot(id) else { return }
        showdownTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            guard self.state.phase == .showdown,
                  self.state.pendingRevealPlayerID == id else { return }
            if self.isHost {
                self.showCards(for: id, auto: true)
            } else if id == self.state.heroID {
                self.showCards(for: id, auto: true)
            }
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

    /// Merges a remote `GameState` into local state while preserving per-client private data:
    /// the hero's identity, their hole cards, and the host's full `holeCardsByPlayer` map.
    /// Public fields including `handResult` come from remote (version-wins).
    private func mergeRemoteState(_ remote: GameState, remoteHostID: String?) {
        var remote = remote
        if remote.hostID == nil {
            remote.hostID = remoteHostID
        }
        if let hostID = remote.hostID {
            isHost = hostID == ProfileService.deviceID
        }

        guard let heroID = state.heroID else {
            state = remote
            engine.syncBettingUI(&state)
            engine.updateHeroDisplay(&state)
            GameLog.remoteStateMerged(state: state, heroRestored: false)
            return
        }
        let heroPlayer       = state.players.first(where: { $0.id == heroID })
        let savedHeroCards   = state.heroHoleCards
        let savedHoleCards   = state.holeCardsByPlayer
        let savedDeck        = state.remainingDeck
        let isNewHand        = state.handID != remote.handID
        let heroWasMissing   = !remote.players.contains(where: { $0.id == heroID })

        state = remote
        state.heroID = heroID

        if isNewHand {
            // Drop the previous hand's private cards so the guest fetches the new deal.
            if !isHost {
                state.heroHoleCards = []
            } else if !savedHeroCards.isEmpty {
                state.heroHoleCards = savedHeroCards
            }
        } else if !savedHeroCards.isEmpty {
            state.heroHoleCards = savedHeroCards
        }

        if isHost {
            state.holeCardsByPlayer = savedHoleCards
            if !savedDeck.isEmpty {
                state.remainingDeck = savedDeck
            }
        }

        if heroWasMissing, let hero = heroPlayer {
            state.players.append(hero)
        }

        engine.syncBettingUI(&state)
        engine.updateHeroDisplay(&state)
        GameLog.remoteStateMerged(state: state, heroRestored: heroWasMissing)

        if isHost, engine.correctShowdownReveals(&state) {
            publishCurrentState()
        }

        if (state.phase == .playing || state.phase == .showdown), state.heroHoleCards.isEmpty {
            fetchHeroHoleCards()
        }
        if state.phase == .showdown {
            scheduleBotShowIfNeeded()
            restartShowdownTimeout()
            scheduleShowdownAdvanceIfNeeded()
        } else {
            // Another device already moved the table on, so drop our own fallback.
            cancelShowdownAdvance()
        }
        // Recover before the next street is dealt, so the rebuilt deck knows which cards
        // are already in players' hands.
        if isHost, (state.phase == .playing || state.phase == .showdown), state.holeCardsByPlayer.isEmpty {
            restoreHostHoleCards()
        }
    }

    private func resolveHostPendingState() {
        if state.phase == .showdown { return }

        if state.handResult?.wentToShowdown == true, state.phase == .playing {
            enterShowdown(fromRemotePoll: true)
            publishCurrentState()
            return
        }

        if state.lastHandWinnerID != nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
            publishCurrentState()
            return
        }

        guard engine.resolvePendingBettingRound(&state) else { return }
        if state.handResult?.wentToShowdown == true {
            enterShowdown(fromRemotePoll: true)
        } else if state.activePlayerID == nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
        }
        publishCurrentState()
    }

    /// Watches for a table with nobody on the clock. A lost or overwritten publish used to
    /// leave both devices waiting on each other with no way back, since resolution only ran
    /// inside the poll callback for the update that went missing.
    private func startStalledHandWatchdog() {
        stalledHandTask?.cancel()
        stalledHandTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.recoverStalledHandIfNeeded()
            }
        }
    }

    private func recoverStalledHandIfNeeded() {
        guard state.gameMode == .classicPoker else {
            stalledPollTicks = 0
            return
        }
        if state.phase == .showdown {
            if isHost, state.holeCardsByPlayer.isEmpty {
                restoreHostHoleCards()
            }
            if state.pendingRevealPlayerID == nil,
               !(state.handResult?.reveals.isEmpty ?? true) {
                stalledPollTicks = 0
                if showdownDeciderID != nil {
                    // Every hand is face up, so the winner owns the table: only re-arm the
                    // fallback instead of yanking the screen away from them.
                    scheduleShowdownAdvanceIfNeeded()
                } else if isHost {
                    finishShowdownToSummary()
                }
                return
            }
            stalledPollTicks += 1
            if isHost, stalledPollTicks >= 2, let id = state.pendingRevealPlayerID {
                stalledPollTicks = 0
                showCards(for: id, auto: true)
            }
            return
        }
        guard state.phase == .playing else {
            stalledPollTicks = 0
            return
        }
        if isHost, state.holeCardsByPlayer.isEmpty {
            restoreHostHoleCards()
        }
        guard state.activePlayerID == nil else {
            stalledPollTicks = 0
            return
        }
        stalledPollTicks += 1

        guard isHost else {
            // A guest waiting on the host to resolve a round is normal for a poll cycle or
            // two. Longer means our own write never landed, so re-merge the server's row:
            // it either hands the turn back or carries the street we missed.
            guard stalledPollTicks >= 3 else { return }
            stalledPollTicks = 0
            GameLog.snapshot(state, event: "guest resync after stalled hand")
            startRoomSubscription()
            return
        }

        if state.handResult?.wentToShowdown == true {
            enterShowdown(fromRemotePoll: true)
            publishCurrentState()
            return
        }
        if state.lastHandWinnerID != nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
            publishCurrentState()
            return
        }
        guard engine.recoverStalledHand(&state) else { return }
        GameLog.snapshot(state, event: "recovered stalled hand")
        if state.handResult?.wentToShowdown == true {
            enterShowdown(fromRemotePoll: true)
        } else if state.activePlayerID == nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
        }
        publishCurrentState()
    }

    /// Re-reads every seat's hole cards so a host that lost them (extension relaunch) can
    /// still deal the remaining streets and run the showdown.
    private func restoreHostHoleCards() {
        guard let supabaseSync = syncer as? SupabaseSync, !isRestoringHostHoleCards else { return }
        isRestoringHostHoleCards = true
        let roomID = state.gameID.uuidString
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRestoringHostHoleCards = false }
            guard let cards = try? await supabaseSync.fetchAllHoleCards(roomID: roomID),
                  !cards.isEmpty else { return }
            self.state.holeCardsByPlayer = cards
            self.engine.updateHeroDisplay(&self.state)
            if self.engine.correctShowdownReveals(&self.state) {
                self.publishCurrentState()
            }
            GameLog.snapshot(self.state, event: "host hole cards restored")
        }
    }

    private func startHoleCardRetryLoop() {
        holeCardRetryTask?.cancel()
        holeCardRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if (self.state.phase == .playing || self.state.phase == .showdown)
                    && self.state.heroHoleCards.isEmpty {
                    self.fetchHeroHoleCards()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Fetches the hero's hole cards from `player_hole_cards` and stores them locally.
    /// Retried on every poll tick until the host has written them.
    private func fetchHeroHoleCards() {
        guard let heroID = state.heroID,
              let supabaseSync = syncer as? SupabaseSync,
              !isFetchingHoleCards else { return }
        isFetchingHoleCards = true
        let roomID = state.gameID.uuidString
        let handID = state.handID
        Task { [weak self] in
            guard let self else { return }
            var shouldRefetch = false
            defer {
                self.isFetchingHoleCards = false
                if shouldRefetch {
                    self.fetchHeroHoleCards()
                }
            }
            do {
                if let cards = try await supabaseSync.fetchHoleCards(roomID: roomID, playerID: heroID) {
                    if cards.isEmpty {
                        GameLog.holeCardsFetchEmpty(playerID: heroID, state: self.state)
                    } else if self.state.handID != handID {
                        shouldRefetch = (self.state.phase == .playing || self.state.phase == .showdown)
                            && self.state.heroHoleCards.isEmpty
                    } else {
                        self.state.heroHoleCards = cards
                        self.engine.updateHeroDisplay(&self.state)
                        GameLog.holeCardsFetched(
                            playerID: heroID,
                            cardCount: cards.count,
                            state: self.state
                        )
                    }
                } else {
                    GameLog.holeCardsFetchEmpty(playerID: heroID, state: self.state)
                }
            } catch {
                GameLog.holeCardsFetchFailed(playerID: heroID, state: self.state)
            }
        }
    }

    private func writeHoleCardsToSupabase() async -> Bool {
        guard let supabaseSync = syncer as? SupabaseSync else { return false }
        let holeCards = state.holeCardsByPlayer
        let roomID    = state.gameID.uuidString
        var allStored = true

        for (playerID, cards) in holeCards {
            var stored = false
            for attempt in 1...3 {
                do {
                    try await supabaseSync.upsertHoleCards(roomID: roomID, playerID: playerID, cards: cards)
                    GameLog.holeCardsStored(
                        playerID: playerID,
                        cardCount: cards.count,
                        state: state
                    )
                    stored = true
                    break
                } catch {
                    if attempt == 3 {
                        GameLog.holeCardsStoreFailed(playerID: playerID, state: state)
                    } else {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            allStored = allStored && stored
        }
        return allStored
    }

    private func buildHandSummaryStats() -> [PlayerStats] {
        let winnerIDs = Set(state.handResult?.winnerIDs ?? [])
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
                isWinner: winnerIDs.contains(p.id)
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

    static var mockShowdown: GameStore {
        var state = GameState()
        state.phase = .showdown
        state.handID = UUID()
        state.bettingRound = .river
        state.players = [
            Player(id: "hero", name: "You", stack: 520, avatarIndex: 0),
            Player(id: "bot-1", name: "CPU 1", stack: 480, isFolded: true, avatarIndex: 1, isBot: true),
            Player(id: "bot-2", name: "CPU 2", stack: 500, isDealer: true, avatarIndex: 2, isBot: true),
        ]
        state.heroID = "hero"
        state.heroHoleCards = [Card(rank: .ace, suit: .spades), Card(rank: .king, suit: .hearts)]
        state.heroHandRank = .pair
        state.board = [
            Card(rank: .ace, suit: .hearts),
            Card(rank: .queen, suit: .clubs),
            Card(rank: .ten, suit: .diamonds),
            Card(rank: .four, suit: .spades),
            Card(rank: .three, suit: .clubs)
        ]
        state.pendingRevealPlayerID = "hero"
        state.activePlayerID = "hero"
        state.lastAggressorID = "hero"
        state.handResult = HandResult(
            pots: [PotAward(
                amount: 40,
                eligibleIDs: ["hero", "bot-2"],
                winnerIDs: ["hero"],
                shares: ["hero": 40],
                isSidePot: false
            )],
            payouts: ["hero": 40],
            reveals: [],
            wentToShowdown: true
        )
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
        state.handID = UUID()
        state.handResult = HandResult(
            pots: [PotAward(
                amount: 40,
                eligibleIDs: ["hero", "bot-1"],
                winnerIDs: ["hero"],
                shares: ["hero": 40],
                isSidePot: false
            )],
            payouts: ["hero": 40],
            reveals: [
                RevealedHand(
                    playerID: "hero",
                    holeCards: [Card(rank: .ace, suit: .spades), Card(rank: .king, suit: .hearts)],
                    rank: .pair,
                    bestFive: [
                        Card(rank: .ace, suit: .spades),
                        Card(rank: .ace, suit: .hearts),
                        Card(rank: .king, suit: .hearts),
                        Card(rank: .queen, suit: .clubs),
                        Card(rank: .ten, suit: .diamonds)
                    ]
                ),
                RevealedHand(
                    playerID: "bot-1",
                    holeCards: [Card(rank: .seven, suit: .clubs), Card(rank: .two, suit: .diamonds)],
                    rank: .highCard,
                    bestFive: [
                        Card(rank: .ace, suit: .hearts),
                        Card(rank: .queen, suit: .clubs),
                        Card(rank: .ten, suit: .diamonds),
                        Card(rank: .seven, suit: .clubs),
                        Card(rank: .two, suit: .diamonds)
                    ]
                )
            ],
            wentToShowdown: true
        )
        state.board = [
            Card(rank: .ace, suit: .hearts),
            Card(rank: .queen, suit: .clubs),
            Card(rank: .ten, suit: .diamonds),
            Card(rank: .four, suit: .spades),
            Card(rank: .three, suit: .clubs)
        ]
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
