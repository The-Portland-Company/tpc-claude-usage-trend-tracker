import SwiftUI

extension Color {
    /// Same mapping as macOS `Theme.swift`: system semantic colors so it
    /// adapts to light/dark and accessibility settings automatically.
    init(severity: PaceMath.Severity) {
        switch severity {
        case .normal: self = .accentColor
        case .warning: self = .orange
        case .critical: self = .red
        }
    }
}
