import Foundation

/// Implements read-only `GameSyncing` by polling the viewer-scoped Edge Function.
///
/// Sync model (turn-based, so 2-second polling is sufficient):
/// - `subscribe` starts a Task loop that calls `room-state` every 2 s.
///   Change detection uses the monotonic `stateVersion` carried inside `public_state`;
///   older writes are dropped and duplicates are skipped. `updated_at` only breaks ties
///   between two writes that share a version.
/// - There is no client-side publish path and the response includes only this
///   device's cards.
final class SupabaseSync: GameSyncing {

    private var pollTask: Task<Void, Never>?

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
                    guard let id = UUID(uuidString: roomID) else { return }
                    let response = try await GameCommandClient.shared.roomState(roomID: id, playerID: ProfileService.deviceID)
                    guard let remote = response.state else { return }
                    let version = response.serverVersion ?? remote.version
                    if let seen = lastSeenVersion {
                        // Never move backwards, and skip a version we have already merged
                        // unless a second write landed on it.
                        if version < seen { return }
                        if version == seen { return }
                    }
                    lastSeenVersion = version
                    lastSeenUpdatedAt = String(version)
                    await MainActor.run {
                        GameLog.remoteStateReceived(state: remote)
                    }
                    await onUpdate(remote, remote.hostID)
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

    func unsubscribe(roomID: String) {
        pollTask?.cancel()
        pollTask = nil
        GameLog.subscriptionStopped(roomID: roomID)
    }

    // Private cards are intentionally unavailable here; `room-state` provides
    // only the current viewer's cards.

    /// Host writes each player's private hole cards after dealing.
    func upsertHoleCards(
        roomID: String,
        playerID: String,
        handID: UUID,
        cards: [Card]
    ) async throws {
        throw GameAPIClientError.server(status: 410, code: "legacy_private_card_write_disabled", message: nil)
    }

    /// Removes every private-card row for the room before a new deal is written.
    func deleteAllHoleCards(roomID: String) async throws {
        // Kept as a compatibility shim while old rooms are readable. New
        // server-authoritative rooms keep cards solely in private_state.
    }

    /// Guest fetches their own hole cards after the host has dealt.
    func fetchHoleCards(roomID: String, playerID: String, handID: UUID) async throws -> [Card]? {
        return nil
    }

    /// Host recovery: re-reads every seat's cards so a relaunched host can still run a showdown.
    func fetchAllHoleCards(roomID: String, handID: UUID) async throws -> [String: [Card]] {
        return [:]
    }

    // MARK: - Private

}

// MARK: - Private Decodable row type
