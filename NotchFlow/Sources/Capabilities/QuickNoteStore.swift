import Combine
import Foundation

public enum QuickNoteSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed
}

/// Keeps a mini-note safe locally until the existing Notes writer confirms its
/// save. The injected writer makes the persistence policy independently testable.
@MainActor
public final class QuickNoteStore: ObservableObject {
    public typealias Writer = (String, @escaping @MainActor (Bool) -> Void) -> Void

    @Published public var draft: String {
        didSet {
            persistDraft()
            scheduleSave()
        }
    }
    @Published public private(set) var saveState: QuickNoteSaveState = .idle

    private let defaults: UserDefaults
    private let key = "notchflow.quickNote.draft.v1"
    private let writer: Writer
    private var pendingSave: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, writer: @escaping Writer) {
        self.defaults = defaults
        self.writer = writer
        draft = defaults.string(forKey: key) ?? ""
    }

    deinit { pendingSave?.cancel() }

    public func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else {
            if saveState != .saved { saveState = .idle }
            return
        }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot else { return }
            self.saveNow()
        }
    }

    public func saveNow() {
        pendingSave?.cancel()
        let snapshot = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return }
        saveState = .saving
        writer(snapshot) { [weak self] success in
            guard let self, self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot else { return }
            if success {
                self.pendingSave?.cancel()
                self.draft = ""
                self.defaults.removeObject(forKey: self.key)
                self.saveState = .saved
            } else {
                self.saveState = .failed
            }
        }
    }

    public func retry() { saveNow() }

    private func persistDraft() {
        if draft.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(draft, forKey: key)
        }
    }
}
