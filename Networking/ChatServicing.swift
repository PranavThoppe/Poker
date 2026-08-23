import Foundation

@MainActor
protocol ChatServicing: AnyObject {
    func loadMessages(roomID: String) async throws -> [ChatMessage]

    func subscribe(
        roomID: String,
        onMessage: @escaping @MainActor (ChatMessage) -> Void
    ) -> UUID

    func send(message: ChatMessage) async throws
    func unsubscribe(subscriptionID: UUID)
}

@MainActor
final class InMemoryChatService: ChatServicing {
    static let shared = InMemoryChatService()

    private var messagesByRoom: [String: [ChatMessage]]
    private var subscriptions: [UUID: (roomID: String, onMessage: @MainActor (ChatMessage) -> Void)] = [:]

    init(messages: [ChatMessage] = []) {
        messagesByRoom = Dictionary(grouping: messages, by: \.roomID)
    }

    func loadMessages(roomID: String) async throws -> [ChatMessage] {
        sorted(messagesByRoom[roomID] ?? [])
    }

    func subscribe(
        roomID: String,
        onMessage: @escaping @MainActor (ChatMessage) -> Void
    ) -> UUID {
        let subscriptionID = UUID()
        subscriptions[subscriptionID] = (roomID, onMessage)
        return subscriptionID
    }

    func send(message: ChatMessage) async throws {
        var roomMessages = messagesByRoom[message.roomID] ?? []
        guard !roomMessages.contains(where: { $0.id == message.id }) else { return }

        roomMessages.append(message)
        messagesByRoom[message.roomID] = sorted(roomMessages)

        for subscription in subscriptions.values where subscription.roomID == message.roomID {
            subscription.onMessage(message)
        }
    }

    func unsubscribe(subscriptionID: UUID) {
        subscriptions[subscriptionID] = nil
    }

    private func sorted(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }
}
