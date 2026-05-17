import SwiftUI

// MARK: - Avatar symbols (stand-ins for Memoji)

private let avatarSymbols = [
    "person.crop.circle.fill",
    "mustache.fill",
    "person.crop.circle.badge.moon.fill",
    "person.crop.circle.fill",
    "person.crop.circle.badge.checkmark.fill"
]

private let avatarColors: [Color] = [
    Color(red: 0.65, green: 0.82, blue: 0.99),
    Color(red: 0.75, green: 0.60, blue: 0.42),
    Color(red: 0.70, green: 0.50, blue: 0.65),
    Color(red: 0.55, green: 0.70, blue: 0.55),
    Color(red: 0.95, green: 0.80, blue: 0.50)
]

struct AvatarView: View {
    let player: Player
    var size: CGFloat = Theme.Size.avatarMD
    var showDealer: Bool = false

    private var symbolName: String {
        avatarSymbols[player.avatarIndex % avatarSymbols.count]
    }
    private var tint: Color {
        avatarColors[player.avatarIndex % avatarColors.count]
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .clipShape(Circle())

            if showDealer || player.isDealer {
                DealerBadge()
                    .offset(x: 4, y: 4)
            }
        }
    }
}

struct DealerBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: 16, height: 16)
            Circle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            Text("D")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Chip label (small bet amount pill below avatar)

struct BetChip: View {
    let amount: Int

    var body: some View {
        Text("\(amount)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Color.background)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.Color.chipYellow)
            .clipShape(Capsule())
    }
}

// MARK: - Previews

#Preview {
    HStack(spacing: 16) {
        ForEach(0..<5) { i in
            let p = Player(id: "\(i)", name: "P\(i)", stack: 500, isDealer: i == 2, avatarIndex: i)
            AvatarView(player: p)
        }
    }
    .padding()
    .background(Theme.Color.background)
}
