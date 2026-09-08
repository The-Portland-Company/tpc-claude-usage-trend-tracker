import Foundation
import Combine

/// Non-secret display preferences, persisted in UserDefaults per §4's
/// "Cross-cutting" rule (secrets never live here — only metadata/selection).
@MainActor
final class AppSettings: ObservableObject {
    @Published var featuredBucketIDs: Set<String> {
        didSet { defaults.set(Array(featuredBucketIDs), forKey: Keys.featured) }
    }
    @Published var useIconStyle: Bool {
        didSet { defaults.set(useIconStyle, forKey: Keys.iconStyle) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let featured = "settings.featuredBucketIDs"
        static let iconStyle = "settings.useIconStyle"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        featuredBucketIDs = Set(defaults.stringArray(forKey: Keys.featured) ?? ["weekly_all", "session"])
        useIconStyle = defaults.object(forKey: Keys.iconStyle) as? Bool ?? true
    }

    func toggleFeatured(_ id: String) {
        if featuredBucketIDs.contains(id) {
            featuredBucketIDs.remove(id)
        } else {
            featuredBucketIDs.insert(id)
        }
    }
}
