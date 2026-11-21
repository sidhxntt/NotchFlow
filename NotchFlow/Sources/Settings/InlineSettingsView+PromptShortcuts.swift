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
    /// Prompt shortcuts stay compact in the list. Selecting one presents its
    /// editor in the same centered dialog layer used by destructive confirmation;
    /// the list itself never unfolds or moves the groups below it.
    var promptShortcutsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title keeps the text position of every other group's title, and
            // the add chip hangs in an OVERLAY rather than in the row: a 24pt
            // button inside the HStack made this one header 24pt tall, so its text
            // sat ~5pt lower than "Summoning" below it and the block opened with a
            // band of air above the words.
            //
            // The header still RESERVES the chip's full height, with the text
            // pinned to the top of that box. This group is the first thing in the
            // Shortcuts pane, so its title sits at y=0 of the scroll content — a
            // 24pt chip centred on a ~15pt line overflowed ~5pt above the scroll
            // view's edge, which clipped the chip's upper arc clean off.
            Text(L("shortcuts.promptAction"))
                .font(.sf(12.5, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .frame(maxWidth: .infinity, minHeight: Self.promptAddChipSize,
                       alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    Button {
                        // Added to the list, NOT to disk: an untouched row is
                        // discarded when the editor closes (`dropBlankPromptShortcuts`),
                        // and the first real edit is what persists it — every field
                        // binding saves as it writes.
                        let shortcut = PromptShortcut()
                        withAnimation(Tokens.stackSpring) {
                            promptShortcuts.append(shortcut)
                        }
                        DispatchQueue.main.async {
                            presentedPromptShortcutID = shortcut.id
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.sf(10.5, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                            .frame(width: Self.promptAddChipSize,
                                   height: Self.promptAddChipSize)
                    }
                    .buttonStyle(ShortcutChipStyle())
                    .help(L("shortcuts.promptAction.add"))
                }

            // The header box already carries ~9pt of slack below the title text
            // (the chip's height minus the line's); these top pads add the rest of
            // the clearance, so the title reads as a section header rather than as
            // a label stuck to the first row.
            Group {
                if promptShortcuts.isEmpty {
                    Text(L("shortcuts.promptAction.empty"))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                } else {
                    // One row of small cards running right, scrolled rather than
                    // wrapped: the group keeps a fixed height however many
                    // shortcuts there are, so adding a tenth one never pushes the
                    // reference groups below it off the page.
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(promptShortcuts) { binding in
                                promptShortcutCardChip(binding)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        // The glow bleeds a couple of points past each card.
                        .padding(.horizontal, 3)
                        .padding(.vertical, 3)
                        // Give the last card a runway past the shared edge fade,
                        // so it can scroll fully into view instead of remaining
                        // dimmed when the list reaches its end.
                        .padding(.trailing, 24)
                    }
                    .scrollIndicators(.never)
                    // Match the panel's other overflowing lists: content
                    // dissolves into the boundary instead of being sliced by the
                    // scroll viewport. The resting leading edge stays crisp.
                    .scrollEdgeFade(leading: false, trailing: true,
                                    leadingFade: 0, trailingFade: 24)
                    .padding(.horizontal, -3)
                }
            }
            .padding(.top, 10)
        }
    }

    /// The card's fields and chips share a control height, so the two-column row
    /// reads as one grid rather than a pile of unrelated controls.
    private static let promptControlHeight: CGFloat = 30

    /// The header's add chip — smaller than a row's chips, and the height the
    /// title row reserves so the pane's top edge never shaves it.
    private static let promptAddChipSize: CGFloat = 24

    /// One shortcut, as a small card: its AI name over its chord. The whole card
    /// is the control — clicking it opens the editor — and the pointer is answered
    /// by the card's own surface lighting up, no revealed affordance.
    ///
    /// Width is CAPPED, not free: the name is generated prose, and one long one
    /// would otherwise set the width for the whole flow.
    private func promptShortcutCardChip(_ binding: PromptShortcut) -> some View {
        let hovered = hoveredPromptShortcutID == binding.id
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button {
            presentedPromptShortcutID = binding.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(promptShortcutName(binding)
                     ?? (binding.prompt.isEmpty
                         ? L("shortcuts.promptAction.placeholder")
                         : binding.prompt))
                    .font(.sf(12, weight: .medium))
                    .foregroundStyle(binding.prompt.isEmpty ? Tokens.text4 : Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let chord = binding.shortcut?.displayString {
                    HStack(spacing: 3) {
                        ForEach(Array(Self.keyCaps(chord).enumerated()), id: \.offset) { _, cap in
                            keyCap(cap)
                        }
                    }
                } else {
                    Text(L("shortcuts.promptAction.set"))
                        .font(.sf(11, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .overlay(
                            Capsule().strokeBorder(
                                .white.opacity(0.13),
                                style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        )
                }
            }
            .frame(width: Self.promptCardWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(PromptShortcutCardSurface(id: binding.id,
                                                  hovering: hovered,
                                                  shape: shape))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("shortcuts.promptAction.edit"))
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                if hovering {
                    hoveredPromptShortcutID = binding.id
                } else if hoveredPromptShortcutID == binding.id {
                    hoveredPromptShortcutID = nil
                }
            }
        }
    }

    /// The card's text column — two of them plus their gap fit the pane's width.
    private static let promptCardWidth: CGFloat = 118

    /// The row's AI name, when it has one worth showing beside the prompt.
    private func promptShortcutName(_ binding: PromptShortcut) -> String? {
        guard let name = binding.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name.caseInsensitiveCompare(
                binding.prompt.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        else { return nil }
        return name
    }

    func closePromptShortcutEditor(_ id: UUID) {
        if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        if recordingShortcut == .prompt(id) { recordingShortcut = nil }
        dropBlankPromptShortcuts()
    }

    /// Forget the rows nothing was ever set on. Opening the editor is how a
    /// shortcut is created, so backing out of it — Done, the ✕, or the scrim —
    /// must not leave "Prompt for the selected text / Set" standing in the list
    /// forever. A row with a prompt OR a chord is never touched: half-finished is
    /// still something the user typed.
    func dropBlankPromptShortcuts() {
        let blanks = promptShortcuts.filter(\.isBlank).map(\.id)
        guard !blanks.isEmpty else { return }
        for id in blanks {
            shortcutHints[.prompt(id)] = nil
            if recordingShortcut == .prompt(id) { recordingShortcut = nil }
            if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        }
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.removeAll(where: \.isBlank)
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
    }

    /// The editor: one subject (the prompt, full width under its own label) over a
    /// short settings list whose controls all land on the same right edge.
    ///
    /// The list used to run through `settingRow`, whose label column sizes itself
    /// per row — so "Prompt", "Model" and "Show in force click" each pushed their
    /// control to a different x and the card read as a pile of unrelated widgets.
    /// Here the label takes the leading edge, a `Spacer` takes the slack, and the
    /// control takes the trailing edge; the two menus, the chord cap and the
    /// switch stack into one column.
    func promptShortcutCard(_ binding: PromptShortcut) -> some View {
        let target = EditableShortcut.prompt(binding.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(promptShortcutName(binding)
                     ?? (binding.prompt.isEmpty
                         ? L("shortcuts.promptAction")
                         : binding.prompt))
                    .font(.sf(13.5, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    closePromptShortcutEditor(binding.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.sf(9, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.035, restStroke: 0.08))
                .accessibilityLabel(L("detached.close"))
            }
            .padding(.bottom, 14)

            // The prompt is what this card is about, not one field among five: it
            // gets the full width, under its own label, so a real instruction is
            // readable while it's being written.
            Text(L("shortcuts.group.prompt"))
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text3)
                .padding(.bottom, 6)

            ZStack(alignment: .leading) {
                if binding.prompt.isEmpty {
                    Text(L("shortcuts.promptAction.placeholder"))
                        .font(.sf(12.5))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: promptBinding(for: binding.id))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.sf(12.5))
                    .foregroundStyle(Tokens.text1)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.promptControlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .recessedSurface(in: RoundedRectangle(cornerRadius: 8), lit: false)
            .padding(.bottom, 14)

            VStack(spacing: 8) {
                promptCardRow(L("general.shortcut")) {
                    Button {
                        shortcutHints[target] = nil
                        recordingShortcut = recordingShortcut == target ? nil : target
                    } label: {
                        Text(recordingShortcut == target
                             ? L("general.shortcut.recording")
                             : (binding.shortcut?.displayString
                                ?? L("shortcuts.promptAction.set")))
                            .font(.sf(11.5, weight: recordingShortcut == target
                                ? .semibold : .medium))
                            .foregroundStyle(recordingShortcut == target
                                ? Tokens.text1 : Tokens.text2)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 72, minHeight: Self.promptControlHeight)
                    }
                    .buttonStyle(ShortcutChipStyle(active: recordingShortcut == target))
                }

                promptCardRow(L("shortcuts.promptAction.model")) {
                    promptModelPicker(for: binding.id)
                }

                if ForceClickFeature.isEnabled {
                    promptCardRow(L("shortcuts.promptAction.forceTouch")) {
                        Toggle("", isOn: promptForceTouchBinding(for: binding.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(Tokens.text2)
                            .frame(height: Self.promptControlHeight)
                    }
                }
            }

            if let hint = shortcutHints[target] {
                Text(hint)
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 8)
            }

            // Every field here writes through the moment it changes, but a card with
            // no way to say "that's it" leaves the user guessing whether anything
            // took — so the edit ends the way the app's other dialogs end: one
            // primary capsule that closes it. Delete sits under it in the quiet
            // register, on air alone (a rule across the card drew a second,
            // competing edge inside a slab that already has one).
            HStack(spacing: 10) {
                Button {
                    deletePromptShortcut(binding.id)
                } label: {
                    Text(L("shortcuts.promptAction.delete"))
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(Tokens.danger)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(PromptCardActionStyle(kind: .destructive))

                Button {
                    closePromptShortcutEditor(binding.id)
                } label: {
                    Text(L("shortcuts.promptAction.done"))
                        .font(.sf(12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(PromptCardActionStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// One line of the editor's settings list: label on the leading edge, control
    /// on the trailing one, every control the same height.
    private func promptCardRow<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(12.5))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: Self.promptControlHeight)
    }

    private func promptBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { promptShortcuts.first(where: { $0.id == id })?.prompt ?? "" },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                let wasReady = promptShortcuts[index].isReady
                promptShortcuts[index].prompt = value
                model.noteUserTyping()
                PromptShortcutStore.save(promptShortcuts)
                if wasReady != promptShortcuts[index].isReady {
                    NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
                    // The prompt just settled into a ready row — ask the AI for a
                    // display name once (it only writes when one is still missing,
                    // so an already-named shortcut is never touched).
                    if promptShortcuts[index].isReady {
                        model.ensurePromptShortcutName(promptShortcuts[index])
                    }
                }
            }
        )
    }

    /// One provider's pinnable models, precomputed so the menu below stays a
    /// shallow expression — the nested ForEach/Section written inline in the row
    /// blew past the type checker's budget.
    private struct PromptModelGroup: Identifiable {
        let provider: Provider
        let models: [String]
        var id: String { provider.rawValue }
    }

    /// Providers a shortcut can actually be pinned to: the ones that can serve a
    /// request as things stand (key stored, or a signed-in CLI). Offering a
    /// provider with no key would be offering a pin that silently falls back.
    private var promptModelGroups: [PromptModelGroup] {
        Provider.offered
            .filter(ModelCatalogStore.ready)
            .map { PromptModelGroup(provider: $0, models: $0.availableModels) }
    }

    /// A dedicated model control in the card, rather than a submenu inside an
    /// unrelated overflow menu. The closed chip always names what this shortcut
    /// will run; the menu keeps native sections and checkmarks for the long list.
    private func promptModelPicker(for id: UUID) -> some View {
        let selection = promptModelBinding(for: id)
        return GlassMenu(title: promptModelDisplayName(for: id)) {
            ForEach(promptModelGroups) { group in
                SwiftUI.Section(group.provider.displayName) {
                    ForEach(group.models, id: \.self) { name in
                        let pin = ModelPin(provider: group.provider, model: name)
                        Button { selection.wrappedValue = pin } label: {
                            menuOption(ModelRatings.prettyName(for: name,
                                                               provider: group.provider),
                                       selected: selection.wrappedValue == pin)
                        }
                    }
                }
            }
        }
    }

    /// The model chip names the shortcut's saved model. Provider remains visible
    /// inside the opened menu, where it helps disambiguate choices without making
    /// the closed chip verbose.
    private func promptModelDisplayName(for id: UUID) -> String {
        let pin = promptShortcuts.first(where: { $0.id == id })?.pin
            ?? PromptShortcut.currentModelPin
        return ModelRatings.prettyName(for: pin.model, provider: pin.provider)
    }

    /// Whether the force click box offers this row as a button. Persisted like
    /// every other row property, and the composer reads the list fresh on each
    /// appearance, so a change takes effect on the next press.
    private func promptForceTouchBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                promptShortcuts.first(where: { $0.id == id })?.appearsInForceTouch ?? true
            },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                promptShortcuts[index].showsInForceTouch = value
                PromptShortcutStore.save(promptShortcuts)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            }
        )
    }

    /// The row's pinned backend. Every selection is a concrete provider/model
    /// pair; changing the app-wide default cannot rewrite it.
    private func promptModelBinding(for id: UUID) -> Binding<ModelPin> {
        Binding(
            get: {
                promptShortcuts.first(where: { $0.id == id })?.pin
                    ?? PromptShortcut.currentModelPin
            },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                promptShortcuts[index].pin = value
                PromptShortcutStore.save(promptShortcuts)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            }
        )
    }

    private func deletePromptShortcut(_ id: UUID) {
        let target = EditableShortcut.prompt(id)
        if recordingShortcut == target { recordingShortcut = nil }
        shortcutHints[target] = nil
        if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.removeAll { $0.id == id }
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
    }
}
