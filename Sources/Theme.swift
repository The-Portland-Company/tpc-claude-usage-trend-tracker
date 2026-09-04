import SwiftUI

extension Color {
    /// One place that maps a pace severity onto a system semantic color, so
    /// light and dark both look right without a custom asset catalog.
    init(severity: PaceMath.Severity) {
        switch severity {
        case .normal: self = .accentColor
        case .warning: self = .orange
        case .critical: self = .red
        }
    }

    /// Menu bar label tint: normal stays the default text color so the item
    /// blends into the bar, and only trouble gets a color.
    static func menuBarTint(_ severity: PaceMath.Severity) -> Color {
        severity == .normal ? .primary : Color(severity: severity)
    }
}
