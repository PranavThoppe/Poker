import Foundation
import Combine

/// Reads the server-authoritative lifetime win count for this device.
/// Classic Poker credits are written atomically with the server game-end transition.
@MainActor
final class WinStatsService: ObservableObject {

    static let shared = WinStatsService()

    @Published private(set) var lifetimeWins: Int = 0

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

    // MARK: - Remote sync

    /// Fetches the server-authoritative `profiles.lifetime_wins` value.
    func reconcileWithRemote() async {
        await fetchAndReconcileLifetimeWins()
    }

    // MARK: - UserDefaults

    private enum Keys {
        static let lifetimeWins = "winStats.lifetimeWins"
    }

    private func loadLocal() {
        lifetimeWins = defaults.integer(forKey: Keys.lifetimeWins)
    }

    private func persistLocal() {
        defaults.set(lifetimeWins, forKey: Keys.lifetimeWins)
    }

    // MARK: - Supabase

    private func fetchRemoteLifetimeWins() async throws -> Int? {
        struct ProfileWinsRow: Decodable {
            let lifetimeWins: Int
            enum CodingKeys: String, CodingKey {
                case lifetimeWins = "lifetime_wins"
            }
        }
        let rows: [ProfileWinsRow] = try await client.get(
            path: "profiles",
            query: [
                "id": "eq.\(playerID())",
                "select": "lifetime_wins"
            ]
        )
        return rows.first?.lifetimeWins
    }

    private func fetchAndReconcileLifetimeWins() async {
        do {
            guard let remote = try await fetchRemoteLifetimeWins() else { return }
            guard remote != lifetimeWins else { return }
            lifetimeWins = remote
            persistLocal()
        } catch {
            // Column or network missing — local count still stands.
        }
    }
}
