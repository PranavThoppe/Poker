import SwiftUI

/// Capsule track with a fill that grows left → right as `progress` goes 0 → 1.
struct CountdownCapsuleFill: View {
    var progress: Double
    var trackColor: Color = Theme.Color.surface
    var fillColor: Color = Theme.Color.primary

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(fillColor)
                    .frame(width: geo.size.width * min(1, max(0, progress)))
            }
        }
    }
}
