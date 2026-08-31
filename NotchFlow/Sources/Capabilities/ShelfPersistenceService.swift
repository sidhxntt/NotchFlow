import Foundation

public final class ShelfPersistenceService: @unchecked Sendable {
    public static let shared = ShelfPersistenceService(defaults: .standard)
    public static let ephemeral = ShelfPersistenceService(defaults: nil)
    private let defaults: UserDefaults?
    private let key = "notchflow.file-tray.items"

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func load() -> [NotchShelfItem] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([NotchShelfItem].self, from: data)) ?? []
    }

    public func save(_ items: [NotchShelfItem]) {
        guard let defaults, let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
