import SwiftUI

/// Animated equalizer bars — mimics the waveform animation in the design kit.
/// Uses staggered `easeInOut` repeat animations so each bar oscillates at a
/// slightly different rate, giving the "speech amplitude envelope" effect.
struct EqualizerView: View {
    var active: Bool
    var color: Color = Color.green
    var barCount: Int = 11
    var maxHeight: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let durations: [Double]  = [0.88, 1.05, 0.96, 1.14, 0.92, 1.20, 1.01, 1.08, 0.95, 1.17, 0.90]
    private static let delays:    [Double]  = [0.00, 0.08, 0.16, 0.04, 0.20, 0.12, 0.24, 0.06, 0.14, 0.18, 0.10]
    private static let minScales: [CGFloat] = [0.30, 0.25, 0.40, 0.20, 0.35, 0.25, 0.45, 0.30, 0.20, 0.40, 0.28]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                EqualizerBar(
                    color: color,
                    maxHeight: maxHeight,
                    animate: active && !reduceMotion,
                    duration: Self.durations[i % Self.durations.count],
                    delay:    Self.delays[i % Self.delays.count],
                    minScale: Self.minScales[i % Self.minScales.count]
                )
            }
        }
        .frame(height: maxHeight)
    }
}

private struct EqualizerBar: View {
    let color: Color
    let maxHeight: CGFloat
    let animate: Bool
    let duration: Double
    let delay: Double
    let minScale: CGFloat

    @State private var scale: CGFloat = 1.0

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: maxHeight)
            .scaleEffect(y: scale, anchor: .bottom)
            .onAppear {
                scale = 1.0
                guard animate else { return }
                withAnimation(
                    .easeInOut(duration: duration)
                    .repeatForever(autoreverses: true)
                    .delay(delay)
                ) {
                    scale = minScale
                }
            }
            .onChange(of: animate) { go in
                if go {
                    withAnimation(
                        .easeInOut(duration: duration)
                        .repeatForever(autoreverses: true)
                    ) {
                        scale = minScale
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = 1.0
                    }
                }
            }
    }
}
