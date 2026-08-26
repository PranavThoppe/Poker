import SwiftUI

struct ResultsWinner: Identifiable {
    let id: String
    let name: String
    let avatarIndex: Int
    var subtitle: String = ""
}

enum PlayerReadyStatus {
    case ready
    case waiting
    case out
}

struct ResultsScreenView: View {
    let stats: [PlayerStats]
    let winnerLabel: String
    let winners: [ResultsWinner]
    let winnerSubtitle: String
    let statsSectionTitle: String
    let buttonTitle: String
    let onButton: () -> Void
    var buttonDetail: String? = nil
    var secondaryButtonTitle: String? = nil
    var onSecondaryButton: (() -> Void)? = nil
    var tertiaryButtonTitle: String? = nil
    var onTertiaryButton: (() -> Void)? = nil
    var readyStatusByPlayerID: [String: PlayerReadyStatus] = [:]
    var countdownStartedAt: Date? = nil
    var countdownDuration: TimeInterval = 5
    var buttonFillColor: Color = Theme.Color.primary
    var buttonTrackColor: Color = Theme.Color.surface
    var buttonTextColor: Color = Theme.Color.background

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

                VStack(spacing: Theme.Spacing.sm) {
                    if let tertiaryButtonTitle, let onTertiaryButton {
                        HStack(spacing: Theme.Spacing.sm) {
                            actionButton
                            sideActionButton(title: tertiaryButtonTitle, action: onTertiaryButton)
                        }
                    } else {
                        actionButton
                    }
                    if let secondaryButtonTitle, let onSecondaryButton {
                        Button(action: onSecondaryButton) {
                            Text(secondaryButtonTitle)
                                .font(Theme.Font.actionLabel)
                                .foregroundStyle(Theme.Color.background)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Size.actionPillH)
                                .background(Theme.Color.green)
                                .clipShape(Capsule())
                        }
                    }
                }
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

            HStack(spacing: Theme.Spacing.md) {
                ForEach(displayWinners) { winner in
                    VStack(spacing: Theme.Spacing.xs) {
                        let player = Player(
                            id: winner.id,
                            name: winner.name,
                            stack: 0,
                            avatarIndex: winner.avatarIndex
                        )
                        AvatarView(player: player, size: winners.count > 1 ? 56 : 72)

                        Text(winner.name)
                            .font(winners.count > 1 ? Theme.Font.subhead : Theme.Font.headline)
                            .foregroundStyle(Theme.Color.primary)

                        if winners.count > 1, !winner.subtitle.isEmpty {
                            Text(winner.subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Color.secondary)
                        }
                    }
                }
            }

            if winners.count <= 1 {
                Text(winnerSubtitle)
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.Color.secondary)
            }
        }
    }

    private var displayWinners: [ResultsWinner] {
        if winners.isEmpty {
            return [ResultsWinner(id: "none", name: "—", avatarIndex: 0)]
        }
        return winners
    }

    private var statsList: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(stats) { stat in
                StatsRow(
                    stat: stat,
                    readyStatus: readyStatusByPlayerID[stat.id]
                )
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
                    CountdownCapsuleFill(
                        progress: progress,
                        trackColor: buttonTrackColor,
                        fillColor: buttonFillColor
                    )
                } else {
                    Capsule().fill(buttonFillColor)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    Text(buttonTitle)
                        .font(Theme.Font.actionLabel)
                        .foregroundStyle(buttonTextColor)

                    if let buttonDetail {
                        Text(buttonDetail)
                            .font(Theme.Font.actionLabel)
                            .foregroundStyle(buttonTextColor.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.actionPillH)
            .clipShape(Capsule())
        }
    }

    private func sideActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.actionLabel)
                .foregroundStyle(Theme.Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Stats row

struct StatsRow: View {
    let stat: PlayerStats
    var readyStatus: PlayerReadyStatus? = nil

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

            Text(displayName(stat.name, maxChars: 20))
                .font(Theme.Font.playerName)
                .foregroundStyle(stat.isWinner ? Theme.Color.primary : Theme.Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: Theme.Spacing.sm)

            if let readyStatus {
                readyPill(readyStatus)
            }

            statColumns(stat)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }

    private func displayName(_ name: String, maxChars: Int) -> String {
        guard name.count > maxChars else { return name }
        return String(name.prefix(maxChars - 1)) + "…"
    }

    @ViewBuilder
    private func readyPill(_ status: PlayerReadyStatus) -> some View {
        switch status {
        case .ready:
            pillLabel(
                "Ready",
                foreground: Theme.Color.green,
                background: Theme.Color.green.opacity(0.15)
            )
        case .out:
            pillLabel(
                "Out",
                foreground: Theme.Color.secondary,
                background: Theme.Color.surfaceDeep
            )
        case .waiting:
            EmptyView()
        }
    }

    private func pillLabel(_ label: String, foreground: Color, background: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func statColumns(_ stat: PlayerStats) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
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
