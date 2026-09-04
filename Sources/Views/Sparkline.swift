import SwiftUI

/// Tiny polyline of recent percents, oldest first.
struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

                if let last = points.last {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 3, height: 3)
                        .position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let lo = samples.min() ?? 0
        let hi = samples.max() ?? 1
        let span = hi - lo
        let inset: CGFloat = 1.5
        let h = max(size.height - inset * 2, 1)
        let w = max(size.width - inset * 2, 1)
        return samples.enumerated().map { i, v in
            let x = inset + w * CGFloat(i) / CGFloat(samples.count - 1)
            // A flat series draws through the middle rather than collapsing to the top.
            let norm = span > 0 ? (v - lo) / span : 0.5
            let y = inset + h * (1 - CGFloat(norm))
            return CGPoint(x: x, y: y)
        }
    }
}
