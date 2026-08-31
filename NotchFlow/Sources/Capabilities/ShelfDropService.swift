import AppKit
import Foundation
import UniformTypeIdentifiers

public enum ShelfDropService {
    public static let acceptedTypes: [UTType] = [.fileURL, .url, .item, .utf8PlainText, .plainText, .data]

    public static func items(from providers: [NSItemProvider]) async -> [NotchShelfItem] {
        var items: [NotchShelfItem] = []
        for provider in providers {
            if let item = await item(from: provider) { items.append(item) }
        }
        return items
    }

    private static func item(from provider: NSItemProvider) async -> NotchShelfItem? {
        if let url = await loadURL(from: provider, type: .fileURL), url.isFileURL {
            return .file(url: url)
        }
        if let url = await loadURL(from: provider, type: .url) {
            return url.isFileURL ? .file(url: url) : .link(url)
        }
        if let url = await loadURL(from: provider, type: .item), url.isFileURL {
            return .file(url: url)
        }
        if let text = await loadString(from: provider) {
            return .text(text)
        }
        if let payload = await loadData(from: provider), let url = TemporaryShelfStorage.create(data: payload.data, suggestedName: payload.name) {
            return .file(url: url, displayName: payload.name, isTemporary: true)
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                let url: URL? = switch item {
                case let url as URL: url
                case let url as NSURL: url as URL
                case let data as Data: decodedURL(from: data)
                case let text as String:
                    if let url = URL(string: text) { url }
                    else if text.hasPrefix("/") { URL(fileURLWithPath: text) }
                    else { nil }
                default: nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func decodedURL(from data: Data) -> URL? {
        if let text = String(data: data, encoding: .utf8), let url = URL(string: text) { return url }
        if let path = String(data: data, encoding: .utf8), path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) ? UTType.utf8PlainText : UTType.plainText
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                let string: String? = switch item {
                case let string as String: string
                case let string as NSString: string as String
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: string)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider) async -> (data: Data, name: String?)? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) else { return nil }
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { item, _ in
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    continuation.resume(returning: (data, suggestedName ?? url.lastPathComponent))
                } else if let data = item as? Data {
                    continuation.resume(returning: (data, suggestedName))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

public enum TemporaryShelfStorage {
    private static var directory: URL {
        AppSupportPaths.fileTrayDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("\(AppSupportPaths.directoryName)/FileTray", isDirectory: true)
    }

    public static func create(data: Data, suggestedName: String?) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = suggestedName?.isEmpty == false ? URL(fileURLWithPath: suggestedName!).lastPathComponent : "Dropped Item"
            let itemDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            let url = itemDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    public static func remove(_ url: URL) {
        guard url.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
