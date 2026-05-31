import Foundation
import UIKit
import Combine

// MARK: - Local model

struct LocalProfile {
    let id: String
    let displayName: String
    let avatarIndex: Int
}

// MARK: - Service

@MainActor
final class ProfileService: ObservableObject {

    static let shared = ProfileService()

    // Stable device identifier; falls back to a new UUID if the vendor ID is unavailable.
    static let deviceID: String = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    @Published private(set) var profile: LocalProfile?

    private init() {
        profile = loadLocal()
    }

    // MARK: - UserDefaults persistence

    private enum Keys {
        static let name   = "profileName"
        static let avatar = "profileAvatar"
    }

    func loadLocal() -> LocalProfile? {
        guard let name = UserDefaults.standard.string(forKey: Keys.name) else { return nil }
        let avatarIndex = UserDefaults.standard.integer(forKey: Keys.avatar)
        return LocalProfile(id: Self.deviceID, displayName: name, avatarIndex: avatarIndex)
    }

    private func persistLocal(name: String, avatarIndex: Int) {
        UserDefaults.standard.set(name, forKey: Keys.name)
        UserDefaults.standard.set(avatarIndex, forKey: Keys.avatar)
    }

    // MARK: - Supabase REST upsert

    /// Upserts the profile row in Supabase `profiles` table, then persists locally.
    func saveProfile(name: String, avatarIndex: Int) async throws {
        let body: [String: Any] = [
            "id":           Self.deviceID,
            "display_name": name,
            "avatar_index": avatarIndex
        ]
        try await upsertProfile(body: body)
        persistLocal(name: name, avatarIndex: avatarIndex)
        profile = LocalProfile(id: Self.deviceID, displayName: name, avatarIndex: avatarIndex)
    }

    private func upsertProfile(body: [String: Any]) async throws {
        let urlString = SupabaseConstants.projectURL + "/rest/v1/profiles"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConstants.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConstants.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Prefer upsert behaviour: on conflict, update existing row.
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}
