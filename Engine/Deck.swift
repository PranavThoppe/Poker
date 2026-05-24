import Foundation

struct Deck {
    private var cards: [Card]

    init(shuffled: Bool = true) {
        cards = Suit.allCases.flatMap { suit in
            Rank.allCases.map { rank in
                Card(rank: rank, suit: suit)
            }
        }
        if shuffled {
            shuffle()
        }
    }

    mutating func shuffle() {
        cards.shuffle()
    }

    mutating func draw() -> Card? {
        guard !cards.isEmpty else { return nil }
        return cards.removeFirst()
    }

    mutating func draw(_ count: Int) -> [Card] {
        (0..<count).compactMap { _ in draw() }
    }

    var remaining: Int { cards.count }

    /// Persists remaining cards in game state between streets.
    init(remainingCards: [Card]) {
        cards = remainingCards
    }

    func saveRemaining() -> [Card] {
        cards
    }
}
