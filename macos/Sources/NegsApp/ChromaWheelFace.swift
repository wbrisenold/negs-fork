import SwiftUI

/// The color field, saturation rings, and position marker for the pre-scan
/// color-correction wheel. Gesture handling stays with its owning control.
struct ChromaWheelFace: View {
    let radius: CGFloat
    let marker: CGPoint

    var body: some View {
        ZStack {
            colorField
            ringGuides
            positionMarker
        }
    }

    private var colorField: some View {
        Circle()
            .fill(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                center: .center))
            .overlay(Circle().fill(RadialGradient(
                colors: [.white, .clear], center: .center,
                startRadius: 0, endRadius: radius)))
    }

    private var ringGuides: some View {
        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
            Circle()
                .stroke(.white.opacity(fraction == 1 ? 0.72 : 0.25),
                        lineWidth: fraction == 1 ? 1.2 : 0.6)
                .scaleEffect(fraction)
        }
    }

    private var positionMarker: some View {
        Circle().fill(.white).frame(width: 11, height: 11)
            .overlay(Circle().stroke(.black.opacity(0.8), lineWidth: 1.5))
            .position(marker)
    }
}
