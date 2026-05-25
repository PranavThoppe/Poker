import SwiftUI

struct ResultsScreenView: View {
    let stats: [PlayerStats]
    let winnerLabel: String
    let winnerName: String
    let winnerAvatarIndex: Int
    let winnerSubtitle: String
    let statsSectionTitle: String
    let buttonTitle: String
    let onButton: () -> Void
    var countdownStartedAt: Date? = nil
    var countdownDuration: TimeInterval = 5

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Spacing.xl)

                winnerSection

                Spacer().frame(height: Theme.Spacing.xl)

                Text(statsSectionTitle)
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.sm)

                statsList

                Spacer()

                actionButton
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer().frame(height: Theme.Spacing.xl)
            }
        }
    }

    private var winnerSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(winnerLabel)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)
                .textCase(.uppercase)
                .tracking(1.5)

            let player = Player(
                id: "winner",
                name: winnerName,
                stack: 0,
                avatarIndex: winnerAvatarIndex
            )
            AvatarView(player: player, size: 72)

            Text(winnerName)
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Color.primary)

            Text(winnerSubtitle)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    private var statsList: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(stats) { stat in
                StatsRow(stat: stat)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var actionButton: some View {
        Group {
            if let countdownStartedAt {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let elapsed = context.date.timeIntervalSince(countdownStartedAt)
                    let progress = min(1, elapsed / countdownDuration)
                    countdownActionButton(progress: progress)
                }
            } else {
                countdownActionButton(progress: nil)
            }
        }
    }

    private func countdownActionButton(progress: Double?) -> some View {
        Button(action: onButton) {
            ZStack {
                if let progress {
                    CountdownCapsuleFill(progress: progress)
                } else {
                    Capsule().fill(Theme.Color.primary)
                }

                Text(buttonTitle)
                    .font(Theme.Font.actionLabel)
                    .foregroundStyle(Theme.Color.background)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Stats row

struct StatsRow: View {
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
            statCell(label: "Final", value: "\(stat.finalStack)")
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
