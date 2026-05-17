import SwiftUI

struct EndGameView: View {
    @EnvironmentObject var store: GameStore

    private var stats: [PlayerStats] { store.state.endStats }
    private var winner: PlayerStats? { stats.first { $0.isWinner } }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Spacing.xl)

                winnerSection

                Spacer().frame(height: Theme.Spacing.xl)

                Text("Results")
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.sm)

                statsList

                Spacer()

                backButton
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.xl)
            }
        }
    }

    // MARK: - Winner section

    private var winnerSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text("Winner")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)
                .textCase(.uppercase)
                .tracking(1.5)

            if let winner {
                let player = Player(
                    id: winner.id,
                    name: winner.name,
                    stack: winner.finalStack,
                    avatarIndex: winner.avatarIndex
                )
                AvatarView(player: player, size: 72)

                Text(winner.name)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Color.primary)

                Text("\(winner.finalStack)")
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.Color.secondary)
            }
        }
    }

    // MARK: - Stats list

    private var statsList: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(stats) { stat in
                StatsRow(stat: stat)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - Back button

    private var backButton: some View {
        Button(action: { store.resetToWaiting() }) {
            Text("Play Again")
                .font(Theme.Font.actionLabel)
                .foregroundStyle(Theme.Color.background)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(Theme.Color.primary)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Stats row

private struct StatsRow: View {
    let stat: PlayerStats

    var body: some View {
        let player = Player(
            id: stat.id,
            name: stat.name,
            stack: stat.finalStack,
            avatarIndex: stat.avatarIndex
        )

        HStack(spacing: Theme.Spacing.md) {
            AvatarView(player: player, size: Theme.Size.avatarSM)
                .opacity(stat.isWinner ? 1 : 0.6)

            Text(stat.name)
                .font(Theme.Font.playerName)
                .foregroundStyle(stat.isWinner ? Theme.Color.primary : Theme.Color.secondary)

            Spacer()

            statColumns(stat)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }

    @ViewBuilder
    private func statColumns(_ stat: PlayerStats) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            statCell(label: "Won", value: "\(stat.handsWon)")
            statCell(label: "Best", value: "\(stat.biggestPot)")
            statCell(label: "Final", value: stat.isWinner ? "\(stat.finalStack)" : "—")
        }
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.primary)
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)
        }
        .frame(width: 38)
    }
}

// MARK: - Preview

#Preview("End Screen") {
    EndGameView()
        .environmentObject(GameStore.mockEnded)
}
