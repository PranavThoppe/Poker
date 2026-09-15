import Foundation
import Combine

/// Durable lifetime count of hands in which this device was dealt cards.
/// Local credits are immediate; failed remote credits are retried on launch.
@MainActor
final class HandsPlayedStatsService: ObservableObject {

    static let shared = HandsPlayedStatsService()

    @Published private(set) var lifetimeHandsPlayed = 0

    private var creditedHandIDs: Set<UUID> = []
    private var pendingRemoteCredits: [PendingRemoteHandCredit] = []
    private let defaults: UserDefaults
    private let client: SupabaseClient
    private let playerID: () -> String

    init(
        defaults: UserDefaults = .standard,
        client: SupabaseClient = .shared,
        playerID: @escaping () -> String = { ProfileService.deviceID }
    ) {
        self.defaults = defaults
        self.client = client
        self.playerID = playerID
        loadLocal()
    }

    /// Call only after a hand has reached its summary. A hand ID makes both local and
    /// server credits idempotent when a state is replayed or a request is retried.
    func recordCompletedHand(handID: UUID, gameMode: GameMode) {
        guard !creditedHandIDs.contains(handID) else { return }
        creditedHandIDs.insert(handID)
        lifetimeHandsPlayed += 1
        if !pendingRemoteCredits.contains(where: { $0.handID == handID }) {
            pendingRemoteCredits.append(PendingRemoteHandCredit(handID: handID, gameMode: gameMode))
        }
        persistLocal()
        Task { await pushPendingCredits() }
    }

    func reconcileWithRemote() async {
        await pushPendingCredits()
        await fetchAndReconcileLifetimeHandsPlayed()
    }

    private enum Keys {
        static let lifetimeHandsPlayed = "handsPlayedStats.lifetimeHandsPlayed"
        static let creditedHandIDs = "handsPlayedStats.creditedHandIDs"
        static let pendingRemoteCredits = "handsPlayedStats.pendingRemoteCredits"
    }

    private func loadLocal() {
        lifetimeHandsPlayed = defaults.integer(forKey: Keys.lifetimeHandsPlayed)
        creditedHandIDs = Set(
            (defaults.stringArray(forKey: Keys.creditedHandIDs) ?? []).compactMap(UUID.init(uuidString:))
        )
        if let data = defaults.data(forKey: Keys.pendingRemoteCredits),
           let pending = try? JSONDecoder().decode([PendingRemoteHandCredit].self, from: data) {
            pendingRemoteCredits = pending
        }
    }

    private func persistLocal() {
        defaults.set(lifetimeHandsPlayed, forKey: Keys.lifetimeHandsPlayed)
        defaults.set(creditedHandIDs.map(\.uuidString), forKey: Keys.creditedHandIDs)
        if let data = try? JSONEncoder().encode(pendingRemoteCredits) {
            defaults.set(data, forKey: Keys.pendingRemoteCredits)
        }
    }

    private func pushPendingCredits() async {
        guard !pendingRemoteCredits.isEmpty else { return }
        var remaining: [PendingRemoteHandCredit] = []
        for credit in pendingRemoteCredits {
            do {
                try await client.rpc("credit_hand_played", body: CreditHandPlayedRPC(
                    handID: credit.handID,
                    playerID: playerID(),
                    gameMode: credit.gameMode
                ))
            } catch {
                remaining.append(credit)
            }
        }
        pendingRemoteCredits = remaining
        persistLocal()
    }

    private func fetchAndReconcileLifetimeHandsPlayed() async {
        struct ProfileHandsRow: Decodable {
            let lifetimeHandsPlayed: Int
            enum CodingKeys: String, CodingKey {
                case lifetimeHandsPlayed = "lifetime_hands_played"
            }
        }
        do {
            let rows: [ProfileHandsRow] = try await client.get(
                path: "profiles",
                query: [
                    "id": "eq.\(playerID())",
                    "select": "lifetime_hands_played"
                ]
            )
            guard let remote = rows.first?.lifetimeHandsPlayed else { return }
            let reconciled = max(lifetimeHandsPlayed, remote)
            guard reconciled != lifetimeHandsPlayed else { return }
            lifetimeHandsPlayed = reconciled
            persistLocal()
        } catch {
            // The local count remains usable while offline or before the migration runs.
        }
    }
}

private struct PendingRemoteHandCredit: Codable, Equatable {
    let handID: UUID
    let gameMode: GameMode
}

private struct CreditHandPlayedRPC: Encodable {
    let p_hand_id: UUID
    let p_player_id: String
    let p_game_mode: String

    init(handID: UUID, playerID: String, gameMode: GameMode) {
        p_hand_id = handID
        p_player_id = playerID
        p_game_mode = gameMode.rawValue
    }
}
