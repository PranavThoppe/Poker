import SwiftUI

// MARK: - Hand rankings cheat sheet

struct HandRankingsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let miniCardW: CGFloat = 36
    private static let miniCardH: CGFloat = 50

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Self.examples) { example in
                        HandRankingRow(
                            example: example,
                            cardWidth: Self.miniCardW,
                            cardHeight: Self.miniCardH
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .background(Theme.Color.background.ignoresSafeArea())
            .navigationTitle("Poker Hand Ranking")
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
            .toolbarBackground(Theme.Color.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // Chart examples, strongest → weakest. `nil` slots are face-down kickers.
    private static let examples: [HandRankingExample] = [
        HandRankingExample(
            name: "Royal Flush",
            cards: [
                Card(rank: .ace, suit: .spades),
                Card(rank: .king, suit: .spades),
                Card(rank: .queen, suit: .spades),
                Card(rank: .jack, suit: .spades),
                Card(rank: .ten, suit: .spades),
            ]
        ),
        HandRankingExample(
            name: "Straight Flush",
            cards: [
                Card(rank: .jack, suit: .spades),
                Card(rank: .ten, suit: .spades),
                Card(rank: .nine, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .seven, suit: .spades),
            ]
        ),
        HandRankingExample(
            name: "4 of a Kind",
            cards: [
                Card(rank: .king, suit: .hearts),
                Card(rank: .king, suit: .clubs),
                Card(rank: .king, suit: .diamonds),
                Card(rank: .king, suit: .spades),
                nil,
            ]
        ),
        HandRankingExample(
            name: "Full House",
            cards: [
                Card(rank: .ace, suit: .hearts),
                Card(rank: .ace, suit: .clubs),
                Card(rank: .ace, suit: .diamonds),
                Card(rank: .nine, suit: .spades),
                Card(rank: .nine, suit: .hearts),
            ]
        ),
        HandRankingExample(
            name: "Flush",
            cards: [
                Card(rank: .king, suit: .spades),
                Card(rank: .jack, suit: .spades),
                Card(rank: .eight, suit: .spades),
                Card(rank: .seven, suit: .spades),
                Card(rank: .five, suit: .spades),
            ]
        ),
        HandRankingExample(
            name: "Straight",
            cards: [
                Card(rank: .jack, suit: .hearts),
                Card(rank: .ten, suit: .clubs),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .eight, suit: .spades),
                Card(rank: .seven, suit: .hearts),
            ]
        ),
        HandRankingExample(
            name: "3 of a Kind",
            cards: [
                Card(rank: .king, suit: .hearts),
                Card(rank: .king, suit: .clubs),
                Card(rank: .king, suit: .diamonds),
                nil,
                nil,
            ]
        ),
        HandRankingExample(
            name: "2 Pair",
            cards: [
                Card(rank: .ace, suit: .hearts),
                Card(rank: .ace, suit: .clubs),
                Card(rank: .nine, suit: .diamonds),
                Card(rank: .nine, suit: .spades),
                nil,
            ]
        ),
        HandRankingExample(
            name: "Pair",
            cards: [
                Card(rank: .king, suit: .hearts),
                Card(rank: .king, suit: .clubs),
                nil,
                nil,
                nil,
            ]
        ),
        HandRankingExample(
            name: "High Card",
            cards: [
                Card(rank: .ace, suit: .hearts),
                nil,
                nil,
                nil,
                nil,
            ]
        ),
    ]
}

// MARK: - Row

private struct HandRankingRow: View {
    let example: HandRankingExample
    let cardWidth: CGFloat
    let cardHeight: CGFloat

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: 4) {
                ForEach(0..<example.cards.count, id: \.self) { index in
                    if let card = example.cards[index] {
                        CardView(card: card, width: cardWidth, height: cardHeight)
                    } else {
                        CardBackView(width: cardWidth, height: cardHeight)
                    }
                }
            }

            Text(example.name)
                .font(Theme.Font.subhead)
                .foregroundStyle(Theme.Color.primary)
                .textCase(.uppercase)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Model

private struct HandRankingExample: Identifiable {
    let name: String
    /// Exactly five slots; `nil` means a face-down kicker.
    let cards: [Card?]

    var id: String { name }
}

#Preview("Hand Rankings") {
    HandRankingsView()
}
