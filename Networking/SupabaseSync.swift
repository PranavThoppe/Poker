import Foundation

/// Implements `GameSyncing` against the Supabase REST API.
///
/// Sync model (turn-based, so 2-second polling is sufficient):
/// - `subscribe` starts a Task loop that GETs the game_rooms row every 2 s.
///   Change detection uses the monotonic `stateVersion` carried inside `public_state`;
///   older writes are dropped and duplicates are skipped. `updated_at` only breaks ties
///   between two writes that share a version.
/// - `publish` upserts game_rooms with a sanitised public state (no private card data).
/// - Hole cards are written/read separately through `player_hole_cards`.
/// - Poll queries exclude `debug_log` so the growing log is not downloaded every 2 s.
final class SupabaseSync: GameSyncing {

    private var pollTask: Task<Void, Never>?
    private static let pollSelect = "id,host_id,public_state,updated_at"

    deinit { pollTask?.cancel() }

    // MARK: - GameSyncing

    func subscribe(
        roomID: String,
        onUpdate: @escaping @MainActor (GameState, String?) -> Void
    ) {
        pollTask?.cancel()
        GameLog.subscriptionStarted(roomID: roomID)
        pollTask = Task { [weak self] in
            guard self != nil else { return }
            var lastSeenVersion: Int? = nil
            var lastSeenUpdatedAt: String? = nil

            func fetchOnce() async {
                do {
                    let rows: [GameRoomRow] = try await SupabaseClient.shared.get(
                        path: "game_rooms",
                        query: ["id": "eq.\(roomID)", "select": Self.pollSelect]
                    )
                    guard let row = rows.first else { return }
                    let version = row.publicState.version
                    if let seen = lastSeenVersion {
                        // Never move backwards, and skip a version we have already merged
                        // unless a second write landed on it.
                        if version < seen { return }
                        if version == seen, row.updatedAt == lastSeenUpdatedAt { return }
                    }
                    lastSeenVersion = version
                    lastSeenUpdatedAt = row.updatedAt
                    await MainActor.run {
                        GameLog.remoteStateReceived(state: row.publicState)
                    }
                    await onUpdate(row.publicState, row.hostID)
                } catch {
                    // Transient errors (network, extension suspended) are expected — ignore silently.
                }
            }

            await fetchOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await fetchOnce()
            }
        }
    }

    func publish(state: GameState, roomID: String) {
        GameLog.statePublishStarted(state: state)
        Task {
            do {
                try await Self.publishRoom(state: state, roomID: roomID)
                await MainActor.run {
                    GameLog.statePublishSucceeded(state: state)
                }
            } catch {
                await MainActor.run {
                    GameLog.statePublishFailed(state: state)
                }
            }
        }
    }

    func unsubscribe(roomID: String) {
        pollTask?.cancel()
        pollTask = nil
        GameLog.subscriptionStopped(roomID: roomID)
    }

    /// One-shot read of the current room row. The host uses this before dealing so every
    /// joined guest is in `players` before cards are written.
    func fetchGameRoom(roomID: String) async throws -> (GameState, String?) {
        let rows: [GameRoomRow] = try await SupabaseClient.shared.get(
            path: "game_rooms",
            query: ["id": "eq.\(roomID)", "select": Self.pollSelect]
        )
        guard let row = rows.first else { throw URLError(.fileDoesNotExist) }
        return (row.publicState, row.hostID)
    }

    // MARK: - Hole cards (called directly by GameStore)

    /// Host writes each player's private hole cards after dealing.
    func upsertHoleCards(
        roomID: String,
        playerID: String,
        handID: UUID,
        cards: [Card]
    ) async throws {
        struct Payload: Encodable {
            let room_id: String
            let player_id: String
            let hand_id: UUID
            let cards: [Card]
        }
        try await SupabaseClient.shared.upsert(
            path: "player_hole_cards",
            body: Payload(room_id: roomID, player_id: playerID, hand_id: handID, cards: cards)
        )
    }

    /// Removes every private-card row for the room before a new deal is written.
    func deleteAllHoleCards(roomID: String) async throws {
        try await SupabaseClient.shared.delete(
            path: "player_hole_cards",
            query: ["room_id": "eq.\(roomID)"]
        )
    }

    /// Guest fetches their own hole cards after the host has dealt.
    func fetchHoleCards(roomID: String, playerID: String, handID: UUID) async throws -> [Card]? {
        struct Row: Decodable {
            let handID: UUID?
            let cards: [Card]

            enum CodingKeys: String, CodingKey {
                case handID = "hand_id"
                case cards
            }
        }
        let rows: [Row] = try await SupabaseClient.shared.get(
            path: "player_hole_cards",
            query: [
                "room_id":  "eq.\(roomID)",
                "player_id": "eq.\(playerID)",
                "select":   "hand_id,cards"
            ]
        )
        guard let row = rows.first, row.handID == handID else { return nil }
        return row.cards
    }

    /// Host recovery: re-reads every seat's cards so a relaunched host can still run a showdown.
    func fetchAllHoleCards(roomID: String, handID: UUID) async throws -> [String: [Card]] {
        struct Row: Decodable {
            let playerID: String
            let handID: UUID?
            let cards: [Card]

            enum CodingKeys: String, CodingKey {
                case playerID = "player_id"
                case handID = "hand_id"
                case cards
            }
        }
        let rows: [Row] = try await SupabaseClient.shared.get(
            path: "player_hole_cards",
            query: ["room_id": "eq.\(roomID)", "select": "player_id,hand_id,cards"]
        )
        return Dictionary(
            rows.filter { $0.handID == handID }.map { ($0.playerID, $0.cards) },
            uniquingKeysWith: { $1 }
        )
    }

    // MARK: - Private

    /// Millisecond precision. The default formatter emits whole seconds, so two writes in
    /// the same second produced identical strings and pollers dropped the second one.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func publishRoom(state: GameState, roomID: String) async throws {
        var pub = state
        pub.holeCardsByPlayer = [:]
        pub.remainingDeck     = []
        pub.heroHoleCards     = []
        pub.heroHandRank      = nil
        pub.heroID            = nil
        // `handResult` stays public. `reveals` starts empty and is appended only when
        // a player shows, so opponents' hole cards are not in the room row mid-hand.

        struct Payload: Encodable {
            let id: String
            let game_mode: String
            let phase: String
            let host_id: String
            let public_state: GameState
            let updated_at: String
        }

        let payload = Payload(
            id:           roomID,
            game_mode:    state.gameMode.rawValue,
            phase:        state.phase.supabaseValue,
            host_id:      state.hostID ?? ProfileService.deviceID,
            public_state: pub,
            updated_at:   timestampFormatter.string(from: Date())
        )
        try await SupabaseClient.shared.upsert(path: "game_rooms", body: payload)
    }
}

// MARK: - Private Decodable row type

private struct GameRoomRow: Decodable {
    let id: String
    let hostID: String?
    let publicState: GameState
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case publicState = "public_state"
        case updatedAt   = "updated_at"
    }
}

// MARK: - GamePhase → Supabase column string

private extension GamePhase {
    var supabaseValue: String {
        switch self {
        case .waiting:     return "waiting"
        case .playing:     return "playing"
        case .showdown:    return "showdown"
        case .handSummary: return "handSummary"
        case .ended:       return "ended"
        }
    }
}
