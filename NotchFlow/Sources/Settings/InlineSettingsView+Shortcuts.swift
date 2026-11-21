import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

@MainActor
extension InlineSettingsView {
    // MARK: - Shortcuts

    /// One first-class settings category for every keyboard control. Product
    /// actions are editable in place; text-field conventions remain read-only so
    /// Return, arrows, paste and `/` continue to behave predictably.
    ///
    /// Chords that do exactly what every Mac app does with them — ⌘, for
    /// Settings, ⌘W to close a window, ⎋ to back out — are deliberately left
    /// out. Nobody comes to a reference for those, and they dilute the ones
    /// worth reading. A row earns its place by teaching something the system
    /// convention wouldn't.
    var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            promptShortcutsGroup
            ForEach(Array(AppShortcutReference.groups(
                summonHotKey: summonHotKey,
                shortcuts: appShortcuts
            ).enumerated()),
                    id: \.offset) { _, group in
                shortcutGroup(group.title, group.entries)
            }
        }
        // No top runway: this pane starts flush with the sidebar's first item,
        // like every other one. The top taper only exists once the pane is
        // actually scrolled (see `paneContent`), so resting rows are never dimmed
        // and no pane has to buy its way out of the gradient with empty space.
        .padding(.bottom, 18)
        // One monitor serves every row. Switching chips changes only the target;
        // leaving the pane dismantles the monitor automatically.
        .background(HotKeyRecorder(active: recordingShortcut != nil,
                                   onCapture: captureShortcut,
                                   onDoubleModifier: captureDoubleModifier,
                                   onCancel: { recordingShortcut = nil }))
        // Leaving the pane ends recording outright. The armed target used to
        // survive in `@State` while the monitor was dismantled, so coming back
        // silently re-armed the old row and the next chord landed on it.
        .onDisappear {
            recordingShortcut = nil
            presentedPromptShortcutID = nil
            hoveredPromptShortcutID = nil
            dropBlankPromptShortcuts()
        }
        // Chat can rebind any of these too (`manage_app_settings`). Re-read the
        // stores when it does, so the pane never shows a binding that is no
        // longer the one the app is registering.
        .onReceive(NotificationCenter.default.publisher(for: .summonHotKeyChanged)) { _ in
            summonHotKey = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShortcutsChanged)) { _ in
            appShortcuts = AppShortcutStore.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptShortcutsChanged)) { _ in
            promptShortcuts = PromptShortcutStore.current
        }
    }

    /// One titled block. The description reads down the left edge and the keycaps
    /// hang off the right, with a hairline between rows — a table, not a list of
    /// sentences, so the eye can drop straight to the chord it came for.
    private func shortcutGroup(_ title: String, _ rows: [AppShortcutReference.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.sf(12.5, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .padding(.bottom, 3)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Text(row.label)
                            .font(.sf(12.5))
                            .foregroundStyle(row.editable == nil ? Tokens.text3 : Tokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if let editable = row.editable {
                            editableShortcutControl(editable, row: row)
                        } else if let note = row.note {
                            Text(note)
                                .font(.sf(12))
                                .foregroundStyle(Tokens.text4)
                        } else {
                            HStack(spacing: 6) {
                                ForEach(Array(row.chords.enumerated()), id: \.offset) { i, chord in
                                    if i > 0 {
                                        Text(L("shortcuts.or"))
                                            .font(.sf(11))
                                            .foregroundStyle(Tokens.text4)
                                    }
                                    HStack(spacing: 3) {
                                        ForEach(Array(Self.keyCaps(chord).enumerated()), id: \.offset) { _, cap in
                                            keyCap(cap, readOnly: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let editable = row.editable, let hint = shortcutHints[editable] {
                        Text(hint)
                            .font(.sf(11))
                            .foregroundStyle(Tokens.text3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard let editable = row.editable else { return }
                    withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                        if hovering {
                            hoveredShortcutRow = editable
                        } else if hoveredShortcutRow == editable {
                            hoveredShortcutRow = nil
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editableShortcutControl(
        _ target: EditableShortcut,
        row: AppShortcutReference.Entry
    ) -> some View {
        HStack(spacing: 5) {
            // Summon has two useful modifier-only presets, so its inboard control
            // is a Reset To menu instead of a one-way default reset. Other editable
            // chords keep the compact reset affordance when they differ from
            // their shipped value.
            if target == .summon {
                Menu {
                    Button("Double-tap Command") {
                        restoreSummonDoubleTap(UInt32(cmdKey))
                    }
                    Button("Double-tap Option") {
                        restoreSummonDoubleTap(UInt32(optionKey))
                    }
                } label: {
                    Text(L("general.shortcut.resetTo"))
                        .font(.sf(10.5, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .menuStyle(.button)
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .menuIndicator(.hidden)
                .opacity(hoveredShortcutRow == target ? 1 : 0)
                .allowsHitTesting(hoveredShortcutRow == target)
            } else if shortcutIsModified(target) {
                Button {
                    resetShortcut(target)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.sf(10.5, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .help(L("shortcuts.reset"))
                .opacity(hoveredShortcutRow == target ? 1 : 0)
                .allowsHitTesting(hoveredShortcutRow == target)
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            Button {
                shortcutHints[target] = nil
                recordingShortcut = recordingShortcut == target ? nil : target
            } label: {
                Text(recordingShortcut == target
                     ? L("general.shortcut.recording")
                     : (row.note ?? row.chords.first ?? L("general.shortcut.off")))
                    .font(.sf(11.5, weight: recordingShortcut == target ? .semibold : .medium))
                    .foregroundStyle(recordingShortcut == target ? Tokens.text1 : Tokens.text2)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 48, minHeight: 24)
            }
            .buttonStyle(ShortcutChipStyle(active: recordingShortcut == target))
            // Turning off the global summon remains available without leaving a
            // permanent trailing control in every default row.
            .contextMenu {
                if target == .summon, summonHotKey.enabled {
                    Button(L("general.shortcut.disable")) { disableSummonHotKey() }
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: shortcutIsModified(target))
    }

    private func shortcutIsModified(_ target: EditableShortcut) -> Bool {
        switch target {
        case .summon:
            return summonHotKey != .defaultConfig
        case .action(let action):
            return (appShortcuts[action] ?? action.defaultChord) != action.defaultChord
        case .prompt:
            return false
        }
    }

    /// One conflict pass for every editable chord. `AppShortcutStore` owns the
    /// fixed/local actions and summon; the two global selected-text families live
    /// beside it and therefore add their owners here.
    private func shortcutConflictOwner(
        for chord: ShortcutChord,
        editing target: EditableShortcut
    ) -> String? {
        let appOwner: String? = switch target {
        case .summon:
            AppShortcutStore.conflictOwner(for: chord, editingSummon: true)
        case .action(let action):
            AppShortcutStore.conflictOwner(for: chord, editingAction: action)
        case .prompt:
            AppShortcutStore.conflictOwner(for: chord)
        }
        if let appOwner { return appOwner }

        let editingPromptID: UUID? = if case .prompt(let id) = target { id } else { nil }
        if promptShortcuts.contains(where: {
            $0.id != editingPromptID && $0.shortcut == chord
        }) {
            return L("shortcuts.promptAction")
        }
        return nil
    }

    /// Recorder validation is deliberately shared for summon and local actions:
    /// one real modifier is required, and a chord may have exactly one owner.
    private func captureShortcut(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard let target = recordingShortcut else { return }
        let chord = ShortcutChord(keyCode: keyCode,
                                  modifiers: SummonHotKey.carbonModifiers(from: flags))
        let realModifierMask = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard chord.modifiers & realModifierMask != 0 else {
            shortcutHints[target] = L("general.shortcut.needModifier")
            return
        }

        if let owner = shortcutConflictOwner(for: chord, editing: target) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy", owner)
            return
        }

        let unchangedGlobal: Bool = switch target {
        case .summon:
            summonHotKey.enabled && !summonHotKey.isDoubleTap
                && summonHotKey.keyCode == chord.keyCode
                && summonHotKey.modifiers == chord.modifiers
        case .prompt(let id):
            promptShortcuts.first(where: { $0.id == id })?.shortcut == chord
        case .action:
            true
        }
        let needsGlobalProbe: Bool = switch target {
        case .summon, .prompt: true
        case .action: false
        }
        if needsGlobalProbe, !unchangedGlobal,
           !HotKey.isAvailable(keyCode: chord.keyCode,
                               modifiers: chord.modifiers) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy",
                                      L("shortcuts.reserved.system"))
            return
        }

        shortcutHints[target] = nil
        recordingShortcut = nil
        switch target {
        case .summon:
            commitSummonHotKey(SummonHotKey(keyCode: chord.keyCode,
                                            modifiers: chord.modifiers,
                                            enabled: true))
        case .action(let action):
            AppShortcutStore.set(chord, for: action)
            appShortcuts[action] = chord
        case .prompt(let id):
            guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
            promptShortcuts[index].shortcut = chord
            PromptShortcutStore.save(promptShortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        }
    }

    /// A bare modifier never produces `keyDown`, so summon and prompt shortcut
    /// rows receive double-Command / double-Option separately from ordinary
    /// chords. Panel-local action shortcuts remain chord-only.
    private func captureDoubleModifier(_ modifier: UInt32) {
        guard let target = recordingShortcut else { return }
        if case .action = target { return }
        let chord = ShortcutChord.doubleTap(modifier)

        if let owner = shortcutConflictOwner(for: chord, editing: target) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy", owner)
            return
        }

        switch target {
        case .summon:
            shortcutHints[target] = nil
            recordingShortcut = nil
            commitSummonHotKey(SummonHotKey(keyCode: 0,
                                            modifiers: 0,
                                            doubleTapModifier: modifier,
                                            enabled: true))
        case .prompt(let id):
            guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
            shortcutHints[target] = nil
            recordingShortcut = nil
            promptShortcuts[index].shortcut = chord
            PromptShortcutStore.save(promptShortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        case .action:
            break
        }
    }

    private func resetShortcut(_ target: EditableShortcut) {
        recordingShortcut = nil
        shortcutHints[target] = nil
        switch target {
        case .summon:
            commitSummonHotKey(.defaultConfig)
        case .action(let action):
            AppShortcutStore.reset(action)
            appShortcuts[action] = action.defaultChord
        case .prompt:
            break
        }
    }

    private func restoreSummonDoubleTap(_ modifier: UInt32) {
        recordingShortcut = nil
        let chord = ShortcutChord.doubleTap(modifier)
        if let owner = shortcutConflictOwner(for: chord, editing: .summon) {
            shortcutHints[.summon] = L("shortcuts.conflict.usedBy",
                                       owner)
            return
        }
        shortcutHints[.summon] = nil
        commitSummonHotKey(SummonHotKey(keyCode: 0,
                                        modifiers: 0,
                                        doubleTapModifier: modifier,
                                        enabled: true))
    }

    private func disableSummonHotKey() {
        recordingShortcut = nil
        shortcutHints[.summon] = nil
        var off = summonHotKey
        off.enabled = false
        commitSummonHotKey(off)
    }

    private func commitSummonHotKey(_ newValue: SummonHotKey) {
        summonHotKey = newValue
        SummonHotKey.current = newValue
        NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
    }

    /// Split a written chord ("⇧⌘I", "⌘,") into the individual caps a keyboard
    /// sheet draws — one per modifier, then the key itself as the last cap. The
    /// key half is taken whole rather than per-character, so a named key ("Space",
    /// "F5") from a recorded summon chord stays on one cap instead of exploding
    /// into letters.
    static func keyCaps(_ chord: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(chord)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }

    /// One keycap. Deliberately the same skin as the summon recorder's chip in
    /// General — that chip *is* a keycap showing a chord, so the reference's caps
    /// and the editable one read as the same object at two sizes.
    func keyCap(_ text: String, readOnly: Bool = false) -> some View {
        Text(text)
            .font(.sf(11, weight: .medium))
            .foregroundStyle(readOnly ? Tokens.text4 : Tokens.text2)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                Capsule()
                    .fill(.white.opacity(readOnly ? 0.025 : 0.07))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        .white.opacity(readOnly ? 0.075 : 0.13),
                        style: StrokeStyle(lineWidth: 0.5,
                                           dash: readOnly ? [2, 2] : [])
                    )
            )
    }
}
