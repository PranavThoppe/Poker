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

    // MARK: - DELETE

    func delete(path: String, query: [String: String] = [:]) async throws {
        guard var components = URLComponents(string: SupabaseConstants.projectURL + "/rest/v1/" + path) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyHeaders(to: &request)
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

    /// Calls an Edge Function with the project publishable key. Game state must
    /// use this path; REST remains only for non-game features.
    func function<T: Decodable>(_ name: String, body: some Encodable) async throws -> T {
        guard let url = URL(string: SupabaseConstants.projectURL + "/functions/v1/" + name) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, contentType: true)
        request.httpBody = try encoder.encode(body)
        // A Function can take a moment to resume after being idle. Retrying only
        // transport and temporary-server failures keeps the UI responsive without
        // hiding authentication or validation errors. Game room creation and
        // commands are idempotent on the server, so repeating this request is safe.
        let (data, response) = try await performFunctionRequest(request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(GameAPIErrorEnvelope.self, from: data) {
                throw GameAPIClientError.server(status: http.statusCode, code: failure.error.code, message: failure.error.message)
            }
            throw GameAPIClientError.server(status: http.statusCode, code: "http_\(http.statusCode)", message: nil)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func performFunctionRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let retryDelays: [Duration] = [.milliseconds(400), .seconds(1)]
        for attempt in 0...retryDelays.count {
            do {
                let result = try await session.data(for: request)
                if let response = result.1 as? HTTPURLResponse,
                   shouldRetry(status: response.statusCode), attempt < retryDelays.count {
                    try await Task.sleep(for: retryDelays[attempt])
                    continue
                }
                return result
            } catch let error as URLError where attempt < retryDelays.count && isTransient(error) {
                try await Task.sleep(for: retryDelays[attempt])
            }
        }
        // The loop either returned a response or the final request threw.
        throw URLError(.cannotConnectToHost)
    }

    private func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
         .dnsLookupFailed, .internationalRoamingOff].contains(error.code)
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
