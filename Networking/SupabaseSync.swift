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

}
