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
    // MARK: - General
    // MARK: - Privacy

    /// Which screens carry a notch island. External monitors get a virtual
    /// notch that nests inside their menu bar; the choice applies immediately
    /// (AppDelegate listens and rebuilds the per-screen panels).
    ///
    /// Drawn as a two-card picker rather than a dropdown: "which screens" is a
    /// spatial choice, so each card shows a miniature laptop + external monitor
    /// with a bright pill on every screen that gets an island.
    /// The two placement cards, on a line of their own.
    ///
    /// The label moved out to the group caption above ("SHOW ON"): as an inline
    /// label it had to be nudged down by a hand-tuned 8pt to look level with the
    /// cards' first inner line, and it pushed the heaviest control on the page
    /// off the pane's left margin. Caption above, cards at the margin — no
    /// vertical fudge left to keep true.
    var placementRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(DisplayPlacement.allCases) { p in
                placementCard(p)
            }
            Spacer(minLength: 0)
        }
    }

    private func placementCard(_ p: DisplayPlacement) -> some View {
        let selected = placement == p
        return PickerCard(selected: selected) {
            selectPlacement(p)
        } content: {
            VStack(spacing: 7) {
                HStack(alignment: .bottom, spacing: 8) {
                    MiniDisplay(kind: .laptop, hasIsland: true)
                    MiniDisplay(kind: .external, hasIsland: p == .all)
                }
                // The unselected diagram dims as a whole so the bright pills
                // read as "what you'd get", not as a second active choice.
                .opacity(selected ? 1 : 0.55)
                Text(p.label)
                    .font(.sf(11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
            }
        }
    }

    private func selectPlacement(_ newValue: DisplayPlacement) {
        guard newValue != placement else { return }
        placement = newValue
        DisplayPlacement.current = newValue
        NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
    }

    /// Pick between the shipping icon and the adaptive Dot counterpart. The artwork
    /// itself is the useful preview, so this uses the same compact cards as the
    /// display-placement choice instead of hiding the difference in a menu.
    var appIconStyleRow: some View {
        settingRow(label: L("appearance.appIcon"), verticalAlignment: .top) {
            HStack(spacing: 8) {
                ForEach(AppIconStyle.allCases) { style in
                    appIconStyleCard(style)
                }
            }
        }
    }

    private func appIconStyleCard(_ style: AppIconStyle) -> some View {
        let selected = appIconStyle == style
        return PickerCard(selected: selected, width: 80) {
            selectAppIconStyle(style)
        } content: {
            VStack(spacing: 5) {
                if let icon = style.image {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(style.previewScale)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .clipped()
                        .id(appIconAppearanceRevision)
                }
                Text(style.label)
                    .font(.sf(10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func selectAppIconStyle(_ newValue: AppIconStyle) {
        guard newValue != appIconStyle else { return }
        Haptics.levelChange()
        appIconStyle = newValue
        AppIconStyle.current = newValue
        NotificationCenter.default.post(name: .appIconStyleChanged, object: nil)
    }

    /// Whether the app shows a Dock icon. Off by default — the notch overlay is a
    /// Whether the app shows a Dock icon — mirrors the persisted value; writes go
    /// through `selectDockIconVisibility` so `AppDelegate` flips the activation
    /// policy immediately.
    ///
    /// Hidden is the app's natural state: a menu-bar-less accessory whose only
    /// presence is the island. Some users want one place to relaunch or quit
    /// from, though.
    ///
    /// Drawn as a switch, not a menu: the choice is Shown/Hidden and nothing
    /// else, and a two-item popup makes you open it to learn that. The enum
    /// stays — it carries the persisted value and the activation-policy mapping,
    /// which a raw Bool would throw away.
    var dockIconRow: some View {
        // Not `aligned`: the shared label column was measured without this
        // row's ⓘ, which then sat on top of the switch. Launch at login and the
        // menu-bar row use the same plain inline layout.
        settingRow(label: L("general.dockIcon.toggle"),
                   info: L("general.dockIcon.footer")) {
            Toggle("", isOn: Binding(
                get: { dockIconVisibility == .shown },
                set: { Haptics.levelChange(); selectDockIconVisibility($0 ? .shown : .hidden) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Whether the app puts its icon in the menu bar. Shown by default — it's the
    /// one handle that works when the notch is behind a full-screen app and the
    /// summon shortcut has been forgotten. The choice applies immediately
    /// (AppDelegate adds/removes the status item).
    var menuBarIconRow: some View {
        settingRow(label: L("general.menuBarIcon.toggle")) {
            Toggle("", isOn: Binding(
                get: { menuBarIconVisibility == .shown },
                set: { Haptics.levelChange(); selectMenuBarIconVisibility($0 ? .shown : .hidden) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    private func selectMenuBarIconVisibility(_ newValue: MenuBarIconVisibility) {
        guard newValue != menuBarIconVisibility else { return }
        menuBarIconVisibility = newValue
        MenuBarIconVisibility.current = newValue
        NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
    }

    private func selectDockIconVisibility(_ newValue: DockIconVisibility) {
        guard newValue != dockIconVisibility else { return }
        dockIconVisibility = newValue
        DockIconVisibility.current = newValue
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
    }

    /// Where a note-classified line files: Apple Notes (the default), or per-day
    /// Markdown files in a folder the user owns — plain text they can grep, sync,
    /// and summarize, with no Automation prompt. The folder sub-row (current path
    /// + chooser) only appears while the Markdown destination is active.
    var noteDestinationRow: some View {
        settingRow(label: L("general.noteDestination"), forceStacked: true) {
            // Keep the expandable folder detail above the menu. Native menus open
            // downward, so this avoids the menu covering the path or its Choose
            // action while it is open.
            VStack(alignment: .leading, spacing: 8) {
                if noteDestination == .markdownFolder {
                    HStack(spacing: 10) {
                        Text(notesFolderDisplay)
                            .font(.sf(12))
                            .foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        SettingActionButton(title: L("general.noteFolder.choose")) { chooseNotesFolder() }
                            .fixedSize()
                    }
                }
                GlassMenu(title: noteDestination.label) {
                    ForEach(NoteDestination.allCases) { d in
                        Button { selectNoteDestination(d) } label: {
                            menuOption(d.label, selected: d == noteDestination)
                        }
                    }
                }
            }
        }
    }

    private func selectNoteDestination(_ newValue: NoteDestination) {
        guard newValue != noteDestination else { return }
        noteDestination = newValue
        NoteDestination.current = newValue
    }

    /// Standard folder picker for the Markdown destination. The modal steals key
    /// focus from the notch (the panel may fold behind it) — harmless: the pick
    /// lands in `UserDefaults`, and the row shows it whenever Settings reopens.
    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: FileNotesService.folderPath, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            FileNotesService.folderPath = url.path
            notesFolderDisplay = FileNotesService.folderDisplayPath
        }
    }

    /// Whether Notch launches itself when you log in. Off by default; flipping it
    /// on registers a login item via `SMAppService` so the notch is there from the
    /// first hover after every restart, with no manual relaunch.
    /// Custom instructions (XII-137): one short line of personal preference the
    /// model gets appended after its built-in persona on the Ask path — "always
    /// answer in English", "prefer code", "metric units". Capped at
    /// `NotchModel.customInstructionsLimit` chars (the binding truncates), empty by
    /// default. Deliberately understated: the hint says it refines, never that it
    /// overrides the core rules.
    /// Folded away at rest behind the same glass disclosure chip the API key uses:
    /// it is a once-in-a-while preference, not something the Model pane should
    /// spend a whole field on every time it opens.
    var customInstructionsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { instructionsSectionOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(instructionsSectionOpen ? 90 : 0))
                    Text(L("general.customInstructions"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .instructions ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .instructions ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .instructions }
                else if hoveredDisclosure == .instructions { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if instructionsSectionOpen {
                ZStack(alignment: .topLeading) {
                    if model.customInstructions.isEmpty {
                        Text(L("general.customInstructions.placeholder"))
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text3)
                            .allowsHitTesting(false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    TextField("", text: Binding(
                        get: { model.customInstructions },
                        set: { model.customInstructions = $0 }
                    ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Typing here counts as activity so a drifting pointer can't fold
                        // the panel mid-edit (same guard the API-key field uses).
                        .onChange(of: model.customInstructions) { model.noteUserTyping() }
                }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(0.06))
                )
            }
        }
        // An instruction already on file shouldn't hide behind a fold the user
        // never opened — start unfolded in that case, still foldable by hand.
        .onAppear {
            if !model.customInstructions.isEmpty { instructionsSectionOpen = true }
        }
    }

    var launchAtLoginRow: some View {
        settingRow(label: L("general.launchAtLogin")) {
            Toggle("", isOn: Binding(
                get: { launchAtLogin },
                set: { Haptics.levelChange(); selectLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }
}
