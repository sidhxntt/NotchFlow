import AppKit

/// The menu bar item — the app's only always-visible affordance besides the
/// notch itself. Notch is an `.accessory` app with no Dock icon by default, so
/// until now the *only* way in was hovering the notch or firing the summon
/// shortcut; a user who forgot the shortcut and was on a full-screen Space had
/// no handle at all. This is that handle: click the icon, get a menu.
///
/// Shape follows the convention every mature menu-bar utility settles on (and
/// the Typeless menu Cyrus pointed at): the two or three things you actually
/// come here to *do* on top, the one setting you flip most often as a submenu,
/// then the housekeeping block (version / what's new / update) and Quit. Nothing
/// here is a feature of its own — every item routes into a path the panel
/// already owns, so the menu can never drift from the app.
///
/// The menu is rebuilt on every open (`menuNeedsUpdate`) rather than held live:
/// the model list, the update phase and the interface language all change under
/// it, and a rebuild is microseconds against a user-initiated click.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What the menu can ask the app to do. Injected by `AppDelegate` so the
    /// display-resolution logic (which screen a summoned panel lands on) stays
    /// in one place instead of being reimplemented here.
    struct Actions {
        var openNotch: () -> Void
        var newChat: () -> Void
        var openHistory: () -> Void
        var openSettings: () -> Void
        var openAbout: () -> Void
        var openModelSettings: () -> Void
        var openWhatsNew: () -> Void
        var checkForUpdates: () -> Void
    }

    private var statusItem: NSStatusItem?
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Presence

    /// Create or tear down the status item to match the persisted setting.
    /// Idempotent — safe to call at launch and on every toggle.
    func apply() {
        if MenuBarIconVisibility.current == .shown {
            install()
        } else {
            remove()
        }
    }

    func suspendForLicenseBlock() {
        // The status item is also the recovery path for an expired trial: its
        // menu presents Buy / Activate while every product surface is closed.
        apply()
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "NotchFlow"
            button.setAccessibilityLabel("NotchFlow")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func remove() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// The supplied transparent NF artwork, rendered by macOS as a compact white
    /// template glyph. The asset carries no tile or rim, so it sits alongside
    /// standard menu-bar icons without a visual plate.
    private static func statusIcon() -> NSImage {
        guard let source = NSImage(named: "NotchFlowStatusIcon"),
              let icon = source.copy() as? NSImage else {
            return NSImage(systemSymbolName: "wave.3.right", accessibilityDescription: "NotchFlow")
                ?? NSImage(size: NSSize(width: 18, height: 18))
        }
        // The supplied transparent artwork includes intentional breathing room;
        // 24pt makes its visible NF mark match neighbouring menu-bar glyphs.
        icon.size = NSSize(width: 24, height: 24)
        icon.isTemplate = true
        return icon
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard LicenseService.shared.state.allowsProductServices else {
            menu.addItem(item(L("license.buy"), #selector(openSettings)))
            menu.addItem(.separator())
            menu.addItem(item(L("menuBar.quit"), #selector(quit)))
            return
        }

        // What you came here to do.
        menu.addItem(item(L("menuBar.open"), #selector(openNotch)))
        menu.addItem(item(L("menuBar.newChat"), #selector(newChat)))
        menu.addItem(item(L("menuBar.history"), #selector(openHistory)))

        if let remaining = LicenseService.shared.state.trialDaysRemaining {
            let trial = NSMenuItem(
                title: remaining == 1
                    ? L("license.trial.remaining.one")
                    : L("license.trial.remaining", Int64(remaining)),
                action: nil,
                keyEquivalent: ""
            )
            trial.isEnabled = false
            menu.addItem(trial)
            menu.addItem(item(L("license.buy"), #selector(buyNotchFlow)))
        }

        menu.addItem(.separator())

        // The one setting worth reaching without opening Settings — Notch's
        // equivalent of a recorder's input-device picker.
        let modelItem = NSMenuItem(title: L("menuBar.model"), action: nil, keyEquivalent: "")
        modelItem.image = NSImage(
            systemSymbolName: "cpu",
            accessibilityDescription: L("menuBar.model"))
        modelItem.submenu = buildModelMenu()
        menu.addItem(modelItem)

        let settings = item(L("menuBar.settings"), #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        menu.addItem(.separator())

        // Housekeeping: which build this is, what changed, is there a newer one.
        let version = NSMenuItem(
            title: L("menuBar.version", UpdaterService.currentVersion),
            action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item(L("menuBar.whatsNew"), #selector(openWhatsNew)))
        // A pending update takes over the check row — the menu is where a user
        // who never opens Settings would find out at all.
        if case .available(let latest) = UpdaterService.shared.phase {
            menu.addItem(item(L("menuBar.update", latest), #selector(checkForUpdates)))
        } else {
            menu.addItem(item(L("menuBar.checkUpdates"), #selector(checkForUpdates)))
        }

        menu.addItem(.separator())

        menu.addItem(item(L("menuBar.about"), #selector(openAbout)))
        let quit = item(L("menuBar.quit"), #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// The recently-used models, same list the in-panel ⌘⇧I picker shows, with
    /// the serving one checked — so switching model is one click from the menu
    /// bar without any of the picker's chrome. Picking commits through
    /// `ModelCatalogStore.select`, the same path the picker uses.
    private func buildModelMenu() -> NSMenu {
        let menu = NSMenu()
        let current = APIKeyStore.selectedProvider
        let currentModel = APIKeyStore.effectiveModel(for: current) ?? current.defaultModel

        // MRU first (newest first), with the serving model pinned in front so it's
        // always present even on a fresh install that has never picked anything.
        var rows: [AskModelMRU.Entry] = []
        if ModelCatalogStore.ready(current), !currentModel.isEmpty {
            rows.append(AskModelMRU.Entry(provider: current, model: currentModel))
        }
        for entry in AskModelMRU.entries where ModelCatalogStore.ready(entry.provider) {
            if !rows.contains(entry) { rows.append(entry) }
        }

        if rows.isEmpty {
            let empty = NSMenuItem(title: L("menuBar.noModel"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, row) in rows.prefix(AskModelMRU.capacity).enumerated() {
                let name = ModelRatings.prettyName(for: row.model, provider: row.provider)
                let title = "\(name)  ·  \(row.provider.displayName)"
                let entry = NSMenuItem(title: title, action: #selector(selectModel(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.representedObject = row
                entry.state = (row.provider == current && row.model == currentModel) ? .on : .off
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(L("menuBar.modelSettings"), #selector(openModelSettings)))
        return menu
    }

    /// Menu items are built with `target = self` explicitly: a status-item menu
    /// has no responder chain to walk, so an untargeted action would simply be
    /// disabled.
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func openNotch() { actions.openNotch() }
    @objc private func newChat() { actions.newChat() }
    @objc private func openHistory() { actions.openHistory() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func openAbout() { actions.openAbout() }
    @objc private func openModelSettings() { actions.openModelSettings() }
    @objc private func openWhatsNew() { actions.openWhatsNew() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func buyNotchFlow() {
        guard let checkoutURL = LicenseService.shared.beginCheckout() else {
            actions.openAbout()
            return
        }
        NSWorkspace.shared.open(checkoutURL)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard LicenseService.shared.state.allowsProductServices else {
            actions.openSettings()
            return
        }
        guard let row = sender.representedObject as? AskModelMRU.Entry else { return }
        ModelCatalogStore.select(provider: row.provider, model: row.model)
    }
}

/// Whether the app puts an icon in the menu bar — persisted in `UserDefaults`,
/// toggled in Settings → General, consumed by `AppDelegate` via
/// `MenuBarController`. Shown by default: with no Dock icon and no app menu, it
/// is the only handle on the app that doesn't depend on remembering a shortcut
/// or on the notch being reachable. Users who want the bar clean can hide it —
/// the notch and the summon shortcut still work.
enum MenuBarIconVisibility: String, CaseIterable, Identifiable {
    case shown
    case hidden

    var id: String { rawValue }

    /// Reuses the Dock row's Shown/Hidden strings — same two words, same meaning.
    var label: String {
        switch self {
        case .shown:  return L("dock.shown")
        case .hidden: return L("dock.hidden")
        }
    }

    private static let key = "menuBarIconVisibility"
    static var current: MenuBarIconVisibility {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(MenuBarIconVisibility.init) ?? .shown
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
