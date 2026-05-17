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

// MARK: - No-op mock

final class MockSync: GameSyncing {
    func subscribe(roomID: String, onUpdate: @escaping @MainActor (GameState) -> Void) {}
    func publish(state: GameState, roomID: String) {}
    func unsubscribe(roomID: String) {}
}
