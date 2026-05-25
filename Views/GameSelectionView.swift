import SwiftUI

struct GameSelectionView: View {
    var onClassicSend: () -> Void
    var onPracticePlay: () -> Void

    @State private var selectedMode: GameMode?

    private let upcomingModeCount = 3

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer().frame(height: Theme.Spacing.xl)

                gameCards

                Spacer()

                primaryButton

                Spacer().frame(height: Theme.Spacing.lg)
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer().frame(height: Theme.Spacing.lg)
            Text("Choose a Game")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Color.primary)
        }
    }

    // MARK: - Game cards

    private var gameCards: some View {
        VStack(spacing: Theme.Spacing.md) {
            classicPokerCard

            Divider()
                .overlay(Theme.Color.surfaceDeep)

            Text("Coming Soon")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)

            practiceVsCPUCard

            ForEach(0..<upcomingModeCount, id: \.self) { _ in
                upcomingModeCard
            }
        }
    }

    private var classicPokerCard: some View {
        gameModeCard(
            icon: {
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.Color.suitBlack)
            },
            iconBackground: Theme.Color.cardFace,
            title: "Classic Poker",
            subtitle: "Texas hold'em",
            isSelected: selectedMode == .classicPoker,
            isEnabled: true
        ) {
            selectedMode = selectedMode == .classicPoker ? nil : .classicPoker
        }
    }

    private var practiceVsCPUCard: some View {
        gameModeCard(
            icon: {
                Image(systemName: "cpu")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Color.primary)
            },
            iconBackground: Theme.Color.surfaceDeep,
            title: "Practice vs CPU",
            subtitle: "Play locally against bots",
            isSelected: selectedMode == .practiceVsCPU,
            isEnabled: true
        ) {
            selectedMode = selectedMode == .practiceVsCPU ? nil : .practiceVsCPU
        }
    }

    private var upcomingModeCard: some View {
        gameModeCard(
            icon: {
                Image(systemName: "questionmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Color.primary)
            },
            iconBackground: Theme.Color.surfaceDeep,
            title: "",
            subtitle: nil,
            isSelected: false,
            isEnabled: false
        ) {}
    }

    private func gameModeCard<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        iconBackground: SwiftUI.Color,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(iconBackground)
                    icon()
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Font.subhead)
                        .foregroundStyle(isEnabled ? Theme.Color.primary : Theme.Color.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Color.green)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
            .overlay(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.tile)
                            .strokeBorder(Theme.Color.green, lineWidth: 2)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .allowsHitTesting(isEnabled)
    }

    // MARK: - Primary CTA

    private var primaryButton: some View {
        Button(action: performPrimaryAction) {
            Text(primaryButtonTitle)
                .font(Theme.Font.actionLabel)
                .foregroundStyle(canPerformPrimaryAction ? Theme.Color.background : Theme.Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.actionPillH)
                .background(canPerformPrimaryAction ? Theme.Color.primary : Theme.Color.surfaceDeep)
                .clipShape(Capsule())
        }
        .disabled(!canPerformPrimaryAction)
        .animation(.easeInOut(duration: 0.2), value: canPerformPrimaryAction)
    }

    private var primaryButtonTitle: String {
        switch selectedMode {
        case .classicPoker: return "Send to Chat"
        case .practiceVsCPU: return "Play"
        case nil: return "Send to Chat"
        }
    }

    private var canPerformPrimaryAction: Bool {
        selectedMode != nil
    }

    private func performPrimaryAction() {
        switch selectedMode {
        case .classicPoker:
            onClassicSend()
        case .practiceVsCPU:
            onPracticePlay()
        case nil:
            break
        }
    }
}

#Preview("Game Selection") {
    GameSelectionView(onClassicSend: {}, onPracticePlay: {})
}
