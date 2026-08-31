import Foundation

public enum ClipboardContent: Equatable, Hashable, Sendable {
    case text(String)
    case image(Data)
    case file(URL)

    fileprivate var searchableText: String {
        switch self {
        case let .text(value): value
        case let .file(url): url.lastPathComponent
        case .image: "image"
        }
    }

    public var displayText: String {
        switch self {
        case let .text(value): return value.replacingOccurrences(of: "\n", with: " ")
        case let .file(url): return url.lastPathComponent
        case .image: return "Image"
        }
    }

    fileprivate var isMeaningful: Bool {
        if case let .text(value) = self { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if case let .image(data) = self { return !data.isEmpty }
        return true
    }
}

public struct ClipboardHistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public let sourceBundleID: String?
    public var capturedAt: Date
    public var isPinned: Bool

    init(content: ClipboardContent, sourceBundleID: String?, capturedAt: Date, isPinned: Bool = false) {
        id = UUID()
        self.content = content
        self.sourceBundleID = sourceBundleID
        self.capturedAt = capturedAt
        self.isPinned = isPinned
    }
}

/// Pure local-history state. An AppKit pasteboard observer is deliberately kept
/// outside this type so tests and stored content never need pasteboard access.
public struct ClipboardHistoryStore: Sendable {
    public private(set) var items: [ClipboardHistoryItem] = []
    public var limit: Int
    public var ignoredBundleIDs: Set<String>

    public init(limit: Int, ignoredBundleIDs: Set<String> = []) {
        self.limit = max(0, limit)
        self.ignoredBundleIDs = ignoredBundleIDs
    }

    public mutating func record(_ content: ClipboardContent, sourceBundleID: String? = nil, at date: Date = Date()) {
        guard content.isMeaningful, !ignoredBundleIDs.contains(sourceBundleID ?? "") else { return }
        if let index = items.firstIndex(where: { $0.content == content }) {
            var existing = items.remove(at: index)
            existing.capturedAt = date
            items.insert(existing, at: 0)
        } else {
            items.insert(ClipboardHistoryItem(content: content, sourceBundleID: sourceBundleID, capturedAt: date), at: 0)
        }
        enforceLimit()
    }

    public mutating func setPinned(_ isPinned: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = isPinned
        enforceLimit()
    }

    public mutating func remove(id: UUID) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }

    public func search(_ query: String) -> [ClipboardHistoryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.content.searchableText.localizedCaseInsensitiveContains(needle) }
    }

    private mutating func enforceLimit() {
        let nonPinnedCapacity = max(0, limit - items.filter(\.isPinned).count)
        var seenNonPinned = 0
        items.removeAll { item in
            guard !item.isPinned else { return false }
            defer { seenNonPinned += 1 }
            return seenNonPinned >= nonPinnedCapacity
        }
    }
}

public struct ClipboardAutoClearPolicy: Equatable, Sendable {
    public enum Trigger: Equatable, Sendable { case elapsed(seconds: TimeInterval), sleep, displaySleep, lock }
    public var after: TimeInterval?
    public var clearOnSleep: Bool
    public var clearOnDisplaySleep: Bool
    public var clearOnLock: Bool

    public init(after: TimeInterval? = nil, clearOnSleep: Bool = false,
                clearOnDisplaySleep: Bool = false, clearOnLock: Bool = false) {
        self.after = after
        self.clearOnSleep = clearOnSleep
        self.clearOnDisplaySleep = clearOnDisplaySleep
        self.clearOnLock = clearOnLock
    }

    public func shouldClear(for trigger: Trigger) -> Bool {
        switch trigger {
        case let .elapsed(seconds): after.map { seconds >= $0 } ?? false
        case .sleep: clearOnSleep
        case .displaySleep: clearOnDisplaySleep
        case .lock: clearOnLock
        }
    }
}
