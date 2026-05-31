import SwiftUI

// MARK: - Avatar emojis

private let avatarEmojis = ["😵‍💫", "💀", "😴", "🥳", "🤪", "😱", "🐸", "😁", "😇", "🥹", "😍", "😫", "🤯", "🤬", "😡", "🥵", "🤗", "😬", "🫨", "🤢", "🥴", "🥱", "🤮", "🤠", "🤑", "😈", "🤡", "💩", "👽", "😏"]

struct AvatarView: View {
    let player: Player
    var size: CGFloat = Theme.Size.avatarMD
    var showDealer: Bool = false

    private var emoji: String {
        avatarEmojis[player.avatarIndex % avatarEmojis.count]
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(Theme.Color.surface)
                    .frame(width: size, height: size)
                Text(emoji)
                    .font(.system(size: size * 0.6))
            }

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
