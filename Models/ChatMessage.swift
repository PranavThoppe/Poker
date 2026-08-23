import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    static let maximumBodyLength = 280

    let id: UUID
    let roomID: String
    let senderID: String
    let senderName: String
    let senderAvatarIndex: Int
    let body: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        roomID: String,
        senderID: String,
        senderName: String,
        senderAvatarIndex: Int,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarIndex = senderAvatarIndex
        self.body = body
        self.createdAt = createdAt
    }
}

extension ChatMessage {
    static func mockMessages(
        roomID: String = "preview-room",
        localPlayerID: String = "hero"
    ) -> [ChatMessage] {
        let now = Date()
        return [
            ChatMessage(
                roomID: roomID,
                senderID: "maya",
                senderName: "Maya",
                senderAvatarIndex: 3,
                body: "Good luck everyone!",
                createdAt: now.addingTimeInterval(-180)
            ),
            ChatMessage(
                roomID: roomID,
                senderID: localPlayerID,
                senderName: "You",
                senderAvatarIndex: 8,
                body: "You too — let’s play.",
                createdAt: now.addingTimeInterval(-120)
            ),
            ChatMessage(
                roomID: roomID,
                senderID: "leo",
                senderName: "Leo",
                senderAvatarIndex: 24,
                body: "That river card was wild 😅",
                createdAt: now.addingTimeInterval(-45)
            ),
        ]
    }
}
