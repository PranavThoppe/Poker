import Foundation
import Combine

/// Local + remote lifetime game-win tracking for Classic Poker.
///
/// Local UserDefaults is the source of truth on this device. Supabase stores a
/// durable copy (`profiles.lifetime_wins`) plus an idempotency ledger
/// (`game_win_credits`). Network failures do not roll back a local credit;
/// pending rows retry on the next launch or profile save.
@MainActor
final class WinStatsService: ObservableObject {

    static let shared = WinStatsService()

    /// Minimum humans who must have joined for a session win to count.
    static let minimumHumanPlayers = 2
    /// Minimum completed hands required before a session win is credited.
    static let minimumCompletedHands = 1

    @Published private(set) var lifetimeWins: Int = 0

    private var creditedGameIDs: Set<UUID> = []
    private var pendingRemoteCredits: [PendingRemoteCredit] = []

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

    // MARK: - Credit

    /// Records a session win on the winner's device only. Safe to call from
    /// `endGame()` on every client — ineligible devices no-op.
    func recordGameWinIfEligible(
        gameID: UUID,
        gameMode: GameMode,
        endStats: [PlayerStats],
        endReason: GameEndReason,
        humanCount: Int,
        completedHands: Int
    ) {
        guard isEligible(
            gameID: gameID,
            gameMode: gameMode,
            endStats: endStats,
            endReason: endReason,
            humanCount: humanCount,
            completedHands: completedHands
        ) else { return }

        creditLocally(gameID: gameID)
        Task { await pushPendingCredits() }
    }

    // MARK: - Remote sync

    /// Fetches `profiles.lifetime_wins` and keeps the higher of local vs remote.
    /// Also retries any credits that have not yet landed in Supabase.
    func reconcileWithRemote() async {
        await pushPendingCredits()
        await fetchAndReconcileLifetimeWins()
    }

    // MARK: - Eligibility

    private func isEligible(
        gameID: UUID,
        gameMode: GameMode,
        endStats: [PlayerStats],
        endReason: GameEndReason,
        humanCount: Int,
        completedHands: Int
    ) -> Bool {
        guard gameMode == .classicPoker else { return false }
        guard endReason != .manualFinishTieForfeit else { return false }
        guard humanCount >= Self.minimumHumanPlayers else { return false }
        guard completedHands >= Self.minimumCompletedHands else { return false }
        guard !creditedGameIDs.contains(gameID) else { return false }

        let winners = endStats.filter(\.isWinner)
        guard winners.count == 1, winners[0].id == playerID() else { return false }
        return true
    }

    // MARK: - UserDefaults

    private enum Keys {
        static let lifetimeWins = "winStats.lifetimeWins"
        static let creditedGameIDs = "winStats.creditedGameIDs"
        static let pendingRemoteCredits = "winStats.pendingRemoteCredits"
    }

    private func loadLocal() {
        lifetimeWins = defaults.integer(forKey: Keys.lifetimeWins)
        creditedGameIDs = Set(
            (defaults.stringArray(forKey: Keys.creditedGameIDs) ?? []).compactMap(UUID.init(uuidString:))
        )
        if let data = defaults.data(forKey: Keys.pendingRemoteCredits),
           let pending = try? JSONDecoder().decode([PendingRemoteCredit].self, from: data) {
            pendingRemoteCredits = pending
        }
    }

    private func persistLocal() {
        defaults.set(lifetimeWins, forKey: Keys.lifetimeWins)
        defaults.set(creditedGameIDs.map(\.uuidString), forKey: Keys.creditedGameIDs)
        if let data = try? JSONEncoder().encode(pendingRemoteCredits) {
            defaults.set(data, forKey: Keys.pendingRemoteCredits)
        }
    }

    private func creditLocally(gameID: UUID) {
        creditedGameIDs.insert(gameID)
        lifetimeWins += 1
        enqueuePending(gameID: gameID)
        persistLocal()
    }

    private func enqueuePending(gameID: UUID) {
        let credit = PendingRemoteCredit(gameID: gameID)
        guard !pendingRemoteCredits.contains(credit) else { return }
        pendingRemoteCredits.append(credit)
    }

    // MARK: - Supabase

    private func pushPendingCredits() async {
        guard !pendingRemoteCredits.isEmpty else { return }
        var remaining: [PendingRemoteCredit] = []
        for credit in pendingRemoteCredits {
            do {
                try await pushCredit(credit)
            } catch {
                remaining.append(credit)
            }
        }
        pendingRemoteCredits = remaining
        persistLocal()
    }

    private func pushCredit(_ credit: PendingRemoteCredit) async throws {
        try await client.rpc(
            "credit_game_win",
            body: CreditGameWinRPC(
                gameID: credit.gameID,
                playerID: playerID()
            )
        )
    }

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
            let reconciled = max(lifetimeWins, remote)
            guard reconciled != lifetimeWins else { return }
            lifetimeWins = reconciled
            persistLocal()
        } catch {
            // Column or network missing — local count still stands.
        }
    }
}

// MARK: - Payloads

private struct PendingRemoteCredit: Codable, Equatable {
    let gameID: UUID
}

private struct CreditGameWinRPC: Encodable {
    let p_game_id: UUID
    let p_player_id: String

    init(gameID: UUID, playerID: String) {
        p_game_id = gameID
        p_player_id = playerID
    }
}
