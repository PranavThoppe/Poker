import SwiftUI

/// A short expanding outline that confirms an eligible button tap without altering its action.
struct TapGlowRipple: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let trigger: Int
    let color: Color

    @State private var isVisible = false
    @State private var isExpanded = false
    @State private var latestTrigger = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion && isVisible {
                    Capsule()
                        .stroke(color.opacity(isExpanded ? 0 : 0.75), lineWidth: 2)
                        .scaleEffect(isExpanded ? 1.14 : 1)
                        .shadow(color: color.opacity(isExpanded ? 0 : 0.45), radius: isExpanded ? 2 : 8)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { newTrigger in
                play(for: newTrigger)
            }
    }

    private func play(for newTrigger: Int) {
        latestTrigger = newTrigger
        isVisible = false
        isExpanded = false

        guard !reduceMotion else { return }

        isVisible = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard latestTrigger == newTrigger, !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.42)) {
                isExpanded = true
            }

            try? await Task.sleep(for: .milliseconds(420))
            guard latestTrigger == newTrigger, !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

extension View {
    func tapGlowRipple(trigger: Int, color: Color) -> some View {
        modifier(TapGlowRipple(trigger: trigger, color: color))
    }
}
