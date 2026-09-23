import SwiftUI
import AppKit

/// macOS renders a plain SwiftUI `MenuBarExtra` label as a *template* image,
/// which strips all color to monochrome. To show real color — the severity
/// tint, and the "colored text" style the user can choose — we render the
/// label to a non-template `NSImage` ourselves. Non-template images don't
/// auto-adapt to a light/dark bar, so the "normal" tint is resolved from the
/// current appearance (white on a dark bar, black on a light one); warning and
/// critical use orange/red, which read on both.
@MainActor
enum MenuBarRenderer {
    static func color(for severity: PaceMath.Severity, isDark: Bool) -> Color {
        switch severity {
        case .normal:  return isDark ? .white : .black
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// `outdated` dims every segment and leads with a warning glyph, so a
    /// reading that stopped updating can't be mistaken for a live one.
    static func image(items: [MenuBarItem], style: MenuBarStyle, isDark: Bool, outdated: Bool = false) -> NSImage {
        let content = HStack(spacing: 8) {
            if outdated {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
            ForEach(items) { item in
                HStack(spacing: 3) {
                    if style == .icon {
                        Image(systemName: item.icon)
                    }
                    Text(item.text)
                }
                .foregroundStyle(color(for: item.severity, isDark: isDark))
                .opacity(outdated ? 0.45 : 1)
            }
        }
        .font(.system(size: 13))

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            return NSImage(size: NSSize(width: 8, height: 16))
        }
        image.isTemplate = false
        return image
    }
}

/// The menu bar label. Reads the ambient color scheme so the "normal" tint
/// tracks the bar's appearance.
struct MenuBarLabelView: View {
    let items: [MenuBarItem]
    let style: MenuBarStyle
    var outdated = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: MenuBarRenderer.image(items: items, style: style, isDark: scheme == .dark, outdated: outdated))
            .renderingMode(.original)
    }
}
