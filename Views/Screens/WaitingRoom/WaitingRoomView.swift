import SwiftUI

struct WaitingRoomView: View {
    @EnvironmentObject var store: GameStore
    @State private var readyPulse = 0
    @State private var isShowingSettings = false
    @State private var isEditingSettings = false
    @State private var startingStackText = ""
    @State private var smallBlindText = ""

    private var players: [Player] { store.state.players }
    private var heroID: String? { store.state.heroID }

    private var readyCount: Int { players.filter { !$0.isSittingOut && $0.isReady }.count }
    private var totalCount: Int { players.filter { !$0.isSittingOut }.count }
    private var isHeroReady: Bool {
        guard let id = heroID else { return false }
        guard let hero = players.first(where: { $0.id == id }), !hero.isSittingOut else { return false }
        return hero.isReady
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer().frame(height: Theme.Spacing.xl)

                playerList

                settingsButton
                    .padding(.top, Theme.Spacing.md)

                Spacer()

                bottomBar
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer().frame(height: Theme.Spacing.lg)
            Text("Poker")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Color.primary)
            Text(waitingText)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    private var waitingText: String {
        if store.allReady {
            return "Everyone's ready!"
        }
        let waiting = totalCount - readyCount
        return waiting == 1 ? "Waiting for 1 player…" : "Waiting for \(waiting) players…"
    }

    // MARK: - Player list

    private var settingsButton: some View {
        Button {
            isEditingSettings = false
            isShowingSettings = true
        } label: {
            HStack {
                Label("Game Settings", systemImage: "slider.horizontal.3")
                    .font(Theme.Font.actionLabel)
                Spacer()
            }
            .foregroundStyle(Theme.Color.primary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
            .background(Theme.Color.surface)
            .clipShape(Capsule())
        }
        .popover(isPresented: $isShowingSettings) {
            settingsPopover
                .padding(Theme.Spacing.lg)
                .frame(width: 290)
                .presentationCompactAdaptation(.popover)
                .preferredColorScheme(.dark)
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Game Settings")
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.Color.primary)

                Spacer()

                if !isEditingSettings {
                    Button("Edit") { beginEditingSettings() }
                        .font(Theme.Font.body)
                        .foregroundStyle(store.canEditWaitingRoomSettings ? Theme.Color.green : Theme.Color.secondary)
                        .disabled(!store.canEditWaitingRoomSettings)
                }
            }

            if isEditingSettings {
                settingsEditor
            } else {
                HStack(spacing: Theme.Spacing.lg) {
                    settingValue(title: "Starting stack", value: "\(store.tableStartingStack)")
                    settingValue(title: "Blinds", value: "\(store.tableSmallBlind) / \(store.tableSmallBlind * 2)")
                }
                if !store.canEditWaitingRoomSettings {
                    Text("Only the host can change settings before the game starts.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondary)
                }
            }
        }
    }

    private func settingValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)
            Text(value)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.primary)
        }
    }

    private var settingsEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            settingsField(title: "Starting stack", text: $startingStackText)
            settingsField(title: "Small blind", text: $smallBlindText)

            Text("Big blind: \(editedSmallBlind.map { String($0 * 2) } ?? "—")")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)

            if let message = settingsValidationMessage {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { isEditingSettings = false }
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.secondary)

                Spacer()

                Button("Save Settings") { saveSettings() }
                    .font(Theme.Font.body)
                    .foregroundStyle(canSaveSettings ? Theme.Color.green : Theme.Color.secondary)
                    .disabled(!canSaveSettings || store.isSubmittingCommand)
            }
        }
    }

    private func settingsField(title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.primary)
            Spacer()
            TextField(title, text: text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.primary)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .frame(width: 104)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Color.surfaceDeep)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
    }

    private var editedStartingStack: Int? { Int(startingStackText) }
    private var editedSmallBlind: Int? { Int(smallBlindText) }

    private var canSaveSettings: Bool {
        guard let startingStack = editedStartingStack, let smallBlind = editedSmallBlind else { return false }
        return store.areValidWaitingRoomSettings(startingStack: startingStack, smallBlind: smallBlind)
    }

    private var settingsValidationMessage: String? {
        guard !startingStackText.isEmpty || !smallBlindText.isEmpty else { return nil }
        guard let startingStack = editedStartingStack else { return "Enter the starting stack as a whole number." }
        guard let smallBlind = editedSmallBlind else { return "Enter the small blind as a whole number." }
        guard (GameStore.minimumStartingStack...GameStore.maximumStartingStack).contains(startingStack) else {
            return "Starting stack must be between 100 and 100,000."
        }
        guard (GameStore.minimumSmallBlind...GameStore.maximumSmallBlind).contains(smallBlind) else {
            return "Small blind must be between 1 and 5,000."
        }
        let maximumSmallBlind = startingStack / 40
        guard smallBlind <= maximumSmallBlind else {
            return "For a \(startingStack.formatted()) starting stack, choose a small blind of \(maximumSmallBlind.formatted()) or less (big blind: \(maximumSmallBlind * 2))."
        }
        return nil
    }

    private func beginEditingSettings() {
        startingStackText = String(store.tableStartingStack)
        smallBlindText = String(store.tableSmallBlind)
        isEditingSettings = true
    }

    private func saveSettings() {
        guard let startingStack = editedStartingStack, let smallBlind = editedSmallBlind else { return }
        store.updateWaitingRoomSettings(startingStack: startingStack, smallBlind: smallBlind)
        isEditingSettings = false
        isShowingSettings = false
    }

    private var playerList: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(players) { player in
                PlayerReadyRow(player: player, isHero: player.id == heroID)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !store.isHeroSittingOut {
                readyButton
            }
            if store.canStartGame {
                startButton
            }
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }

    private var readyButton: some View {
        Button(action: {
            readyPulse += 1
            store.toggleReady()
        }) {
            Text(isHeroReady ? "Cancel" : "Ready Up")
                .font(Theme.Font.actionLabel)
                .foregroundStyle(isHeroReady ? Theme.Color.secondary : Theme.Color.background)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(isHeroReady ? Theme.Color.surface : Theme.Color.primary)
                .clipShape(Capsule())
        }
        .tapGlowRipple(trigger: readyPulse + store.marketingDemoReadyPulse, color: Theme.Color.green)
        .animation(.easeInOut(duration: 0.2), value: isHeroReady)
    }

    private var startButton: some View {
        Button(action: { store.startGame() }) {
            Text("Start Game")
                .font(Theme.Font.actionLabel)
                .foregroundStyle(Theme.Color.background)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(Theme.Color.green)
                .clipShape(Capsule())
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Player row

private struct PlayerReadyRow: View {
    let player: Player
    let isHero: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(player: player, size: Theme.Size.avatarSM)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.name + (isHero ? " (You)" : ""))
                    .font(Theme.Font.playerName)
                    .foregroundStyle(Theme.Color.primary)
                Text("\(player.stack)")
                    .font(Theme.Font.playerStack)
                    .foregroundStyle(Theme.Color.secondary)
            }

            Spacer()

            readyPill
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }

    private var readyPill: some View {
        Text(player.isSittingOut ? "Sitting Out" : (player.isReady ? "Ready" : "Waiting"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(player.isReady ? .green : Theme.Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                player.isReady
                    ? Color.green.opacity(0.15)
                    : Theme.Color.surfaceDeep
            )
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("Waiting Room") {
    WaitingRoomView()
        .environmentObject(GameStore.mockWaiting)
}
