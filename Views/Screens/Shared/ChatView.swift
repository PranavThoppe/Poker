import SwiftUI

@MainActor
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: ChatStore
    @State private var draft = ""
    @FocusState private var composerIsFocused: Bool

    init(roomID: String, currentPlayer: Player) {
        self.init(
            roomID: roomID,
            currentPlayer: currentPlayer,
            service: InMemoryChatService.shared
        )
    }

    init(
        roomID: String,
        currentPlayer: Player,
        service: ChatServicing
    ) {
        _store = StateObject(
            wrappedValue: ChatStore(
                roomID: roomID,
                localPlayer: currentPlayer,
                service: service
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                composer
            }
            .background(Theme.Color.background)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.Color.primary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await store.start()
        }
        .onDisappear {
            store.stop()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    if store.isLoading && store.messages.isEmpty {
                        ProgressView("Loading messages…")
                            .foregroundStyle(Theme.Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let loadError = store.loadError, store.messages.isEmpty {
                        ChatStatusView(
                            systemName: "exclamationmark.bubble.fill",
                            title: "Chat unavailable",
                            detail: loadError
                        )
                    } else if store.messages.isEmpty {
                        ChatStatusView(
                            systemName: "bubble.left.and.bubble.right",
                            title: "No messages yet",
                            detail: "Start the table talk."
                        )
                    } else {
                        ForEach(store.messages) { message in
                            ChatMessageRow(
                                message: message,
                                isLocal: message.senderID == store.localPlayer.id
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding(Theme.Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) {
                guard let lastMessageID = store.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastMessageID, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let sendError = store.sendError {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(sendError)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.red)
                    Spacer()
                    Button("Dismiss") { store.dismissSendError() }
                        .font(Theme.Font.caption)
                }
                .padding(.horizontal, Theme.Spacing.xs)
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                TextField("Message the table", text: $draft, axis: .vertical)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.primary)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
                    .focused($composerIsFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .onChange(of: draft) { _, newValue in
                        if newValue.count > ChatMessage.maximumBodyLength {
                            draft = String(newValue.prefix(ChatMessage.maximumBodyLength))
                        }
                    }

                Button(action: sendDraft) {
                    Group {
                        if store.isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundStyle(canSend ? Theme.Color.background : Theme.Color.secondary)
                    .frame(width: 42, height: 42)
                    .background(canSend ? Theme.Color.primary : Theme.Color.surface)
                    .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.Color.surfaceDeep)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending
    }

    private func sendDraft() {
        guard canSend else { return }
        let body = draft
        Task {
            if await store.send(body: body) {
                draft = ""
                composerIsFocused = true
            }
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let isLocal: Bool

    private var sender: Player {
        Player(
            id: message.senderID,
            name: message.senderName,
            stack: 0,
            avatarIndex: message.senderAvatarIndex
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            if isLocal { Spacer(minLength: 52) }

            if !isLocal {
                AvatarView(player: sender, size: Theme.Size.avatarSM)
            }

            VStack(alignment: isLocal ? .trailing : .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(isLocal ? "You" : message.senderName)
                        .font(Theme.Font.playerName)
                        .foregroundStyle(isLocal ? Theme.Color.primary : Theme.Color.secondary)
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondary)
                }

                Text(message.body)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.primary)
                    .multilineTextAlignment(isLocal ? .trailing : .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isLocal ? Theme.Color.green.opacity(0.45) : Theme.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
            }

            if isLocal {
                AvatarView(player: sender, size: Theme.Size.avatarSM)
            } else {
                Spacer(minLength: 52)
            }
        }
    }
}

private struct ChatStatusView: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemName)
                .font(.system(size: 30))
                .foregroundStyle(Theme.Color.secondary)
            Text(title)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.primary)
            Text(detail)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(Theme.Spacing.lg)
    }
}

@MainActor
private final class PreviewErrorChatService: ChatServicing {
    private struct PreviewError: Error {}

    func loadMessages(roomID: String) async throws -> [ChatMessage] {
        throw PreviewError()
    }

    func subscribe(
        roomID: String,
        onMessage: @escaping @MainActor (ChatMessage) -> Void
    ) -> UUID {
        UUID()
    }

    func send(message: ChatMessage) async throws {
        throw PreviewError()
    }

    func unsubscribe(subscriptionID: UUID) {}
}

private let previewChatPlayer = Player(
    id: "hero",
    name: "Pranav",
    stack: 480,
    avatarIndex: 8
)

#Preview("Empty Chat") {
    ChatView(
        roomID: "empty-room",
        currentPlayer: previewChatPlayer,
        service: InMemoryChatService()
    )
}

#Preview("Populated Chat") {
    ChatView(
        roomID: "preview-room",
        currentPlayer: previewChatPlayer,
        service: InMemoryChatService(
            messages: ChatMessage.mockMessages(localPlayerID: previewChatPlayer.id)
        )
    )
}

#Preview("Chat Error") {
    ChatView(
        roomID: "error-room",
        currentPlayer: previewChatPlayer,
        service: PreviewErrorChatService()
    )
}
