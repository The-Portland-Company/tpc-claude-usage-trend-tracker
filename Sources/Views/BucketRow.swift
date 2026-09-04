import SwiftUI

/// One usage bucket: title, percent, bar, countdown, projection, sparkline.
struct BucketRow: View {
    let title: String
    let percent: Double
    let severity: PaceMath.Severity
    var resetsAt: Date? = nil
    var projection: PaceMath.Projection? = nil
    var samples: [Double] = []
    var now: Date = Date()

    private var color: Color { Color(severity: severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }

            bar

            if caption != nil || samples.count >= 2 {
                HStack(spacing: 6) {
                    if let caption {
                        Text(caption)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if samples.count >= 2 {
                        Sparkline(samples: samples)
                            .frame(width: 60, height: 16)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(Int(percent.rounded())) percent used")
    }

    private var bar: some View {
        GeometryReader { geo in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 2 : 0))
                if projection?.overPace == true {
                    // Faint marker at the 100% end: this bucket is heading past it.
                    Capsule()
                        .fill(color.opacity(0.45))
                        .frame(width: 2)
                        .position(x: geo.size.width - 1, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 5)
    }

    private var caption: String? {
        var parts: [String] = []
        if let resetsAt {
            parts.append("Resets \(PaceMath.countdown(to: resetsAt, from: now))")
        }
        if let p = projection {
            if let hit = p.hits100At {
                parts.append("→ 100% \(Self.stamp.string(from: hit))")
            } else {
                parts.append("→ ~\(Int(p.projectedAtReset.rounded()))% at reset")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE h a"; return f
    }()
}
