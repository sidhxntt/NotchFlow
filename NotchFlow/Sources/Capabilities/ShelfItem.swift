import Foundation

public enum NotchShelfKind: Codable, Equatable, Sendable {
    case file(bookmark: Data, fallbackURL: URL)
    case link(URL)
    case text(String)
}

public struct NotchShelfItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: NotchShelfKind
    public var displayNameOverride: String?
    public var isTemporary: Bool
    public let addedAt: Date

    public init(id: UUID = UUID(), kind: NotchShelfKind, displayNameOverride: String? = nil, isTemporary: Bool = false, addedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.displayNameOverride = displayNameOverride
        self.isTemporary = isTemporary
        self.addedAt = addedAt
    }

    public static func file(url: URL, displayName: String? = nil, isTemporary: Bool = false) -> NotchShelfItem {
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        return NotchShelfItem(kind: .file(bookmark: bookmark, fallbackURL: url), displayNameOverride: displayName, isTemporary: isTemporary)
    }

    public static func link(_ url: URL) -> NotchShelfItem { NotchShelfItem(kind: .link(url)) }
    public static func text(_ value: String) -> NotchShelfItem { NotchShelfItem(kind: .text(value)) }

    public var url: URL? {
        switch kind {
        case let .file(bookmark, fallbackURL):
            guard !bookmark.isEmpty else { return fallbackURL }
            var stale = false
            return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? fallbackURL
        case let .link(url): return url
        case .text: return nil
        }
    }

    public var displayName: String {
        if let displayNameOverride, !displayNameOverride.isEmpty { return displayNameOverride }
        switch kind {
        case .file: return cleanedTemporaryName(url?.lastPathComponent) ?? url?.lastPathComponent ?? "Missing file"
        case let .link(url): return url.host(percentEncoded: false) ?? url.absoluteString
        case let .text(value): return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        }
    }

    /// Repairs legacy temporary drops that were saved as `UUID-original-name`.
    /// Keeping the file itself at the original name makes Finder and Quick Look agree
    /// with the label rendered in the tray.
    @discardableResult
    public mutating func restorePreferredTemporaryFilename() -> Bool {
        guard isTemporary,
              let displayNameOverride,
              !displayNameOverride.isEmpty,
              let sourceURL = url else {
            return false
        }

        let preferredName = URL(fileURLWithPath: displayNameOverride).lastPathComponent
        guard !preferredName.isEmpty, sourceURL.lastPathComponent != preferredName else {
            return false
        }

        let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(preferredName)
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            return false
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            let bookmark = (try? targetURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
            kind = .file(bookmark: bookmark, fallbackURL: targetURL)
            return true
        } catch {
            return false
        }
    }

    private func cleanedTemporaryName(_ name: String?) -> String? {
        guard isTemporary, let name, name.count > 37 else { return nil }
        let uuidEnd = name.index(name.startIndex, offsetBy: 36)
        guard name[uuidEnd] == "-", UUID(uuidString: String(name[..<uuidEnd])) != nil else { return nil }
        return String(name[name.index(after: uuidEnd)...])
    }

    public var identityKey: String {
        switch kind {
        case .file: return "file:\(url?.standardizedFileURL.path ?? id.uuidString)"
        case let .link(url): return "link:\(url.absoluteString)"
        case let .text(value): return "text:\(value)"
        }
    }
}

/// Resolves the transient File Tray selection against its current contents.
/// The selected id belongs to the view, not persistence: a deleted item must
/// immediately leave the tray without an action target.
public enum ShelfTraySelection {
    public static func item(in items: [NotchShelfItem], selectedID: UUID?) -> NotchShelfItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// Retains the tray's visual order so batch actions behave predictably even
    /// when files were selected in a different order.
    public static func items(in items: [NotchShelfItem], selectedIDs: Set<UUID>) -> [NotchShelfItem] {
        items.filter { selectedIDs.contains($0.id) }
    }
}

public enum ShelfDropTarget: Sendable {
    case chatNotch
    case fileTray
}
