import SwiftUI

struct WaitingRoomView: View {
    @EnvironmentObject var store: GameStore

    private var players: [Player] { store.state.players }
    private var heroID: String? { store.state.heroID }

    private var readyCount: Int { players.filter { $0.isReady }.count }
    private var totalCount: Int { players.count }
    private var isHeroReady: Bool {
        guard let id = heroID else { return false }
        return players.first { $0.id == id }?.isReady ?? false
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer().frame(height: Theme.Spacing.xl)

                playerList

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
            readyButton
            if store.allReady {
                startButton
            }
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }

    private var readyButton: some View {
        Button(action: { store.toggleReady() }) {
            Text(isHeroReady ? "Cancel" : "Ready Up")
                .font(Theme.Font.actionLabel)
                .foregroundStyle(isHeroReady ? Theme.Color.secondary : Theme.Color.background)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(isHeroReady ? Theme.Color.surface : Theme.Color.primary)
                .clipShape(Capsule())
        }
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
        Text(player.isReady ? "Ready" : "Waiting")
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
