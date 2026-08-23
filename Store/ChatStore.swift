import Foundation
import Combine

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var loadError: String?
    @Published private(set) var sendError: String?

    let roomID: String
    let localPlayer: Player

    private let service: ChatServicing
    private var subscriptionID: UUID?
    private var hasStarted = false

    init(roomID: String, localPlayer: Player, service: ChatServicing) {
        self.roomID = roomID
        self.localPlayer = localPlayer
        self.service = service
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        isLoading = true
        loadError = nil

        subscriptionID = service.subscribe(roomID: roomID) { [weak self] message in
            self?.merge(message)
        }

        do {
            merge(try await service.loadMessages(roomID: roomID))
        } catch {
            loadError = "Messages couldn’t be loaded. Pull down and reopen chat to try again."
        }

        isLoading = false
    }

    @discardableResult
    func send(body: String) async -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty, !isSending else { return false }

        let limitedBody = String(trimmedBody.prefix(ChatMessage.maximumBodyLength))
        let message = ChatMessage(
            roomID: roomID,
            senderID: localPlayer.id,
            senderName: localPlayer.name,
            senderAvatarIndex: localPlayer.avatarIndex,
            body: limitedBody
        )

        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            try await service.send(message: message)
            return true
        } catch {
            sendError = "Message couldn’t be sent. Check your connection and try again."
            return false
        }
    }

    func stop() {
        if let subscriptionID {
            service.unsubscribe(subscriptionID: subscriptionID)
        }
        subscriptionID = nil
        hasStarted = false
    }

    func dismissSendError() {
        sendError = nil
    }

    private func merge(_ message: ChatMessage) {
        guard message.roomID == roomID else { return }
        merge([message])
    }

    private func merge(_ incomingMessages: [ChatMessage]) {
        let roomMessages = incomingMessages.filter { $0.roomID == roomID }
        guard !roomMessages.isEmpty else { return }

        var messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in roomMessages {
            messagesByID[message.id] = message
        }

        messages = messagesByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }
}
