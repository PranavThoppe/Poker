import SwiftUI

enum Theme {
    // MARK: - Colors
    enum Color {
        static let background  = SwiftUI.Color.black
        static let surface     = SwiftUI.Color(white: 0.12)
        static let surfaceDeep = SwiftUI.Color(white: 0.08)
        static let primary     = SwiftUI.Color.white
        static let secondary   = SwiftUI.Color(white: 0.55)
        static let red         = SwiftUI.Color(red: 0.90, green: 0.20, blue: 0.20)
        static let green       = SwiftUI.Color.green.opacity(0.85)
        static let chipYellow  = SwiftUI.Color(red: 0.95, green: 0.78, blue: 0.18)
        static let cardFace    = SwiftUI.Color.white
        static let suitRed     = SwiftUI.Color(red: 0.85, green: 0.14, blue: 0.14)
        static let suitBlack   = SwiftUI.Color.black
    }

    // MARK: - Corner radii
    enum Radius {
        static let card:   CGFloat = 12
        static let tile:   CGFloat = 20
        static let pill:   CGFloat = 14
        static let chip:   CGFloat = 10
        static let avatar: CGFloat = 22
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 16
        static let lg:  CGFloat = 24
        static let xl:  CGFloat = 32
    }

    // MARK: - Sizes
    enum Size {
        static let avatarMD:  CGFloat = 44
        static let avatarSM:  CGFloat = 34
        static let cardW:     CGFloat = 64
        static let cardH:     CGFloat = 88
        static let holeCardW: CGFloat = 80
        static let holeCardH: CGFloat = 108
        static let actionPillH: CGFloat = 50
    }

    // MARK: - Typography
    enum Font {
        static func cardRank(_ size: CGFloat = 22) -> SwiftUI.Font {
            .system(size: size, weight: .bold, design: .rounded)
        }
        static func cardSuit(_ size: CGFloat = 18) -> SwiftUI.Font {
            .system(size: size, weight: .regular)
        }
        static let playerName:  SwiftUI.Font = .system(size: 12, weight: .medium)
        static let playerStack: SwiftUI.Font = .system(size: 12, weight: .regular)
        static let pot:         SwiftUI.Font = .system(size: 22, weight: .semibold)
        static let actionLabel: SwiftUI.Font = .system(size: 16, weight: .semibold)
        static let handRank:    SwiftUI.Font = .system(size: 11, weight: .medium)
        static let heroStack:   SwiftUI.Font = .system(size: 22, weight: .semibold)
        static let headline:    SwiftUI.Font = .system(size: 28, weight: .bold)
        static let subhead:     SwiftUI.Font = .system(size: 15, weight: .medium)
        static let body:        SwiftUI.Font = .system(size: 14, weight: .regular)
        static let caption:     SwiftUI.Font = .system(size: 11, weight: .regular)
    }
}

// MARK: - Convenience

extension Suit {
    var color: SwiftUI.Color { isRed ? Theme.Color.suitRed : Theme.Color.suitBlack }
}
