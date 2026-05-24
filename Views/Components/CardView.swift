import SwiftUI

// MARK: - Face-up card

struct CardView: View {
    let card: Card
    var width:  CGFloat = Theme.Size.cardW
    var height: CGFloat = Theme.Size.cardH

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Color.cardFace)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            Text(card.suit.rawValue)
                .font(Theme.Font.cardSuit(width * 0.48))
                .foregroundStyle(card.suit.color)

            Text(card.rank.rawValue)
                .font(Theme.Font.cardRank(width * 0.32))
                .foregroundStyle(card.suit.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Face-down card (diagonal stripe pattern)

struct CardBackView: View {
    var width:  CGFloat = Theme.Size.cardW
    var height: CGFloat = Theme.Size.cardH

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(Theme.Color.cardFace)
            .overlay(
                DiagonalStripePattern()
                    .stroke(Color(white: 0.75), lineWidth: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            )
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .frame(width: width, height: height)
    }
}

private struct DiagonalStripePattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 10
        let count = Int((rect.width + rect.height) / step) + 2
        for i in 0...count {
            let offset = CGFloat(i) * step
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: 0, y: offset))
        }
        return path
    }
}

// MARK: - Previews

#Preview("Face Up") {
    HStack(spacing: 8) {
        CardView(card: Card(rank: .ace, suit: .spades))
        CardView(card: Card(rank: .king, suit: .hearts))
        CardView(card: Card(rank: .four, suit: .diamonds))
        CardView(card: Card(rank: .ten, suit: .clubs))
    }
    .padding()
    .background(Theme.Color.background)
}

#Preview("Face Down") {
    CardBackView()
        .padding()
        .background(Theme.Color.background)
}
