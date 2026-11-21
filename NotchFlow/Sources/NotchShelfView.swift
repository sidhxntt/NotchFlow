import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct NotchShelfView: View {
    @ObservedObject var capabilities: NotchCapabilityStore
    @ObservedObject private var conversions = FileConversionService.shared
    @State private var isDropTargeted = false
    @State private var selectedItemIDs = Set<UUID>()
    /// Where a ⇧-click range starts: the row most recently toggled on.
    @State private var selectionAnchor: UUID?
    /// The row the keyboard is on: the moving end of a ⇧-arrow range.
    @State private var selectionCursor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("File tray")
                        .font(.sf(11, weight: .semibold)).foregroundStyle(Tokens.text3)
                    Spacer(minLength: 4)
                    shelfActions
                }
                if capabilities.shelfItems.isEmpty {
                    Label("Drop files, folders, links, or text here", systemImage: "tray.and.arrow.down")
                        .font(.sf(11, weight: .regular)).foregroundStyle(Tokens.text3)
                } else {
                    if capabilities.shelfItems.count > NotchUtilitiesLayout.maximumVisibleRows {
                        ScrollViewReader { proxy in
                            ScrollView {
                                shelfRows
                            }
                            .frame(height: 122)
                            .scrollIndicators(.hidden)
                            // Keep the keyboard's row on screen as arrows walk it.
                            .onChange(of: selectionCursor) { _, cursor in
                                if let cursor { proxy.scrollTo(cursor) }
                            }
                        }
                    } else {
                        shelfRows
                    }
                    missingCLINote
                }
            }
        .padding(10)
        // Arrow keys walk the tray once a row is selected; ⇧ extends the range
        // and ⌘A takes every row. With nothing selected the keys fall through
        // to the prompt as before.
        .background(KeyEventCatcher { event in handleKey(event) })
        // Width as well as height: without `maxWidth`, the background hugged this
        // card's content instead of filling its column, so the File tray drew
        // narrower than the Calendar beside it and the gap between them stopped
        // matching the layout's actual gutter — which is what made the centered
        // toggle circle read as off-centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isDropTargeted ? Color.white.opacity(0.7) : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: ShelfDropService.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            Task {
                let items = await ShelfDropService.items(from: providers)
                await MainActor.run { capabilities.ingest(items) }
            }
            return true
        }
        // Resolving `auto` costs a login-shell PATH probe plus a spawn, so it
        // happens once, off the main thread, the first time the tray is drawn.
        .task { conversions.prepare(shell: .notch) }
    }

    private var shelfRows: some View {
        VStack(spacing: 7) {
            ForEach(capabilities.shelfItems) { item in
                HStack(spacing: 8) {
                    shelfIcon(for: item)
                        .frame(width: 28, height: 28)
                        .padding(4).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.sf(12, weight: .medium)).lineLimit(1)
                        // The type line doubles as the status line: a conversion
                        // is about this row, so it reports here rather than
                        // anywhere the eye would have to go looking for it.
                        shelfSubtitle(for: item)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(selectedItemIDs.contains(item.id) ? Color.white.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                // One AppKit layer for both gestures. SwiftUI's `onDrag` can
                // hand over a single item only, so a multi-selection could never
                // leave the tray together; and the click needs its modifier keys
                // to tell a ⇧-range from a toggle.
                .overlay {
                    ShelfRowInteraction(
                        onClick: { modifiers in click(item.id, modifiers: modifiers) },
                        dragPayloads: { dragPayloads(startingAt: item) })
                }
            }
        }
    }

    @ViewBuilder private var shelfActions: some View {
        if !selectedItems.isEmpty {
            let urls = selectedItems.compactMap(\.url)
            // One menu for any selection of same-type files: the action runs on
            // every one of them. A mixed selection has no action in common, so
            // it gets the dimmed wand rather than a menu that would half-apply.
            if let batch = ShelfTraySelection.sameTypeFiles(selectedItems) {
                conversionMenu(for: batch)
            } else if selectedItems.contains(where: { $0.url?.isFileURL == true }) {
                ShelfActionButton(symbol: "wand.and.rays", label: "Select files of one type to convert") {}
                    .disabled(true).opacity(0.35)
            }
            if !urls.isEmpty {
                ShelfActionButton(symbol: "eye", label: "Quick Look") {
                    ShelfPreviewer.shared.preview(urls)
                }
                ShelfShareButton(urls: urls)
            }
            let text = selectedItems.filter { $0.url == nil }
            if !text.isEmpty {
                ShelfActionButton(symbol: "document.on.document", label: "Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.map(\.displayName).joined(separator: "\n"), forType: .string)
                }
            }
            ShelfActionButton(symbol: "xmark", label: "Remove", isDestructive: true) {
                removeSelection()
            }
        } else {
            ShelfActionButton(symbol: "wand.and.rays", label: "Convert or process") {}
                .disabled(true).opacity(0.35)
            ShelfActionButton(symbol: "eye", label: "Quick Look") {}
                .disabled(true).opacity(0.35)
            ShelfActionButton(symbol: "square.and.arrow.up", label: "Share") {}
                .disabled(true).opacity(0.35)
            ShelfActionButton(symbol: "xmark", label: "Remove", isDestructive: true) {}
                .disabled(true).opacity(0.35)
        }
    }

    private var selectedItems: [NotchShelfItem] {
        ShelfTraySelection.items(in: capabilities.shelfItems, selectedIDs: selectedItemIDs)
    }

    private func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let next = ShelfTraySelection.selection(afterClicking: id,
                                                extendingRange: modifiers.contains(.shift),
                                                in: capabilities.shelfItems,
                                                current: selectedItemIDs,
                                                anchor: selectionAnchor)
        selectedItemIDs = next.selection
        selectionAnchor = next.anchor
        selectionCursor = next.selection.contains(id) ? id : next.anchor
    }

    /// Takes the selected rows out of the tray. The files themselves stay
    /// where they are on disk.
    private func removeSelection() {
        selectedItemIDs.forEach { capabilities.removeShelfItem(id: $0) }
        selectedItemIDs.removeAll()
        selectionAnchor = nil
        selectionCursor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !selectedItemIDs.isEmpty else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // While a text field holds the caret, Space, ⌘A and ⌘⌫ are editing
        // keys and stay with it. Clicking a row clears the caret.
        let editingText = event.window?.firstResponder is NSTextView
        // keyCode 49 is Space: Quick Look, as in Finder.
        if event.keyCode == 49, modifiers.isEmpty, !editingText {
            let urls = selectedItems.compactMap(\.url)
            guard !urls.isEmpty else { return false }
            ShelfPreviewer.shared.toggle(urls)
            return true
        }
        // keyCode 51 is ⌫: ⌘⌫ removes, as it moves to Trash in Finder.
        if event.keyCode == 51, modifiers == .command, !editingText {
            removeSelection()
            return true
        }
        // keyCode 0 is A.
        if event.keyCode == 0, modifiers == .command, !editingText {
            selectedItemIDs = Set(capabilities.shelfItems.map(\.id))
            return true
        }
        // keyCode 126 is ↑, 125 is ↓. Arrow keys carry .function and
        // .numericPad, so test for ⇧ rather than comparing the whole set.
        let step: Int
        switch event.keyCode {
        case 126: step = -1
        case 125: step = 1
        default: return false
        }
        guard modifiers.isDisjoint(with: [.command, .option, .control]),
              let next = ShelfTraySelection.selection(afterMoving: step,
                                                      extendingRange: modifiers.contains(.shift),
                                                      in: capabilities.shelfItems,
                                                      current: selectedItemIDs,
                                                      anchor: selectionAnchor,
                                                      cursor: selectionCursor) else { return false }
        selectedItemIDs = next.selection
        selectionAnchor = next.anchor
        selectionCursor = next.cursor
        return true
    }

    /// Dragging a selected row carries the whole selection, in tray order —
    /// what Finder does. Dragging an unselected row carries just that row and
    /// leaves the selection alone.
    private func dragPayloads(startingAt item: NotchShelfItem) -> [ShelfDragPayload] {
        let items = selectedItemIDs.contains(item.id) ? selectedItems : [item]
        return items.compactMap(ShelfDragPayload.init)
    }

    @ViewBuilder private func shelfIcon(for item: NotchShelfItem) -> some View {
        if let url = item.url, url.isFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: item.url == nil ? "text.alignleft" : "link")
                .resizable().scaledToFit().foregroundStyle(Tokens.text3).padding(5)
        }
    }

    private func itemTypeLabel(_ item: NotchShelfItem) -> String {
        switch item.kind {
        case .file:
            let extensionName = item.url?.pathExtension.uppercased() ?? "FILE"
            return extensionName.isEmpty ? "FILE" : extensionName
        case .link: return "LINK"
        case .text: return "TEXT"
        }
    }

    // MARK: - Conversions

    /// The type line, or — while a conversion is in flight or has just landed —
    /// what happened to this row. One line either way, so the tray never
    /// reflows under a running job.
    @ViewBuilder private func shelfSubtitle(for item: NotchShelfItem) -> some View {
        let key = item.id.uuidString
        if let action = conversions.running[key] {
            HStack(spacing: 5) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .scaleEffect(0.62)
                    .frame(width: 9, height: 9)
                Text(progressLabel(action))
                    .font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3)
                    .lineLimit(1)
            }
        } else if let outcome = conversions.outcomes[key] {
            Text(outcomeLabel(outcome))
                .font(.sf(9.5, weight: .medium))
                // Only a genuine failure gets colour. "Nothing to do" is a real
                // answer from these tools (an already-optimal image, a photo
                // Vision finds no subject in) and should not read as an error.
                .foregroundStyle(outcome.kind == .failure ? Tokens.danger : Tokens.text3)
                .lineLimit(1).truncationMode(.tail)
                .help(outcome.message)
        } else {
            Text(itemTypeLabel(item))
                .font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3)
        }
    }

    private func progressLabel(_ action: FileConversionAction) -> String {
        switch action.tool {
        case .convert, .image: return "Converting to \(action.label)…"
        case .bg: return "Removing background…"
        case .compress: return "Compressing (\(action.label.lowercased()))…"
        }
    }

    private func outcomeLabel(_ outcome: FileConversionOutcome) -> String {
        switch outcome.kind {
        case .success: return "Saved \(outcome.message)"
        case .noChange, .failure: return outcome.message
        }
    }

    /// Only rendered for a file the CLI can actually do something with, and only
    /// once `auto` has resolved — a row with nothing to offer, or an unresolved
    /// binary, gets no affordance at all rather than a dropdown that opens onto
    /// an apology.
    @ViewBuilder private func conversionMenu(for batch: [(item: NotchShelfItem, url: URL)]) -> some View {
        if conversions.resolvedBinary != nil, let first = batch.first {
            // Same extension throughout, so the first file's actions are every
            // file's actions.
            let actions = FileConversionCatalog.actions(for: first.url)
            if !actions.isEmpty {
                ShelfConversionMenu(
                    actions: actions,
                    isBusy: batch.contains { conversions.isRunning(key: $0.item.id.uuidString) }
                ) { action in
                    // Each file is its own job under its own key, so every row
                    // reports its own progress and outcome on its type line.
                    for (item, url) in batch {
                        conversions.run(action, on: url, key: item.id.uuidString) { outputs in
                            // The results join the tray, so the next thing you do
                            // with them (Quick Look, drag out, convert again) is one
                            // click away. `addShelfItems` dedupes on path.
                            capabilities.ingest(outputs.map { NotchShelfItem.file(url: $0) })
                        }
                    }
                }
            }
        }
    }

    /// One quiet line for the whole tray, not a dead control on every row. Shown
    /// only when the CLI is genuinely absent *and* something in the tray could
    /// have used it — otherwise it is an advert for a feature nobody asked for.
    @ViewBuilder private var missingCLINote: some View {
        if conversions.availability == .missing, hasConvertibleFile {
            Text("Conversions need the Media Automations CLI — npm i -g my_media_automations")
                .font(.sf(9, weight: .medium)).foregroundStyle(Tokens.text3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasConvertibleFile: Bool {
        capabilities.shelfItems.contains { item in
            guard let url = item.url, url.isFileURL else { return false }
            return !FileConversionCatalog.actions(for: url).isEmpty
        }
    }
}

/// The per-file dropdown. Sized and coloured exactly like `ShelfActionButton`
/// so the row reads as one cluster of affordances rather than a button strip
/// with a menu bolted on, and grouped by tool so a PNG's nine options arrive as
/// three short lists instead of one wall.
private struct ShelfConversionMenu: View {
    let actions: [FileConversionAction]
    let isBusy: Bool
    let run: (FileConversionAction) -> Void

    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.actions) { action in
                        Button(action.label) { run(action) }
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0.05)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // A second job on a row already running one would race the first for the
        // same output name, so the affordance goes quiet until it finishes.
        .disabled(isBusy)
        .opacity(isBusy ? 0.35 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .help("Convert or process")
        .accessibilityLabel("Convert or process")
    }

    /// Grouped in the order the catalog emits them, so "Convert to" is always
    /// first and the destructive-sounding options are further down.
    private var sections: [(title: String, actions: [FileConversionAction])] {
        var ordered: [String] = []
        var grouped: [String: [FileConversionAction]] = [:]
        for action in actions {
            let title = action.tool.sectionTitle
            if grouped[title] == nil { ordered.append(title) }
            grouped[title, default: []].append(action)
        }
        return ordered.map { ($0, grouped[$0] ?? []) }
    }
}

private extension FileConversionShell {
    /// Joins `FileConversionService` (which compiles as part of
    /// `NotchCapabilities`) to `ShellEnvironment` (which does not). Without the
    /// login-shell PATH, `auto` is invisible to a GUI process — it lives under
    /// nvm — and even once found, its `#!/usr/bin/env node` shebang needs the
    /// same PATH to resolve `node`.
    static let notch = FileConversionShell(
        which: { ShellEnvironment.which($0) },
        makeProcess: { ShellEnvironment.makeProcess($0, $1, cwd: $2) })
}

/// A row action in the File tray. The tray's actions used to be raw SF Symbols
/// dropped straight into the row: three different optical widths at body size,
/// no container, no hover feedback, and clickable only on the glyph itself. This
/// gives them one uniform 22pt well in the panel's own material, a hover lift,
/// and a hit area that matches what is drawn.
private struct ShelfActionButton: View {
    let symbol: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // One size for every action, so the eye, the share arrow and the
                // cross carry the same weight in the row.
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        if isDestructive { return hovering ? Tokens.danger : Tokens.text3 }
        return hovering ? Tokens.text1 : Tokens.text2
    }

    /// Resting wells are barely there — the row is about the file, not its
    /// controls. Hover is what promotes one to a button, and the discard warms
    /// red only then, so the row never looks like it is asking to be emptied.
    private var fill: Color {
        if isDestructive { return hovering ? Tokens.danger.opacity(0.18) : Color.white.opacity(0.05) }
        return Color.white.opacity(hovering ? 0.14 : 0.05)
    }
}

private struct ShelfShareButton: View {
    let urls: [URL]
    @State private var anchorView: NSView?

    var body: some View {
        ShelfActionButton(symbol: "square.and.arrow.up", label: "Share") {
            guard let anchorView else { return }
            ShelfSharePresenter.shared.share(urls, from: anchorView)
        }
        .background(ShelfShareAnchor { view in
            anchorView = view
        })
    }
}

private struct ShelfShareAnchor: NSViewRepresentable {
    let didMount: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { didMount(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { didMount(nsView) }
    }
}

@MainActor
private final class ShelfPreviewer: NSObject, QLPreviewPanelDataSource {
    static let shared = ShelfPreviewer()
    private var urls: [URL] = []

    /// Space's Finder behaviour: open the preview, or close it if it's up.
    func toggle(_ urls: [URL]) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            preview(urls)
        }
    }

    func preview(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }
}

@MainActor
private final class ShelfSharePresenter: NSObject {
    static let shared = ShelfSharePresenter()
    func share(_ urls: [URL], from anchorView: NSView) {
        let picker = NSSharingServicePicker(items: urls)
        picker.show(
            relativeTo: ShelfSharingLayout.pickerRect(for: anchorView.bounds),
            of: anchorView,
            preferredEdge: .minY
        )
    }
}

// MARK: - Row click + drag source

/// What one tray row puts on the drag pasteboard, and the picture it drags.
struct ShelfDragPayload {
    let writer: NSPasteboardWriting
    let image: NSImage

    init?(_ item: NotchShelfItem) {
        switch item.kind {
        case .file:
            guard let url = item.url else { return nil }
            writer = url as NSURL
            image = NSWorkspace.shared.icon(forFile: url.path)
        case let .link(url):
            writer = url as NSURL
            image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case let .text(value):
            // The full text, not `displayName` — that is trimmed to 48 characters
            // for the row and would silently truncate what lands in the target.
            writer = value as NSString
            image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// Click and drag handling for a File tray row, in AppKit.
///
/// `NSView.beginDraggingSession(with:)` takes any number of dragging items,
/// which is the only way to carry a multi-selection out of the tray as separate
/// files; SwiftUI's `onDrag` is limited to one `NSItemProvider`. Owning the
/// mouse here also gives the click its modifier flags for ⇧-range selection.
struct ShelfRowInteraction: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags) -> Void
    let dragPayloads: () -> [ShelfDragPayload]

    func makeNSView(context: Context) -> ShelfRowInteractionView {
        let view = ShelfRowInteractionView()
        view.onClick = onClick
        view.dragPayloads = dragPayloads
        return view
    }

    func updateNSView(_ view: ShelfRowInteractionView, context: Context) {
        view.onClick = onClick
        view.dragPayloads = dragPayloads
    }
}

final class ShelfRowInteractionView: NSView, NSDraggingSource {
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var dragPayloads: () -> [ShelfDragPayload] = { [] }

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    /// Below this, a slightly unsteady click is still a click.
    private let dragThreshold: CGFloat = 4

    // The notch panel is rarely key; the first click must still land.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
        // Picking a row takes the caret out of the prompt, so the tray's
        // keys (Space, ⌘A, ⌘⌫) act on the files instead of on typed text.
        window?.makeFirstResponder(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= dragThreshold else { return }
        didStartDrag = true

        let payloads = dragPayloads()
        guard !payloads.isEmpty else { return }
        let origin = convert(down.locationInWindow, from: nil)
        let side: CGFloat = 32
        let items = payloads.enumerated().map { index, payload -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            // A small fan, so a multi-file drag visibly carries several things.
            let offset = CGFloat(min(index, 4)) * 5
            item.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset,
                                         y: origin.y - side / 2 - offset,
                                         width: side, height: side),
                                  contents: payload.image)
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !didStartDrag else { return }
        onClick(event.modifierFlags)
    }

    /// Copy only outside the app. `.generic` lets Finder treat a same-volume drop
    /// as a move, which would pull the user's original file out of its folder.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .generic]
    }
}
