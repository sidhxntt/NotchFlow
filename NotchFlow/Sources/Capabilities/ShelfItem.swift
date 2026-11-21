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

    /// The selection after a click on `id`.
    ///
    /// A plain (or ⌘-) click toggles that one row — the tray's original
    /// multi-select gesture, kept so nothing a user already relies on changes.
    /// A ⇧-click adds every row from the anchor (the last row toggled on) through
    /// the clicked one, in tray order, the way a Finder list extends. With no
    /// usable anchor a ⇧-click falls back to a toggle.
    public static func selection(afterClicking id: UUID,
                                 extendingRange: Bool,
                                 in items: [NotchShelfItem],
                                 current: Set<UUID>,
                                 anchor: UUID?) -> (selection: Set<UUID>, anchor: UUID?) {
        if extendingRange,
           let anchor,
           current.contains(anchor),
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == id }) {
            let range = min(from, to)...max(from, to)
            return (current.union(items[range].map(\.id)), anchor)
        }
        var next = current
        if next.contains(id) {
            next.remove(id)
            return (next, next.isEmpty ? nil : (anchor == id ? nil : anchor))
        }
        next.insert(id)
        return (next, id)
    }

    /// The selection after ↑ (`step` -1) or ↓ (`step` 1).
    ///
    /// `cursor` is the row the keyboard is on — the moving end of a range. A
    /// plain arrow moves a single selection one row, Finder-style. ⇧-arrow
    /// moves the cursor and selects exactly anchor…cursor, so stepping back
    /// toward the anchor shrinks the range again. Stops at either end of the
    /// tray. Nil when nothing is selected: the keys belong to the tray only
    /// once the user has picked a row in it.
    public static func selection(afterMoving step: Int,
                                 extendingRange: Bool,
                                 in items: [NotchShelfItem],
                                 current: Set<UUID>,
                                 anchor: UUID?,
                                 cursor: UUID?) -> (selection: Set<UUID>, anchor: UUID?, cursor: UUID?)? {
        let selectedIndices = items.indices.filter { current.contains(items[$0].id) }
        guard let firstSelected = selectedIndices.first, let lastSelected = selectedIndices.last else {
            return nil
        }
        let from = cursor.flatMap { id in
            current.contains(id) ? items.firstIndex { $0.id == id } : nil
        } ?? (step > 0 ? lastSelected : firstSelected)
        let to = min(max(from + step, 0), items.count - 1)
        guard extendingRange else {
            let id = items[to].id
            return ([id], id, id)
        }
        let anchorIndex = anchor.flatMap { id in
            current.contains(id) ? items.firstIndex { $0.id == id } : nil
        } ?? from
        let range = min(anchorIndex, to)...max(anchorIndex, to)
        return (Set(items[range].map(\.id)), items[anchorIndex].id, items[to].id)
    }

    /// Files that can take one conversion together: every item is a local file
    /// and all share one extension (case-insensitive — `.JPG` and `.jpg` are the
    /// same type to every converter). Nil for an empty, mixed, or non-file
    /// selection, so the caller can only offer a batch it can actually run.
    public static func sameTypeFiles(_ items: [NotchShelfItem]) -> [(item: NotchShelfItem, url: URL)]? {
        guard !items.isEmpty else { return nil }
        var result: [(item: NotchShelfItem, url: URL)] = []
        var sharedExtension: String?
        for item in items {
            guard case .file = item.kind, let url = item.url, url.isFileURL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return nil }
            if let sharedExtension, sharedExtension != ext { return nil }
            sharedExtension = ext
            result.append((item, url))
        }
        return result
    }
}

public enum ShelfDropTarget: Sendable {
    case chatNotch
    case fileTray
}
