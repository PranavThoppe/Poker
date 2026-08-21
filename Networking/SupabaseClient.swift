import Foundation

/// Thin URLSession wrapper for the Supabase REST v1 API.
struct SupabaseClient {
    static let shared = SupabaseClient()
    private init() {}

    private let session = URLSession.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - GET

    func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(string: SupabaseConstants.projectURL + "/rest/v1/" + path) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - RPC

    func rpc(_ function: String, body: some Encodable) async throws {
        guard let url = URL(string: SupabaseConstants.projectURL + "/rest/v1/rpc/" + function) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, contentType: true)
        request.httpBody = try encoder.encode(body)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    // MARK: - POST / Upsert

    /// POSTs a JSON body with `Prefer: resolution=merge-duplicates` — upserts on conflict.
    func upsert(path: String, body: some Encodable) async throws {
        guard let url = URL(string: SupabaseConstants.projectURL + "/rest/v1/" + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, contentType: true)
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(body)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    // MARK: - Private helpers

    private func applyHeaders(to request: inout URLRequest, contentType: Bool = false) {
        request.setValue(SupabaseConstants.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConstants.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if contentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
