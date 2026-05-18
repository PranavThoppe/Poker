import Foundation

/// Protocol that any real-time sync backend must conform to.
/// Today only `MockSync` exists; a `SupabaseSync` will implement this later.
protocol GameSyncing: AnyObject {
    /// Subscribe to state changes from remote players.
    /// The closure is called on the main actor whenever a new state arrives.
    func subscribe(roomID: String, onUpdate: @escaping @MainActor (GameState) -> Void)

    /// Publish a local state change to all other participants.
    func publish(state: GameState, roomID: String)

    /// Tear down the subscription.
    func unsubscribe(roomID: String)
}

// MARK: - Message URL (iMessage bubble)

enum GameMessageURL {
    // MSMessage.url silently drops non-HTTPS URLs, so we use a fake HTTPS host
    // to encode game state. The domain is never actually contacted.
    private static let host = "poker.game"
    private static let path = "/session"

    /// Encodes game identity for `MSMessage.url`
    /// (e.g. `https://poker.game/session?id=<UUID>&phase=waiting`).
    static func encode(gameID: UUID, phase: GamePhase) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "id", value: gameID.uuidString),
            URLQueryItem(name: "phase", value: phase.urlQueryValue),
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid poker message URL components for gameID \(gameID), phase \(phase)")
        }
        return url
    }

    /// Parses `encode(gameID:phase:)` URLs; returns nil if the URL is not a poker game link.
    static func decode(from url: URL) -> (gameID: UUID, phase: GamePhase)? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        guard let idString = items["id"],
              let gameID = UUID(uuidString: idString),
              let phaseString = items["phase"],
              let phase = GamePhase(urlQueryValue: phaseString) else { return nil }
        return (gameID, phase)
    }
}

private extension GamePhase {
    var urlQueryValue: String {
        switch self {
        case .waiting: return "waiting"
        case .playing: return "playing"
        case .ended: return "ended"
        }
    }

    init?(urlQueryValue: String) {
        switch urlQueryValue.lowercased() {
        case "waiting": self = .waiting
        case "playing": self = .playing
        case "ended": self = .ended
        default: return nil
        }
    }
}

// MARK: - No-op mock

final class MockSync: GameSyncing {
    func subscribe(roomID: String, onUpdate: @escaping @MainActor (GameState) -> Void) {}
    func publish(state: GameState, roomID: String) {}
    func unsubscribe(roomID: String) {}
}
