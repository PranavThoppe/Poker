import Foundation
import Combine

@MainActor
final class GameStore: ObservableObject {
    @Published var state: GameState
    @Published var showManualFinishTieWarning = false
    @Published var blindIncreaseConfirmation: String?
    @Published private(set) var isSubmittingCommand = false
    @Published private(set) var multiplayerError: String?
    /// Retained verbatim after a transport failure so retrying cannot apply a
    /// second wager if the first request reached the Function.
    private var retryableClassicCommand: (command: GameCommand, actionID: UUID)?

    /// Sync backend; replaced with `SupabaseSync()` for classic multiplayer sessions.
    var syncer: GameSyncing = MockSync()
    /// True on the device that created the game room.
    var isHost: Bool = false

    private var engine = PokerEngine()
    private let botScheduler = BotTurnScheduler()
    private var botSessionConfig = BotSessionConfig.default
    private var botStrategy: BotStrategy = makeStrategy(for: .default)
    private var stalledHandTask: Task<Void, Never>?
    private var showdownTimeoutTask: Task<Void, Never>?
    private var showdownAdvanceTask: Task<Void, Never>?
    private var boardRevealFallbackTask: Task<Void, Never>?
    private var blindIncreaseConfirmationTask: Task<Void, Never>?
    private var lastHandledBlindIncreaseAnnouncementID: UUID?
    private var hasReceivedInitialRoomState = false
    private var lastShowdownTimeoutID: String?
    /// Reopening a room is an intent to return. During a live hand the intent stays local
    /// until the safe `.handSummary` boundary, then writes one normal roster update.
    private var shouldRequestRejoinOnRemoteState = false
    private var pendingRejoinHandID: UUID?
    /// Consecutive watchdog ticks with nobody on the clock.
    private var stalledPollTicks = 0

    /// True while newly dealt board cards are still flipping face-up. Bots and showdown wait;
    /// the hero hand-rank label stays on the pre-deal value so it does not spoil the flip.
    @Published private(set) var isBoardRevealPending = false
    /// Demo-only pulse counters so autoplay can reuse the same button ripples as a real tap.
    @Published private(set) var marketingDemoCheckCallPulse = 0
    @Published private(set) var marketingDemoRaisePulse = 0
    @Published private(set) var marketingDemoReadyPulse = 0
    #if DEBUG
    /// Marketing Demo is a local practice session whose hero uses the same legal-action path as bots.
    private var marketingDemoAutoplay = false
    #endif
    private var heldHeroHandRank: HandRank?
    private var deferredShowdownBefore: GameLog.ActionSnapshot?
    private var deferredShowdownFromRemote = false

    /// How long the host waits (plus a small buffer) before silently advancing showdown
    /// if the human winner never taps Continue. Not shown as a button countdown.
    static let showdownAdvanceSeconds: TimeInterval = 10
    /// Safety net if the board view never reports that a flip finished.
    private static let boardRevealFallbackSeconds: TimeInterval = 2.5
    /// Gives tap feedback and chip-count animations time to finish before a CPU response.
    private static let botTurnDelay: TimeInterval = 0.6
    private static let botTurnDelayAfterBoardDeal: TimeInterval = 0.55

    init(state: GameState = GameState()) {
        self.state = state
    }

    deinit {
        stalledHandTask?.cancel()
        showdownTimeoutTask?.cancel()
        showdownAdvanceTask?.cancel()
        boardRevealFallbackTask?.cancel()
        blindIncreaseConfirmationTask?.cancel()
    }

    /// Hand rank shown under the hero avatar — frozen during a board flip.
    var displayedHeroHandRank: HandRank? {
        isBoardRevealPending ? heldHeroHandRank : state.heroHandRank
    }

    /// Called by `BoardView` when a community-card flip cycle ends (or there was nothing to flip).
    func boardRevealFinished() {
        guard isBoardRevealPending else { return }
        finishBoardRevealAndContinue()
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
        state.players.append(Player(id: playerID, name: name, stack: engine.startingStack(for: state), avatarIndex: avatarIndex))
        if state.heroID == nil {
            state.heroID = playerID
        }
        GameLog.playerJoined(playerID: playerID, state: state)
    }

    /// Room entry APIs are deliberately separate from local `joinGame`, which
    /// remains useful for practice mode and previews.
    func createClassicRoom(playerID: String, name: String, avatarIndex: Int) async throws {
        let response = try await GameCommandClient.shared.createRoom(roomID: state.gameID, playerID: playerID, name: name, avatarIndex: avatarIndex)
        guard let remote = response.state else { throw URLError(.badServerResponse) }
        state = remote; state.stateVersion = response.serverVersion ?? remote.stateVersion; state.heroID = playerID
    }

    func joinClassicRoom(playerID: String, name: String, avatarIndex: Int) async throws {
        let response = try await GameCommandClient.shared.joinRoom(roomID: state.gameID, playerID: playerID, name: name, avatarIndex: avatarIndex)
        guard let remote = response.state else { throw URLError(.badServerResponse) }
        state = remote; state.stateVersion = response.serverVersion ?? remote.stateVersion; state.heroID = playerID
    }

    // MARK: - Ready state

    static let minimumStartingStack = 100
    static let maximumStartingStack = 100_000
    static let minimumSmallBlind = 1
    static let maximumSmallBlind = 5_000

    var tableStartingStack: Int {
        engine.startingStack(for: state)
    }

    var canEditWaitingRoomSettings: Bool {
        state.phase == .waiting
            && (state.gameMode == .practiceVsCPU || (state.gameMode == .classicPoker && isHost))
    }

    func areValidWaitingRoomSettings(startingStack: Int, smallBlind: Int) -> Bool {
        (Self.minimumStartingStack...Self.maximumStartingStack).contains(startingStack)
            && (Self.minimumSmallBlind...Self.maximumSmallBlind).contains(smallBlind)
            && startingStack >= smallBlind * 40
    }

    /// The host changes both pre-game values together, which also asks every
    /// player to explicitly re-confirm readiness at the revised stakes.
    func updateWaitingRoomSettings(startingStack: Int, smallBlind: Int) {
        guard canEditWaitingRoomSettings,
              areValidWaitingRoomSettings(startingStack: startingStack, smallBlind: smallBlind) else { return }
        if state.gameMode == .classicPoker {
            submit(.updateSettings(startingStack: startingStack, smallBlind: smallBlind))
        } else {
            state.startingStack = startingStack
            state.smallBlind = smallBlind
            for index in state.players.indices {
                state.players[index].stack = startingStack
                state.players[index].isReady = false
            }
        }
    }

    func toggleReady() {
        if state.gameMode == .classicPoker { submit(.setReady(!(state.players.first { $0.id == state.heroID }?.isReady ?? false))); return }
        guard let heroID = state.heroID,
              let idx = state.players.firstIndex(where: { $0.id == heroID }) else { return }
        guard !state.players[idx].isSittingOut else { return }
        if state.phase == .handSummary {
            guard !state.players[idx].isEliminated, state.players[idx].stack > 0 else { return }
        }
        state.players[idx].isReady.toggle()
        GameLog.readyChanged(
            playerID: heroID,
            isReady: state.players[idx].isReady,
            state: state
        )
    }

    func startGame() {
        if state.gameMode == .classicPoker { submit(.startGame); return }
        guard !state.players.isEmpty else { return }
        let previousPhase = state.phase
        if state.gameMode == .practiceVsCPU {
            #if DEBUG
            if !marketingDemoAutoplay {
                seedBots()
            }
            #else
            seedBots()
            #endif
            engine.startGame(&state)
            engine.startHand(&state)
            if previousPhase == .waiting {
                GameLog.gameStarted(state: state)
            }
            GameLog.logHandStarted(state: state)
            beginHandPhase(from: previousPhase)
            scheduleBotTurnIfNeeded()
            scheduleBotShowIfNeeded()
            return
        }

    }

    #if DEBUG
    /// Enables hands-free play for the local player in the internal Marketing Demo only.
    func enableMarketingDemoAutoplay() {
        marketingDemoAutoplay = true
    }

    func markMarketingDemoPlayerReady(id: String) {
        guard marketingDemoAutoplay,
              let index = state.players.firstIndex(where: { $0.id == id }) else { return }
        state.players[index].isReady = true
        GameLog.readyChanged(playerID: id, isReady: true, state: state)
        if id == state.heroID {
            marketingDemoReadyPulse += 1
        }
    }
    #endif

    var isMarketingDemoAutoplay: Bool {
        #if DEBUG
        marketingDemoAutoplay
        #else
        false
        #endif
    }

    var allReady: Bool {
        let required = playersRequiredToReadyForNextHand
        return !required.isEmpty && required.allSatisfy(\.isReady)
    }

    private var eligiblePlayerCountForNextHand: Int {
        playersRequiredToReadyForNextHand.count
    }

    var canStartGame: Bool {
        allReady
            && (state.gameMode != .classicPoker || isHost)
            // Preserve the legacy solo Classic lobby, but do not deal a one-player hand
            // after other seated players chose to sit out.
            && (!state.players.contains(where: \.isSittingOut) || eligiblePlayerCountForNextHand >= 2)
    }

    var playersRequiredToReadyForNextHand: [Player] {
        state.players.filter { !$0.isEliminated && !$0.isSittingOut && $0.stack > 0 }
    }

    var allReadyForNextHand: Bool {
        let players = playersRequiredToReadyForNextHand
        return players.count >= 2 && players.allSatisfy(\.isReady)
    }

    var canStartNextHand: Bool {
        state.phase == .handSummary
            && state.gameMode == .classicPoker
            && !sessionEndsAfterHandSummary
            && allReadyForNextHand
            && isHost
    }

    var tableSmallBlind: Int {
        engine.smallBlind(for: state)
    }

    var canRaiseBlinds: Bool {
        state.phase == .handSummary
            && !sessionEndsAfterHandSummary
            && (state.gameMode == .practiceVsCPU || isHost)
    }

    /// Blind levels only change between hands and preserve each player's ready status.
    func raiseSmallBlind(to newSmallBlind: Int) {
        if state.gameMode == .classicPoker { submit(.raiseBlinds(newSmallBlind)); return }
        guard canRaiseBlinds, newSmallBlind > tableSmallBlind else { return }

        state.smallBlind = newSmallBlind
        if state.gameMode == .classicPoker {
            let announcement = BlindIncreaseAnnouncement(id: UUID(), smallBlind: newSmallBlind)
            state.blindIncreaseAnnouncement = announcement
            lastHandledBlindIncreaseAnnouncementID = announcement.id
        }
        presentBlindIncreaseConfirmation(smallBlind: newSmallBlind)
    }

    var isHeroTurn: Bool {
        guard let heroID = state.heroID else { return false }
        return state.activePlayerID == heroID && !isHeroSittingOut
    }

    var isHeroSittingOut: Bool {
        guard let heroID = state.heroID else { return false }
        return state.players.first(where: { $0.id == heroID })?.isSittingOut ?? false
    }

    /// The X action for an unfinished Classic room. This is intentionally available only to
    /// an active, non-eliminated local player; elimination remains permanent.
    func sitOutLocalPlayer() {
        if state.gameMode == .classicPoker { submit(.setSittingOut(true)); return }
        guard state.gameMode == .classicPoker,
              let heroID = state.heroID,
              let index = state.players.firstIndex(where: { $0.id == heroID }),
              !state.players[index].isEliminated,
              !state.players[index].isSittingOut else { return }

        if state.phase == .playing {
            _ = engine.foldForSitOut(&state, playerID: heroID)
        } else if state.phase == .showdown,
                  state.pendingRevealPlayerID == heroID {
            // A reveal order cannot wait for a player who is closing the extension. Record
            // their already-dealt hand before changing presentation to spectator mode.
            showCards(for: heroID, auto: true)
        }
        state.players[index].isSittingOut = true
        state.players[index].isReady = false
        state.heroHoleCards = []
        state.heroHandRank = nil

        // A host can resolve a fold-out immediately. Guests publish their folded snapshot;
        // the host will resolve it on the next subscription tick.
        if isHost, state.phase == .playing, state.activePlayerID == nil {
            resolveHostPendingState()
        }
    }

    /// Called when this device opens an existing Classic room. A sitting-out player returns
    /// at a summary/waiting boundary, or spectates the hand already underway.
    func requestRejoinAfterReopening() {
        guard state.gameMode == .classicPoker else { return }
        shouldRequestRejoinOnRemoteState = true
        reconcileLocalParticipation()
    }

    /// Stops only this extension's polling and local scheduled work. It never writes a room
    /// mutation, so Classic Done and sit-out dismissal cannot end a shared game.
    func stopMultiplayerSession() {
        guard state.gameMode == .classicPoker else { return }
        syncer.unsubscribe(roomID: state.gameID.uuidString)
        stalledHandTask?.cancel()
        stalledHandTask = nil
        showdownTimeoutTask?.cancel()
        showdownTimeoutTask = nil
        cancelShowdownAdvance()
        clearBoardRevealGate()
    }

    /// Largest callable total for the hero this street — own stack capped by the biggest
    /// live opponent. Feeds the raise slider and the All-in label.
    var heroMaxRaise: Int {
        guard let heroID = state.heroID else { return state.raiseAmount }
        return engine.maxRaiseTotal(state, for: heroID)
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

    /// True while an eligible player is waiting for their private cards in the
    /// next server snapshot.
    var isWaitingForHoleCards: Bool {
        guard state.gameMode == .classicPoker else { return false }
        guard state.phase == .playing || state.phase == .showdown else { return false }
        guard isHeroEligibleForHoleCards else { return false }
        return state.heroHoleCards.count < 2
    }

    private var isHeroEligibleForHoleCards: Bool {
        guard let heroID = state.heroID,
              let player = state.players.first(where: { $0.id == heroID }) else { return false }
        return !player.isEliminated && !player.isSittingOut && player.stack > 0
    }

    private func beginHandPhase(from previousPhase: GamePhase) {
        clearBoardRevealGate()
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
        if state.gameMode == .classicPoker { submit(.showCards); return }
        guard state.phase == .showdown else { return }
        guard let id = playerID ?? state.heroID else { return }
        if state.players.first(where: { $0.id == id })?.isSittingOut == true, !auto { return }
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
            showdownTimeoutTask?.cancel()
            scheduleShowdownAdvanceIfNeeded()
        } else {
            lastShowdownTimeoutID = nil
            scheduleBotShowIfNeeded()
            restartShowdownTimeout()
        }
    }

    /// Leaves the showdown table for the hand summary. In classic, only the winner may do this
    /// by hand; `auto` is the countdown fallback, a bot-won pot, or the host covering an absent
    /// winner. Practice always lets the human advance so they pace the table themselves.
    func advanceToHandSummary(auto: Bool = false) {
        if state.gameMode == .classicPoker { submit(.advanceSummary); return }
        guard state.phase == .showdown, showdownDeciderID != nil else { return }
        let practiceHeroMayAdvance = state.gameMode == .practiceVsCPU && state.heroID != nil
        guard auto || isHeroShowdownDecider || practiceHeroMayAdvance else { return }
        GameLog.showdownAdvanced(playerID: showdownDeciderID, auto: auto, state: state)
        finishShowdownToSummary()
    }

    // MARK: - End game / navigation

    func requestManualEndGame() {
        if state.gameMode == .classicPoker { submit(.endGame(.manualFinish)); return }
        guard state.phase == .handSummary else { return }
        if isChipTiedAmongActiveHumans() {
            if state.manualFinishTieAttempts == 0 {
                state.manualFinishTieAttempts += 1
                showManualFinishTieWarning = true
                return
            }
            endGame(reason: .manualFinishTieForfeit)
            return
        }
        endGame(reason: .manualFinish)
    }

    func dismissManualFinishTieWarning() {
        showManualFinishTieWarning = false
    }

    func endGame(reason: GameEndReason = .manualFinish) {
        if state.gameMode == .classicPoker { submit(.endGame(reason)); return }
        clearBoardRevealGate()
        let previousPhase = state.phase
        state.phase = .ended
        state.endStats = buildStats(reason: reason)
        GameLog.phaseChanged(from: previousPhase, to: .ended, state: state)
        GameLog.gameEnded(state: state)

        let humanCount = state.players.filter { !$0.isBot }.count
        WinStatsService.shared.recordGameWinIfEligible(
            gameID: state.gameID,
            gameMode: state.gameMode,
            endStats: state.endStats,
            endReason: reason,
            humanCount: humanCount,
            completedHands: state.completedHandCount
        )

    }

    func continueAfterHandSummary() {
        if state.gameMode == .classicPoker { submit(.startNextHand); return }
        guard state.phase == .handSummary else { return }
        if engine.shouldEndGame(state) {
            endGame(reason: .autoLastStanding)
        } else {
            let previousPhase = state.phase
            engine.startHand(&state)
            GameLog.nextHandStarted(state: state)
            beginHandPhase(from: previousPhase)
            scheduleBotTurnIfNeeded()
            scheduleBotShowIfNeeded()
        }
    }

    var sessionEndsAfterHandSummary: Bool {
        engine.shouldEndGame(state)
    }

    func resetToWaiting() {
        if state.gameMode == .classicPoker { submit(.resetRoom); return }
        botScheduler.cancel()
        showdownTimeoutTask?.cancel()
        cancelShowdownAdvance()
        let previousPhase = state.phase
        var fresh = GameState()
        fresh.phase = .waiting
        fresh.gameID = state.gameID
        fresh.hostID = state.hostID
        fresh.gameMode = state.gameMode
        fresh.startingStack = state.startingStack
        fresh.smallBlind = state.smallBlind
        fresh.players = state.players
            .filter { !$0.isBot }
            .map { p in
                var np = p
                np.isReady = false
                np.isFolded = false
                np.isEliminated = false
                np.isSittingOut = false
                np.isDealer = false
                np.currentBet = 0
                np.stack = engine.startingStack(for: state)
                return np
            }
        fresh.heroID = state.heroID
        // Keep the counter climbing so peers do not reject the reset as a stale write.
        fresh.stateVersion = state.version
        state = fresh
        GameLog.phaseChanged(from: previousPhase, to: .waiting, state: state)
        GameLog.gameReset(state: state)
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
        startStalledHandWatchdog()
    }

    /// (Re)starts the poll loop. Restarting clears the syncer's de-duplication state, so the
    /// next tick re-merges the server's current row even if we already saw that version.
    private func startRoomSubscription() {
        hasReceivedInitialRoomState = false
        lastHandledBlindIncreaseAnnouncementID = nil
        let roomID = state.gameID.uuidString
        syncer.subscribe(roomID: roomID) { [weak self] remoteState, remoteHostID in
            guard let self else { return }

            self.mergeRemoteState(remoteState, remoteHostID: remoteHostID)
            self.reconcileLocalParticipation()

            if self.isHost,
               self.state.phase == .playing,
               self.state.activePlayerID == nil {
                self.resolveHostPendingState()
            }

            self.stalledPollTicks = 0
        }
    }

    // MARK: - Private

    private func apply(_ action: BettingAction) {
        if state.gameMode == .classicPoker {
            switch action {
            case .fold: submit(.bet(kind: "fold", amount: nil))
            case .check: submit(.bet(kind: "check", amount: nil))
            // The server verifies the exact call amount, which prevents a
            // stale client from silently paying too little or too much.
            case .call: submit(.bet(kind: "call", amount: state.callAmount))
            case .raise(let amount): submit(.bet(kind: "raise", amount: amount))
            }
            return
        }
        guard let heroID = state.heroID else { return }
        applyAction(for: heroID, action: action)
    }

    /// Merges only a server response. The local Swift engine remains exclusive
    /// to practice mode; an action ID is retained by callers for retry safety.
    private func submit(_ command: GameCommand, actionID: UUID = UUID()) {
        guard state.gameMode == .classicPoker, let heroID = state.heroID, !isSubmittingCommand else { return }
        isSubmittingCommand = true; multiplayerError = nil
        let roomID = state.gameID, version = state.version, handID = state.handID
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await GameCommandClient.shared.submit(roomID: roomID, playerID: heroID, version: version, handID: handID, command: command, actionID: actionID)
                if let next = result.state {
                    self.mergeServerState(next, serverVersion: result.serverVersion)
                }
                if self.retryableClassicCommand?.actionID == actionID {
                    self.retryableClassicCommand = nil
                }
            } catch {
                if Self.isStaleCommandError(error) {
                    // A response from an earlier poll or another player's action won
                    // the race. Refresh before accepting the next tap; retrying this
                    // command would apply it to a different decision.
                    await self.refreshClassicState(roomID: roomID, playerID: heroID)
                } else {
                    self.retryableClassicCommand = (command, actionID)
                    self.multiplayerError = error.localizedDescription
                }
            }
            self.isSubmittingCommand = false
        }
    }

    private static func isStaleCommandError(_ error: Error) -> Bool {
        guard let apiError = error as? GameAPIClientError,
              case let .server(_, code, _) = apiError else { return false }
        return code == "stale_state" || code == "stale_hand"
    }

    /// Retrieves a fresh viewer-scoped snapshot after the server rejects a
    /// command composed from an obsolete turn.
    private func refreshClassicState(roomID: UUID, playerID: String) async {
        guard let response = try? await GameCommandClient.shared.roomState(
            roomID: roomID,
            playerID: playerID
        ), let remote = response.state else { return }
        mergeServerState(remote, serverVersion: response.serverVersion)
    }

    private func mergeServerState(_ remote: GameState, serverVersion: Int?) {
        var versionedRemote = remote
        versionedRemote.stateVersion = serverVersion ?? remote.stateVersion
        mergeRemoteState(versionedRemote, remoteHostID: versionedRemote.hostID)
    }

    /// Retries the exact request identity after a transient failure. A stale
    /// response remains a refresh-required error; a dropped accepted response
    /// is returned by the server's idempotency receipt.
    func retryLastClassicCommand() {
        guard let pending = retryableClassicCommand else { return }
        submit(pending.command, actionID: pending.actionID)
    }

    private func applyAction(for playerID: String, action: BettingAction) {
        guard state.phase == .playing else {
            GameLog.actionRejected(playerID: playerID, action: action, reason: "wrongPhase", state: state)
            return
        }

        let rankBefore = state.heroHandRank
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

        let streetBefore = before.bettingRound
        noteBoardGrowthIfNeeded(previousCount: before.boardCount, holdingRank: rankBefore)

        if let result = state.handResult, state.phase == .playing {
            if result.wentToShowdown {
                enterShowdown(before: before)
            } else {
                finalizeHandIfNeeded(before: before)
            }
        } else if state.activePlayerID == nil {
            // Guest finished a street without the deck; wait for the host to deal.
            if state.gameMode == .classicPoker && !isHost && state.holeCardsByPlayer.isEmpty {
                GameLog.showdownDeferredToHost(state: state)
                return
            }
            // Prefer resolving/recovering a closed street over jumping to hand summary.
            let pending = GameLog.ActionSnapshot.capture(from: state, playerID: playerID)
            let boardBeforeResolve = state.board.compactMap { $0 }.count
            let rankBeforeResolve = state.heroHandRank
            if engine.resolvePendingBettingRound(&state) {
                GameLog.logStreetResolved(before: pending, state: state)
                noteBoardGrowthIfNeeded(previousCount: boardBeforeResolve, holdingRank: rankBeforeResolve)
                let dealtNewStreet = streetBefore != state.bettingRound && state.handResult == nil
                if let result = state.handResult, result.wentToShowdown {
                    enterShowdown(before: before)
                } else if state.handResult != nil {
                    finalizeHandIfNeeded(before: before)
                } else if state.activePlayerID == nil {
                    if engine.recoverStalledHand(&state) {
                        scheduleBotTurnIfNeeded(afterBoardDeal: dealtNewStreet)
                    } else {
                        finalizeHandIfNeeded(before: before)
                    }
                } else {
                    scheduleBotTurnIfNeeded(afterBoardDeal: dealtNewStreet)
                }
            } else if engine.recoverStalledHand(&state) {
                scheduleBotTurnIfNeeded()
            } else {
                finalizeHandIfNeeded(before: before)
            }
        } else {
            let dealtNewStreet = streetBefore != state.bettingRound && state.handResult == nil
            scheduleBotTurnIfNeeded(afterBoardDeal: dealtNewStreet)
        }
    }

    private func finalizeHandIfNeeded(before: GameLog.ActionSnapshot? = nil, fromRemotePoll: Bool = false) {
        // A hand is only over once a pot has been awarded. Finalizing without a result
        // silently abandons a live hand into the summary screen with no winner, which is
        // how an unresolved street used to look like the hand had simply ended.
        guard state.handResult != nil else {
            GameLog.handFinalizeBlocked(state: state)
            return
        }

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
        markHandCompletedIfNeeded(previousPhase: previousPhase)
        resetReadyStateForHandSummary()
        state.phase = .handSummary
        reconcileLocalParticipation()
        GameLog.phaseChanged(from: previousPhase, to: .handSummary, state: state)
        GameLog.handSummaryOpened(state: state)
    }

    private func enterShowdown(before: GameLog.ActionSnapshot? = nil, fromRemotePoll: Bool = false) {
        guard state.phase != .showdown else { return }
        if state.gameMode == .classicPoker && !isHost && state.holeCardsByPlayer.isEmpty {
            GameLog.showdownDeferredToHost(state: state)
            return
        }
        // Keep the playing screen up until the last board flip finishes so the hero can
        // see the river (and act) before the showdown chrome replaces it.
        if isBoardRevealPending {
            deferredShowdownBefore = before
            deferredShowdownFromRemote = fromRemotePoll
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
        clearBoardRevealGate()
        state.endStats = buildHandSummaryStats()
        let previousPhase = state.phase
        state.phase = .showdown
        GameLog.phaseChanged(from: previousPhase, to: .showdown, state: state)
        scheduleBotShowIfNeeded()
        restartShowdownTimeout()
    }

    /// Arms the fallback that closes the showdown table if the winner never taps Continue.
    /// Practice waits indefinitely for the human. Classic: a bot winner advances on its think
    /// delay; a human winner has no visible countdown — only the host runs a silent safety
    /// timeout in case that winner has dropped.
    private func scheduleShowdownAdvanceIfNeeded() {
        #if DEBUG
        if marketingDemoAutoplay, let deciderID = showdownDeciderID {
            // Leave the completed reveal on screen long enough to read the winning hand.
            botScheduler.schedule(delay: 2) { [weak self] in
                guard self?.showdownDeciderID == deciderID else { return }
                self?.advanceToHandSummary(auto: true)
            }
            return
        }
        #endif
        guard state.gameMode != .practiceVsCPU else { return }
        guard let deciderID = showdownDeciderID else { return }

        if isBot(deciderID) {
            botScheduler.schedule { [weak self] in
                self?.advanceToHandSummary(auto: true)
            }
            return
        }

        guard isHost else { return }
        guard showdownAdvanceTask == nil else { return }

        let delay = Self.showdownAdvanceSeconds + 4
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
        clearBoardRevealGate()
        // Credit the pot only after every hand is face up, then mark bust-outs.
        engine.applyHandResultPayouts(&state)
        engine.eliminateBrokePlayers(&state)
        engine.updateHeroDisplay(&state)
        state.endStats = buildHandSummaryStats()
        let previousPhase = state.phase
        markHandCompletedIfNeeded(previousPhase: previousPhase)
        resetReadyStateForHandSummary()
        state.phase = .handSummary
        reconcileLocalParticipation()
        GameLog.phaseChanged(from: previousPhase, to: .handSummary, state: state)
        GameLog.handSummaryOpened(state: state)
    }

    private func resetReadyStateForHandSummary() {
        guard state.gameMode == .classicPoker else { return }
        for index in state.players.indices {
            state.players[index].isReady = false
        }
    }

    /// Applies a local reopen request once the room reaches a hand boundary. Repeated poll
    /// updates are harmless: after activation both intent markers are cleared.
    private func reconcileLocalParticipation() {
        guard state.gameMode == .classicPoker,
              let heroID = state.heroID,
              let index = state.players.firstIndex(where: { $0.id == heroID }),
              !state.players[index].isEliminated else {
            shouldRequestRejoinOnRemoteState = false
            pendingRejoinHandID = nil
            return
        }

        let wantsToRejoin = shouldRequestRejoinOnRemoteState || pendingRejoinHandID != nil
        guard wantsToRejoin, state.players[index].isSittingOut else {
            // Before the first poll our temporary join record says "not sitting out".
            // Keep the reopen intent until the authoritative roster has arrived.
            if hasReceivedInitialRoomState && !state.players[index].isSittingOut {
                shouldRequestRejoinOnRemoteState = false
                pendingRejoinHandID = nil
            }
            return
        }

        switch state.phase {
        case .waiting, .handSummary:
            state.players[index].isSittingOut = false
            state.players[index].isReady = false
            state.heroHoleCards = []
            state.heroHandRank = nil
            shouldRequestRejoinOnRemoteState = false
            pendingRejoinHandID = nil
        case .playing, .showdown:
            pendingRejoinHandID = state.handID
            shouldRequestRejoinOnRemoteState = false
            state.heroHoleCards = []
            state.heroHandRank = nil
        case .ended:
            break
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

    private func scheduleBotTurnIfNeeded(afterBoardDeal: Bool = false) {
        guard state.gameMode == .practiceVsCPU,
              let id = state.activePlayerID,
              isAutomatedPlayer(id) else { return }
        // New board cards are still flipping — resume from boardRevealFinished instead.
        guard !isBoardRevealPending else {
            botScheduler.cancel()
            return
        }
        // After a deal, give a short beat once the flip has already finished.
        #if DEBUG
        let delay: TimeInterval
        if marketingDemoAutoplay,
           let action = marketingDemoAction(for: id, legalActions: engine.legalActions(for: state, playerID: id)),
           isQuickDemoAction(action) {
            delay = 0.5
        } else if marketingDemoAutoplay {
            delay = Double.random(in: 1.2...3.0)
        } else {
            delay = afterBoardDeal ? Self.botTurnDelayAfterBoardDeal : Self.botTurnDelay
        }
        #else
        let delay = afterBoardDeal ? Self.botTurnDelayAfterBoardDeal : Self.botTurnDelay
        #endif
        botScheduler.schedule(delay: delay) { [weak self] in
            self?.performBotTurn(playerID: id)
        }
    }

    private func noteBoardGrowthIfNeeded(previousCount: Int, holdingRank: HandRank?) {
        let nextCount = state.board.compactMap { $0 }.count
        guard nextCount > previousCount, state.phase == .playing else { return }
        beginBoardReveal(holdingRank: holdingRank)
    }

    private func beginBoardReveal(holdingRank: HandRank?) {
        if !isBoardRevealPending {
            heldHeroHandRank = holdingRank
        }
        isBoardRevealPending = true
        botScheduler.cancel()
        armBoardRevealFallback()
    }

    private func finishBoardRevealAndContinue() {
        isBoardRevealPending = false
        heldHeroHandRank = nil
        cancelBoardRevealFallback()

        if state.phase == .playing,
           state.handResult?.wentToShowdown == true {
            let before = deferredShowdownBefore
            let fromRemote = deferredShowdownFromRemote
            deferredShowdownBefore = nil
            deferredShowdownFromRemote = false
            enterShowdown(before: before, fromRemotePoll: fromRemote)
            return
        }

        deferredShowdownBefore = nil
        deferredShowdownFromRemote = false
        scheduleBotTurnIfNeeded(afterBoardDeal: true)
    }

    private func clearBoardRevealGate() {
        isBoardRevealPending = false
        heldHeroHandRank = nil
        deferredShowdownBefore = nil
        deferredShowdownFromRemote = false
        cancelBoardRevealFallback()
    }

    private func armBoardRevealFallback() {
        boardRevealFallbackTask?.cancel()
        boardRevealFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.boardRevealFallbackSeconds))
            guard let self, !Task.isCancelled else { return }
            self.boardRevealFinished()
        }
    }

    private func cancelBoardRevealFallback() {
        boardRevealFallbackTask?.cancel()
        boardRevealFallbackTask = nil
    }

    private func scheduleBotShowIfNeeded() {
        guard state.phase == .showdown,
              let id = state.pendingRevealPlayerID,
              isAutomatedPlayer(id) else { return }
        #if DEBUG
        // The Show control has an eight-second fill. Hold the demo hero for four seconds so
        // the recording captures a deliberate half-filled reveal instead of an instant flip.
        let delay: TimeInterval = marketingDemoAutoplay && id == state.heroID ? 4 : 0.4
        #else
        let delay: TimeInterval = 0.4
        #endif
        botScheduler.schedule(delay: delay) { [weak self] in
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
              !isBoardRevealPending,
              state.activePlayerID == playerID,
              isAutomatedPlayer(playerID) else { return }
        let legal = engine.legalActions(for: state, playerID: playerID)
        guard !legal.isEmpty else { return }
        let action: BettingAction
        #if DEBUG
        if marketingDemoAutoplay {
            guard let demoAction = marketingDemoAction(for: playerID, legalActions: legal) else { return }
            action = demoAction
        } else {
            action = botStrategy.chooseAction(
                state: state,
                playerID: playerID,
                legalActions: legal
            )
        }
        #else
        action = botStrategy.chooseAction(
            state: state,
            playerID: playerID,
            legalActions: legal
        )
        #endif
        #if DEBUG
        if marketingDemoAutoplay, playerID == state.heroID {
            noteMarketingDemoHeroPulse(action)
            botScheduler.schedule(delay: 0.42) { [weak self] in
                guard let self else { return }
                guard self.state.phase == .playing,
                      self.state.activePlayerID == playerID else { return }
                self.applyAction(for: playerID, action: action)
            }
            return
        }
        #endif
        applyAction(for: playerID, action: action)
    }

    private func seedBots() {
        state.players.removeAll { $0.isBot }
        state.players.append(contentsOf: BotCatalog.makeBots(
            count: botSessionConfig.botCount,
            startingStack: engine.startingStack(for: state)
        ))
        botStrategy = makeStrategy(for: botSessionConfig)
    }

    private func isBot(_ playerID: String) -> Bool {
        state.players.first(where: { $0.id == playerID })?.isBot == true
    }

    private func isAutomatedPlayer(_ playerID: String) -> Bool {
        if isBot(playerID) { return true }
        #if DEBUG
        return marketingDemoAutoplay && playerID == state.heroID
        #else
        return false
        #endif
    }

    #if DEBUG
    private func isQuickDemoAction(_ action: BettingAction) -> Bool {
        switch action {
        case .check, .call:
            return true
        case .fold, .raise:
            return false
        }
    }

    /// Keeps everyone in the demo hand, with one readable opening raise on both turn and river.
    private func marketingDemoAction(for playerID: String, legalActions: [BettingAction]) -> BettingAction? {
        guard state.activePlayerID == playerID else { return nil }

        let isOpeningTurnOrRiverBet = (state.bettingRound == .turn || state.bettingRound == .river)
            && state.streetBetLevel == 0
        if isOpeningTurnOrRiverBet,
           let raise = legalActions.first(where: {
               if case .raise = $0 { return true }
               return false
           }) {
            return raise
        }

        return legalActions.first(where: {
            if case .check = $0 { return true }
            return false
        }) ?? legalActions.first(where: {
            if case .call = $0 { return true }
            return false
        }) ?? legalActions.first(where: {
            if case .raise = $0 { return true }
            return false
        })
    }

    private func noteMarketingDemoHeroPulse(_ action: BettingAction) {
        switch action {
        case .check, .call:
            marketingDemoCheckCallPulse += 1
        case .raise:
            marketingDemoRaisePulse += 1
        case .fold:
            break
        }
    }
    #endif

    private func presentBlindIncreaseConfirmation(smallBlind: Int) {
        blindIncreaseConfirmation = "Blinds increased: \(smallBlind) / \(smallBlind * 2)"
        blindIncreaseConfirmationTask?.cancel()
        blindIncreaseConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.blindIncreaseConfirmation = nil
        }
    }

    /// Establishes the first room response as a baseline, then presents each newer event once.
    private func handleBlindIncreaseAnnouncement(from remote: GameState) {
        guard hasReceivedInitialRoomState else {
            lastHandledBlindIncreaseAnnouncementID = remote.blindIncreaseAnnouncement?.id
            hasReceivedInitialRoomState = true
            return
        }

        guard let announcement = remote.blindIncreaseAnnouncement,
              announcement.id != lastHandledBlindIncreaseAnnouncementID else { return }

        lastHandledBlindIncreaseAnnouncementID = announcement.id
        presentBlindIncreaseConfirmation(smallBlind: announcement.smallBlind)
    }

    /// Merges a viewer-scoped server snapshot. `heroHoleCards` belongs to the
    /// current viewer and is authoritative; the server never returns a deck or
    /// another player's cards.
    private func mergeRemoteState(_ remote: GameState, remoteHostID: String?) {
        var remote = remote
        // A command response can land while an older room-state request is
        // still in flight. Never let that older snapshot resurrect a previous
        // turn or its call amount.
        guard remote.version >= state.version else { return }
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
            handleBlindIncreaseAnnouncement(from: remote)
            GameLog.remoteStateMerged(state: state, heroRestored: false)
            return
        }
        let heroPlayer       = state.players.first(where: { $0.id == heroID })
        let isNewHand        = state.handID != remote.handID
        let heroWasMissing   = !remote.players.contains(where: { $0.id == heroID })
        let rankBefore       = state.heroHandRank
        let boardBefore      = state.board.compactMap { $0 }.count

        state = remote
        state.heroID = heroID

        // Guests receive the completed-hand transition from the host rather than
        // running its engine locally. The service de-duplicates replayed states.
        if state.phase == .handSummary || state.phase == .ended {
            creditLocalPlayerForCompletedHand()
        }

        if isNewHand {
            clearBoardRevealGate()
        }

        if heroWasMissing, let hero = heroPlayer {
            state.players.append(hero)
        }

        engine.syncBettingUI(&state)
        engine.updateHeroDisplay(&state)
        handleBlindIncreaseAnnouncement(from: remote)
        GameLog.remoteStateMerged(state: state, heroRestored: heroWasMissing)

        if state.phase == .playing {
            noteBoardGrowthIfNeeded(previousCount: boardBefore, holdingRank: rankBefore)
        } else {
            clearBoardRevealGate()
        }

        if state.phase == .showdown {
            scheduleBotShowIfNeeded()
            restartShowdownTimeout()
            scheduleShowdownAdvanceIfNeeded()
        } else {
            // Another device already moved the table on, so drop our own fallback.
            cancelShowdownAdvance()
        }
    }

    private func resolveHostPendingState() {
        if state.phase == .showdown { return }

        if state.handResult?.wentToShowdown == true, state.phase == .playing {
            enterShowdown(fromRemotePoll: true)
            return
        }

        if state.lastHandWinnerID != nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
            return
        }

        let pending = GameLog.ActionSnapshot.capture(
            from: state,
            playerID: state.activePlayerID ?? state.heroID ?? ""
        )
        let boardBefore = state.board.compactMap { $0 }.count
        let rankBefore = state.heroHandRank
        guard engine.resolvePendingBettingRound(&state) else { return }
        GameLog.logStreetResolved(before: pending, state: state)
        noteBoardGrowthIfNeeded(previousCount: boardBefore, holdingRank: rankBefore)
        if state.handResult?.wentToShowdown == true {
            enterShowdown(fromRemotePoll: true)
        } else if state.activePlayerID == nil {
            if !engine.recoverStalledHand(&state) {
                finalizeHandIfNeeded(fromRemotePoll: true)
            }
        }
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
            return
        }
        if state.lastHandWinnerID != nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
            return
        }
        let pending = GameLog.ActionSnapshot.capture(
            from: state,
            playerID: state.activePlayerID ?? state.heroID ?? ""
        )
        guard engine.recoverStalledHand(&state) else { return }
        GameLog.logStreetResolved(before: pending, state: state)
        GameLog.snapshot(state, event: "recovered stalled hand")
        if state.handResult?.wentToShowdown == true {
            enterShowdown(fromRemotePoll: true)
        } else if state.activePlayerID == nil {
            finalizeHandIfNeeded(fromRemotePoll: true)
        }
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

    private func buildStats(reason: GameEndReason) -> [PlayerStats] {
        let winnerID: String?
        switch reason {
        case .manualFinishTieForfeit:
            winnerID = nil
        case .autoLastStanding:
            let survivors = state.players.filter { !$0.isEliminated && $0.stack > 0 }
            winnerID = survivors.count == 1 ? survivors[0].id : nil
        case .manualFinish:
            let active = state.players.filter { !$0.isEliminated && $0.stack > 0 }
            if let topStack = active.map(\.stack).max() {
                let leaders = active.filter { $0.stack == topStack }
                winnerID = leaders.count == 1 ? leaders[0].id : nil
            } else {
                winnerID = nil
            }
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

    private var activeHumans: [Player] {
        state.players.filter { !$0.isBot && !$0.isEliminated && $0.stack > 0 }
    }

    private func isChipTiedAmongActiveHumans() -> Bool {
        let humans = activeHumans
        guard let topStack = humans.map(\.stack).max() else { return false }
        return humans.filter { $0.stack == topStack }.count > 1
    }

    private func markHandCompletedIfNeeded(previousPhase: GamePhase) {
        guard previousPhase != .handSummary, previousPhase != .ended else { return }
        state.completedHandCount += 1
        creditLocalPlayerForCompletedHand()
        syncManualFinishTieAttempts()
    }

    private func creditLocalPlayerForCompletedHand() {
        guard let handID = state.handID,
              let heroID = state.heroID,
              state.completedHandCount > 0,
              // A player eliminated before this deal remains in the room but is
              // not dealt cards. A player eliminated by this hand has this hand
              // included in their session total, so the count still matches.
              (state.handStats[heroID]?.handsPlayed ?? 0) >= state.completedHandCount else { return }
        HandsPlayedStatsService.shared.recordCompletedHand(handID: handID, gameMode: state.gameMode)
    }

    private func syncManualFinishTieAttempts() {
        guard state.manualFinishTieAttempts > 0 else { return }
        if !isChipTiedAmongActiveHumans() {
            state.manualFinishTieAttempts = 0
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
            Player(id: "hero", name: "You", stack: 480, avatarIndex: 0),
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
        state.pot = 40
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
            wentToShowdown: true,
            payoutsApplied: false
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
