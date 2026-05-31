import SwiftUI

struct OnboardingView: View {
    /// Called when onboarding completes successfully.
    var onComplete: () -> Void

    @StateObject private var service = ProfileService.shared

    @State private var displayName: String = ""
    @State private var selectedAvatarIndex: Int? = nil
    @State private var isSaving: Bool = false
    @State private var isShuffling: Bool = false
    @State private var spinResults: [Int] = []   // stores final index of each completed spin
    @State private var errorMessage: String? = nil

    private let avatarCount = 30
    private let maxNameLength = 20

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer().frame(height: Theme.Spacing.xl)

                selectedAvatarPreview

                Spacer().frame(height: Theme.Spacing.xl)

                nameField

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.red)
                        .padding(.top, Theme.Spacing.sm)
                }

                Spacer()

                letsPlayButton

                Spacer().frame(height: Theme.Spacing.lg)
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer().frame(height: Theme.Spacing.lg)
            Text("Create Your Profile")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Color.primary)
            Text("Choose an avatar and pick a name")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    private var selectedAvatarPreview: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if spinResults.count < 2 {
                // Spinning phase — empty until first spin, then live avatar
                if spinResults.isEmpty && !isShuffling {
                    emptyAvatarPlaceholder(size: 80)
                } else if let index = selectedAvatarIndex {
                    AvatarView(
                        player: previewPlayer(avatarIndex: index),
                        size: 80
                    )
                }

                Button(action: startShuffle) {
                    Label(spinResults.count == 1 ? "1 more spin" : "Shuffle", systemImage: "shuffle")
                        .font(Theme.Font.subhead)
                        .foregroundStyle(isShuffling ? Theme.Color.secondary : Theme.Color.primary)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(height: 40)
                        .background(Theme.Color.surface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Theme.Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isShuffling)
                .opacity(isShuffling ? 0.6 : 1)
                .padding(.top, Theme.Spacing.sm)
            } else {
                // Both spins done — let the user pick between the two results
                Text("Pick your avatar")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondary)

                HStack(spacing: Theme.Spacing.xl) {
                    ForEach(spinResults.indices, id: \.self) { i in
                        let index = spinResults[i]
                        let isChosen = selectedAvatarIndex == index
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedAvatarIndex = index
                            }
                        } label: {
                            AvatarView(player: previewPlayer(avatarIndex: index), size: 72)
                                .padding(6)
                                .background(
                                    Circle()
                                        .strokeBorder(
                                            isChosen ? Theme.Color.primary : Color.clear,
                                            lineWidth: 2.5
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func emptyAvatarPlaceholder(size: CGFloat) -> some View {
        Circle()
            .fill(Theme.Color.surface)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(Theme.Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }

    private var avatarPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(0..<avatarCount, id: \.self) { index in
                    avatarOption(for: index)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private func avatarOption(for index: Int) -> some View {
        let isSelected = index == selectedAvatarIndex
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedAvatarIndex = index
            }
        } label: {
            AvatarView(
                player: previewPlayer(avatarIndex: index),
                size: Theme.Size.avatarMD
            )
            .padding(6)
            .background(
                Circle()
                    .strokeBorder(
                        isSelected ? Theme.Color.primary : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Display Name")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.secondary)

            TextField("", text: $displayName)
                .onChange(of: displayName) { _, newValue in
                    if newValue.count > maxNameLength {
                        displayName = String(newValue.prefix(maxNameLength))
                    }
                }
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.primary)
                .padding(Theme.Spacing.md)
                .background(Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill)
                        .strokeBorder(Theme.Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
        }
    }

    private var letsPlayButton: some View {
        Button(action: save) {
            Group {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Color.background)
                } else {
                    Text("Let's Play")
                        .font(Theme.Font.actionLabel)
                        .foregroundStyle(canSave ? Theme.Color.background : Theme.Color.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
            .background(canSave ? Theme.Color.primary : Theme.Color.surfaceDeep)
            .clipShape(Capsule())
        }
        .disabled(!canSave || isSaving)
        .animation(.easeInOut(duration: 0.2), value: canSave)
    }

    // MARK: - Helpers

    private func startShuffle() {
        guard !isShuffling, spinResults.count < 2 else { return }
        isShuffling = true
        // Intervals grow progressively — fast at first, then slow to a stop.
        let intervals: [Double] = [0.05, 0.05, 0.06, 0.08, 0.10, 0.13, 0.17, 0.22, 0.28, 0.36]
        Task { @MainActor in
            var last: Int? = selectedAvatarIndex
            for interval in intervals {
                try? await Task.sleep(for: .seconds(interval))
                var next: Int
                repeat { next = Int.random(in: 0..<avatarCount) } while next == last
                last = next
                withAnimation(.easeInOut(duration: 0.07)) {
                    selectedAvatarIndex = next
                }
            }
            if let finalIndex = selectedAvatarIndex {
                spinResults.append(finalIndex)
            }
            isShuffling = false
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && spinResults.count >= 2
            && selectedAvatarIndex != nil
    }

    private func previewPlayer(avatarIndex: Int) -> Player {
        Player(id: "preview-\(avatarIndex)", name: "", stack: 0, avatarIndex: avatarIndex)
    }

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let avatarIndex = selectedAvatarIndex else { return }
        errorMessage = nil
        isSaving = true
        Task {
            do {
                try await ProfileService.shared.saveProfile(name: trimmed, avatarIndex: avatarIndex)
                onComplete()
            } catch {
                errorMessage = "Couldn't save profile. Check your connection and try again."
            }
            isSaving = false
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(onComplete: {})
}
