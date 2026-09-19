import Foundation

/// Commands travel only from the app to the Edge Function; responses never
/// decode commands, so requiring `Decodable` is both unnecessary and invalid.
enum GameCommand: Encodable, Equatable {
    case setReady(Bool)
    case startGame
    case bet(kind: String, amount: Int?)
    case showCards
    case advanceSummary
    case startNextHand
    case setSittingOut(Bool)
    case raiseBlinds(Int)
    case endGame(GameEndReason)
    case resetRoom

    enum CodingKeys: String, CodingKey { case kind, ready, betKind, amount, sittingOut, smallBlind, reason }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setReady(let ready): try c.encode("setReady", forKey: .kind); try c.encode(ready, forKey: .ready)
        case .startGame: try c.encode("startGame", forKey: .kind)
        case .bet(let kind, let amount): try c.encode("bet", forKey: .kind); try c.encode(kind, forKey: .betKind); try c.encodeIfPresent(amount, forKey: .amount)
        case .showCards: try c.encode("showCards", forKey: .kind)
        case .advanceSummary: try c.encode("advanceSummary", forKey: .kind)
        case .startNextHand: try c.encode("startNextHand", forKey: .kind)
        case .setSittingOut(let value): try c.encode("setSittingOut", forKey: .kind); try c.encode(value, forKey: .sittingOut)
        case .raiseBlinds(let value): try c.encode("raiseBlinds", forKey: .kind); try c.encode(value, forKey: .smallBlind)
        case .endGame(let reason): try c.encode("endGame", forKey: .kind); try c.encode(reason, forKey: .reason)
        case .resetRoom: try c.encode("resetRoom", forKey: .kind)
        }
    }
}

struct GameAPIRequest: Encodable {
    let operation: String
    let roomID: UUID
    let playerID: String
    var playerName: String?
    var avatarIndex: Int?
    var actionID: UUID?
    var expectedVersion: Int?
    var expectedHandID: UUID?
    var command: GameCommand?
}

struct GameAPIResponse: Decodable {
    let ok: Bool
    let serverVersion: Int?
    let state: GameState?
    let deadlineAt: String?
}

struct GameAPIErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String? }
    let ok: Bool
    let error: Detail
}

enum GameAPIClientError: LocalizedError {
    case server(status: Int, code: String, message: String?)
    var errorDescription: String? {
        switch self { case let .server(_, code, message): return message ?? code }
    }
}

/// The only Classic Poker writer. Reuse `actionID` when retrying a failed
/// request so the server returns its receipt instead of applying a second bet.
struct GameCommandClient {
    static let shared = GameCommandClient()
    private init() {}

    func createRoom(roomID: UUID, playerID: String, name: String, avatarIndex: Int) async throws -> GameAPIResponse {
        try await invoke(GameAPIRequest(operation: "create-room", roomID: roomID, playerID: playerID, playerName: name, avatarIndex: avatarIndex))
    }
    func joinRoom(roomID: UUID, playerID: String, name: String, avatarIndex: Int) async throws -> GameAPIResponse {
        try await invoke(GameAPIRequest(operation: "join-room", roomID: roomID, playerID: playerID, playerName: name, avatarIndex: avatarIndex))
    }
    func roomState(roomID: UUID, playerID: String) async throws -> GameAPIResponse {
        try await invoke(GameAPIRequest(operation: "room-state", roomID: roomID, playerID: playerID))
    }
    func submit(roomID: UUID, playerID: String, version: Int, handID: UUID?, command: GameCommand, actionID: UUID = UUID()) async throws -> GameAPIResponse {
        try await invoke(GameAPIRequest(operation: "game-command", roomID: roomID, playerID: playerID, actionID: actionID, expectedVersion: version, expectedHandID: handID, command: command))
    }
    private func invoke(_ request: GameAPIRequest) async throws -> GameAPIResponse {
        try await SupabaseClient.shared.function("game-api", body: request)
    }
}
