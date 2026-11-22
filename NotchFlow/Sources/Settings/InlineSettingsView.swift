import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// Settings rendered *inside* the notch panel, in place of the recent list —
/// not a separate window. Carries the same logic as the old native `SettingsView`
/// (active provider, its API key, an optional model override, all in
/// `UserDefaults` via `APIKeyStore`) but wears the panel's Liquid Glass skin so it
/// reads as part of the island. The gear and ⌘, both swap the RECENT block for
/// this; the back chevron returns to the idle prompt.
struct InlineSettingsView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var capabilities = NotchCapabilityStore.shared
    /// The same settings controls can also live in the standalone macOS Settings
    /// window. In that case the native window provides navigation and chrome;
    /// this view supplies only the selected pane and its established behaviour.
    private let presentedInSettingsWindow: Bool
    @ObservedObject var clipboardHistory = ClipboardHistoryService.shared
    /// The Pomodoro durations the Utilities pane edits. Observed rather than
    /// mirrored: both minute counts are backed by `@Published` storage, so the
    /// rows follow a change made from the overlay's own pickers too.
    @ObservedObject var focusTimer = FocusTimerStore.shared
    /// Self-update state (shared app-wide — the gear badge reads the same object).
    /// Drives the Version row: a quiet number normally, an Update action when a
    /// newer release is known.
    @ObservedObject var updater = UpdaterService.shared
    /// Trial and perpetual-license state is shared with the launch gate. About
    /// exposes the same buy/activate/deactivate paths without duplicating state.
    @ObservedObject var license = LicenseService.shared
    /// The one-click OpenRouter OAuth flow. Observed so the Account row tracks
    /// its phases (waiting on the browser, exchanging, failed) live.
    @ObservedObject var orAuth = OpenRouterAuth.shared

    /// The provider whose model is in effect — the backend that answers. Changed
    /// only by picking a model; key management never touches it.
    @State var provider: Provider = APIKeyStore.selectedProvider
    /// The provider whose key the key section is viewing/editing. Follows
    /// `provider` while the section is closed; retargeted by the picker's
    /// "Add key" flow and by the section's own provider menu. All key-editor
    /// state below (apiKey / editingKey / saved / testResult) is scoped to this,
    /// so managing a key never hijacks the active backend.
    @State var keyScope: Provider = APIKeyStore.selectedProvider
    @State var apiKey: String = APIKeyStore.stored(for: APIKeyStore.selectedProvider)
    /// Empty string = "use the provider's default".
    @State var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.selectedProvider)
    @State var saved = false
    /// False once a key is saved: the row shows a masked, read-only summary of
    /// the stored key (so screenshots never carry the full secret) until the
    /// user explicitly hits Change. Starts true only when nothing is stored.
    @State var editingKey: Bool =
        APIKeyStore.stored(for: APIKeyStore.selectedProvider).isEmpty
            && !APIKeyStore.hasEnvOverride(for: APIKeyStore.selectedProvider)

    @State var loadingModels = false

    /// Pointer over the model row — the refresh arrow rides its hover, the way the
    /// shortcut rows' reset button does.
    @State var modelRowHovering = false

    /// A manual refresh (the arrow beside the model chip) in flight — every catalog
    /// cache bypassed at once, so this one can take a beat where the automatic
    /// refreshes never do (CLI probes spawn processes).
    @State var refreshingModels = false

    /// A model waiting on a key: set when the user taps a keyless model in the
    /// picker. The key section opens on that provider, and the moment a key
    /// lands (paste-save or OpenRouter connect) this exact model is selected and
    /// the pending state clears — the "configure only when the pick needs it"
    /// flow. Until the key exists, nothing about the active backend changes.
    struct PendingModel { let provider: Provider; let id: String }
    @State var pendingModel: PendingModel?
    /// Whether the "Provider & API key" section is expanded by hand. A required
    /// setup (keyless active provider, or a pending model) forces it open
    /// regardless — see `keySection`.
    @State var keySectionOpen = false
    /// Whether the custom-instructions field is unfolded. Collapsed at rest like
    /// the key section above it — it opens by itself only when there is already an
    /// instruction stored, so an existing preference is never hidden.
    @State var instructionsSectionOpen = false

    /// The model catalog behind the picker — live lists, the fold, and which providers
    /// are callable. Session-wide (the panel's ⌘⇧I picker reads the same store), so a
    /// list fetched for one surface is already warm for the other.
    @ObservedObject var catalog = ModelCatalogStore.shared

    /// Whether the custom cross-provider model picker overlay is open.
    @State var modelPickerOpen = false

    /// Connectivity-test state. `testing` drives the spinner; `testResult` is the
    /// last verdict shown under the key field (nil = nothing tested yet).
    @State var testing = false
    @State var testResult: ConnectivityTest.Result?

    /// True while an env var forces a key for the key section's provider — then
    /// the field is informational only, since the env override wins over typing.
    var envOverride: Bool { APIKeyStore.hasEnvOverride(for: keyScope) }

    /// Exa search key state — a separate, provider-agnostic key (Exa is a search
    /// backend, not an LLM provider). When set, it replaces every model's built-in
    /// web search. Mirrors the provider key's edit/mask/saved lifecycle, minus the
    /// Test button and live-model coupling (there's nothing to test a search key
    /// against here, and it doesn't gate a model list).
    @State var exaKey: String = APIKeyStore.storedExaKey()
    @State var editingExaKey: Bool =
        APIKeyStore.storedExaKey().isEmpty && !APIKeyStore.hasExaEnvOverride()
    @State var exaSaved = false
    /// True while `EXA_API_KEY` forces the Exa key — field is then informational.
    var exaEnvOverride: Bool { APIKeyStore.hasExaEnvOverride() }

    /// The user's chosen search backend. Pick one and that's what runs, like the
    /// model picker. `nil` is the provider's own web search, offered in the menu
    /// as "Model's own search".
    @State var searchBackend: APIKeyStore.SearchBackend? = APIKeyStore.preferredSearchBackend

    /// Keenable search key state — a standalone search backend, keyed (its HTTP API
    /// requires a key). Same edit/mask/saved lifecycle as the Exa row.
    @State var keenableKey: String = APIKeyStore.storedKeenableKey()
    @State var editingKeenableKey: Bool =
        APIKeyStore.storedKeenableKey().isEmpty && !APIKeyStore.hasKeenableEnvOverride()
    @State var keenableSaved = false
    /// True while `KEENABLE_API_KEY` forces the key — field is then informational.
    var keenableEnvOverride: Bool { APIKeyStore.hasKeenableEnvOverride() }

    var canSaveKeenable: Bool {
        guard !keenableEnvOverride else { return false }
        return editingKeenableKey
            && keenableKey != APIKeyStore.storedKeenableKey()
    }

    /// The stored Keenable key rendered safe for display (same masking as Exa).
    var maskedKeenableKey: String {
        let key = APIKeyStore.currentKeenableKey() ?? APIKeyStore.storedKeenableKey()
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// AnySearch can run anonymously; its optional key only raises quota and
    /// concurrency limits. Start in the summary state even when no key exists so
    /// the row clearly says that anonymous access is already active.
    @State var anySearchKey: String = APIKeyStore.storedAnySearchKey()
    @State var editingAnySearchKey = false
    @State var anySearchSaved = false
    var anySearchEnvOverride: Bool { APIKeyStore.hasAnySearchEnvOverride() }

    var canSaveAnySearch: Bool {
        guard !anySearchEnvOverride else { return false }
        return editingAnySearchKey
            && anySearchKey != APIKeyStore.storedAnySearchKey()
    }

    var maskedAnySearchKey: String {
        guard let key = APIKeyStore.currentAnySearchKey(), !key.isEmpty else {
            return L("model.anysearchAnonymous")
        }
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    var canSaveExa: Bool {
        guard !exaEnvOverride else { return false }
        return editingExaKey
            && exaKey != APIKeyStore.storedExaKey()
    }

    /// The stored Exa key rendered safe for display (same head/tail masking as the
    /// provider key).
    var maskedExaKey: String {
        let key = APIKeyStore.currentExaKey() ?? APIKeyStore.storedExaKey()
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// OpenRouter normally connects via the one-click OAuth row; this flips to the
    /// standard paste field for users who'd rather supply a key by hand.
    @State var manualKeyEntry = false

    /// The custom endpoint's three fields (see `CustomProvider`), edited together
    /// and committed by one Save — unlike a key, an endpoint that's half-typed is
    /// worse than the old one, so nothing is persisted keystroke by keystroke.
    @State var customName: String = CustomProvider.name
    @State var customURL: String = CustomProvider.baseURL
    @State var customModel: String = CustomProvider.model
    @State var customSaved = false

    /// Whether any of the three differs from what's stored — the only state where
    /// the custom Save button lights up.
    var canSaveCustom: Bool {
        customName.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.name
            || customURL.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.baseURL
            || customModel.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.model
    }

    var canSave: Bool {
        guard !envOverride else { return false }
        // Only the API key needs an explicit Save — a model switch auto-persists,
        // so it never lights up this button.
        return editingKey
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey != APIKeyStore.stored(for: keyScope)
    }

    /// The stored key rendered safe for display: enough of the head and tail to
    /// recognize which key it is, bullets for everything in between. Short keys
    /// mask entirely rather than leak most of their characters.
    var maskedKey: String {
        let key = APIKeyStore.current(for: keyScope) ?? APIKeyStore.stored(for: keyScope)
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// The left-hand category list — the point of the column is that the next
    /// setting gets a home without redesigning the panel.
    enum Section: String, CaseIterable, Identifiable {
        case chat = "Chat"       // inherited Notchi assistant, capture, and search settings
        case agent = "Agent"     // task and prompt shortcuts
        case media = "Media"     // system now-playing behaviour
        case utilities = "Utilities" // clipboard and utility services
        case appearance = "Appearance" // global notch style and display placement
        case global = "Global"   // app presence, permissions, language, and network
        case stats = "Stats"     // what the archive adds up to — read-only
        case about = "About"     // version + self-update
        case licenses = "Licenses" // third-party attribution and licences
        var id: String { rawValue }

        /// A sub-page rather than a category: reached from About, drawn across
        /// the whole panel, and left through the header's back pill or Esc.
        var isDetail: Bool { self == .licenses }

        /// The section a sub-page sits under — where back (and ⎋) returns to.
        /// `nil` for the top-level categories, whose back leaves settings.
        var parent: Section? { isDetail ? .about : nil }

        /// The sidebar's rows: every category, minus the sub-pages — in
        /// declaration order, which is the grouping. The column is 104pt wide and
        /// carries no device to draw a group with: a rule through it is heavy, and
        /// an inserted gap reads as a layout slip rather than a boundary. So the
        /// bands live in the ORDER and nowhere else — what answers and what it
        /// takes in, then how the app presents and behaves, then the two pages
        /// that only report.
        static var sidebarCases: [Section] { allCases.filter { !$0.isDetail } }

        /// The sidebar label, localized. The raw value stays English (a stable
        /// identity); this is what the user actually reads.
        var title: String {
            switch self {
            case .chat:       return "Chat"
            case .agent:      return "Agent"
            case .media:      return "Media"
            case .utilities:  return "Utilities"
            case .appearance: return L("sidebar.appearance")
            case .global:     return "Global"
            case .stats:      return L("sidebar.stats")
            case .about:      return L("sidebar.about")
            case .licenses:   return L("about.licenses")
            }
        }
    }
    /// The open category, backed by `model.settingsSection` rather than local
    /// `@State`, so it persists while the panel is open.
    var section: Section {
        get {
            switch model.settingsSection {
            case "Model", "Capture": return .chat
            case "Shortcuts": return .agent
            case "General": return .global
            default: return Section(rawValue: model.settingsSection) ?? .chat
            }
        }
        nonmutating set { model.settingsSection = newValue.rawValue }
    }

    /// Re-reads every value this view mirrors from its store. Key editing is
    /// left alone while the key section is open, so a change elsewhere never
    /// swaps the key someone is typing for another provider's.
    func resyncMirrors() {
        if pendingModel == nil {
            provider = APIKeyStore.selectedProvider
            modelID = APIKeyStore.storedModel(for: provider)
        }
        if !keySectionOpen, keyScope != provider {
            keyScope = provider
            apiKey = APIKeyStore.stored(for: provider)
            editingKey = apiKey.isEmpty
        }
        placement = .current
        dockIconVisibility = .current
        menuBarIconVisibility = .current
        launchAtLogin = LaunchAtLogin.isEnabled
        noteDestination = .current
        notesFolderDisplay = FileNotesService.folderDisplayPath
    }

    /// Which screens carry an island — mirrors the persisted value; writes go
    /// through `selectPlacement` so `AppDelegate` rebuilds panels immediately.
    @State var placement: DisplayPlacement = .current

    /// Whether the app shows a Dock icon — mirrors the persisted value; writes go
    /// through `selectDockIconVisibility` so `AppDelegate` flips the activation
    /// policy immediately.
    @State var dockIconVisibility: DockIconVisibility = .current

    /// The artwork shown when NotchFlow has a Dock / app-switcher presence. The
    /// original icon remains the persisted fallback; changing cards applies the
    /// running app image immediately.
    @State var appIconStyle: AppIconStyle = .current
    /// Forces the Dot preview to resolve its other asset when macOS switches
    /// between light and dark while Settings is open.
    @State var appIconAppearanceRevision = 0

    /// Whether the app shows a menu bar icon — mirrors the persisted value; writes
    /// go through `selectMenuBarIconVisibility` so `AppDelegate` adds or removes
    /// the status item immediately.
    @State var menuBarIconVisibility: MenuBarIconVisibility = .current

    /// Whether the app launches itself at login — seeded from the live system
    /// login-item status (`SMAppService`), not `UserDefaults`. Writes go through
    /// `selectLaunchAtLogin`, which registers/unregisters the item and reverts
    /// this optimistic flag if the OS refuses.
    @State var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    /// How eagerly the resting notch opens under the pointer — mirrors the
    /// persisted value; writes go through `selectHoverSensitivity`. Read live by
    /// `NotchModel.hoverEntered`, so a change applies to the very next hover.
    @State var hoverSensitivity: HoverSensitivity = .current
    /// Where the hover slider's ticks actually sit (normalized 0…1), so its
    /// labels line up under the marks rather than under an equal-width guess.
    @State var hoverTickCenters: [CGFloat]?
    /// Where the pressure slider's ticks actually sit; see `hoverTickCenters`.
    @State var pressureTickCenters: [CGFloat]?

    /// Where note captures land (Apple Notes / Markdown folder) — mirrors the
    /// persisted value; writes go through `selectNoteDestination`. Consulted per
    /// write, so the switch applies to the very next jot.
    @State var noteDestination: NoteDestination = .current
    /// The Markdown folder as shown under the destination row (home-relative);
    /// refreshed when the chooser commits a new pick.
    @State var notesFolderDisplay: String = FileNotesService.folderDisplayPath

    /// All editable shortcuts live together in the Shortcuts category. The
    /// summon chord re-registers globally; product actions are read live by the
    /// panel key catcher.
    @State var summonHotKey: SummonHotKey = .current
    @State var appShortcuts: [AppShortcutAction: ShortcutChord] = AppShortcutStore.current
    /// User-authored global bindings are intentionally only a shortcut and one
    /// prompt. Their UUID exists solely so SwiftUI and AppDelegate can track rows.
    @State var promptShortcuts: [PromptShortcut] = PromptShortcutStore.current
    /// The shortcut whose independent editor popover is open. The list itself
    /// never expands or changes height; one id also guarantees only one editor is
    /// presented at a time.
    @State var presentedPromptShortcutID: UUID?
    /// Prompt rows stay visually still; hover reveals only the explicit Edit
    /// action in the reserved trailing slot.
    @State var hoveredPromptShortcutID: UUID?
    @State var hoveredShortcutRow: EditableShortcut?
    /// At most one row records at a time. Hints belong to their row so a conflict
    /// stays visually attached to the shortcut that needs attention.
    @State var recordingShortcut: EditableShortcut?
    @State var shortcutHints: [EditableShortcut: String] = [:]

    /// The open pane's shared label column width (see `LabelColumnWidthKey`).
    /// Zero means "not measured yet" — rows fall back to their own width for the
    /// one frame before the measurement lands. Reset on every pane switch: each
    /// category has its own set of labels, and General's longest must not stretch
    /// Appearance's column.
    @State var labelColumnWidth: CGFloat = 0

    /// Whether the General pane's folded Advanced block is open.
    @State var advancedSectionOpen = false
    /// Permissions are diagnostic/recovery controls rather than everyday
    /// preferences, so they stay folded until the user needs them.
    @State var permissionsSectionOpen = false

    /// Which disclosure chip owns the pointer. Permissions and Advanced can share
    /// one pane, so a single Bool would brighten both at once.
    enum DisclosureHover { case keys, instructions, permissions, advanced }
    @State var hoveredDisclosure: DisclosureHover?

    /// What the proxy field resolves to right now — filled in asynchronously by
    /// `refreshProxyStatus` because detection may spawn a login shell.
    @State var proxyStatus: String = ""

    /// Live macOS authorization state for the three protected capabilities the
    /// app actually uses. These are refreshed whenever General appears and when
    /// NotchFlow becomes active again, so a change made in System Settings is
    /// reflected without relaunching.
    @State var remindersPermission: SettingsPermissionStatus = .checking
    @State var notesPermission: SettingsPermissionStatus = .checking
    @State var notificationsPermission: SettingsPermissionStatus = .checking
    /// Accessibility is the odd one out: macOS exposes it as a plain bool, with
    /// no "not determined" versus "denied" distinction, and it is the only
    /// permission the app never asks for on its own (see
    /// `AlertBannerWatcher` — nothing may conjure a TCC dialog unprompted). That
    /// makes this row the ONLY way a user can discover why the resting notch's
    /// call and notification ears are silent, so it is not optional polish.
    @State var accessibilityPermission: SettingsPermissionStatus = .checking
    /// Location backs one thing only: the temperature under the clock in
    /// Utilities. Listed here so it is visible and revocable, and so the weather
    /// line has somewhere to send a user who wants it and hasn't been asked yet.
    @State var locationPermission: SettingsPermissionStatus = .checking

    /// The Utilities and Media panes' stored knobs, mirrored into view state for
    /// the same reason as the Agent pane's below: they live on value types in
    /// `Capabilities`, which nothing there may make observable.
    @State var mediaInClosedNotch: Bool = MediaPresentationPolicy.showsInClosedNotch
    @State var temperatureUnit: WeatherUnitPreference = WeatherUnitPreference.current
    @State var quickActionsHidden: Set<String> = QuickUtilityStrip.hidden
    /// The clipboard limit is a plain stored property on the service (not
    /// `@Published`), so the menu title reads this mirror rather than the service.
    @State var clipboardLimit: Int = ClipboardHistoryService.shared.limit

    /// The Agent pane's four stored knobs, mirrored into view state. They live on
    /// value types in `Capabilities` (nothing there may depend on SwiftUI), so
    /// there is no publisher to observe — the mirror is what redraws the row, and
    /// each setter writes both.
    @State var permissionDelay: TimeInterval = AgentPermissionPolicy.delay
    @State var stalledAfter: TimeInterval = AgentSessionTerminal.stalledAfter
    @State var sessionWindow: TimeInterval = AgentSessionObservation.activeFileWindow
    @State var showsSubagents: Bool = AgentDisplayPolicy.showsSubagents

    /// The day the Stats grid's pointer is on. Lives here, not in the pane,
    /// because the readout naming it is drawn in the panel header — the pane's
    /// own corners are all spoken for.
    @State var statsHover: StatsHoverDay?

    /// What Settings → Stats draws. `nil` until the first fold over the archive
    /// lands (see `refreshStats`); recomputed whenever the archive grows.
    @State var stats: StatsDigest?
    /// The token odometer's reading, refreshed alongside the digest.
    @State var statsTokens = TokenMeter.Reading(total: 0)

    init(model: NotchModel, presentedInSettingsWindow: Bool = false) {
        _model = ObservedObject(wrappedValue: model)
        self.presentedInSettingsWindow = presentedInSettingsWindow
    }

    var body: some View {
        Group {
            if presentedInSettingsWindow {
                // Keep every mature setting and its interaction intact while the
                // desktop window supplies the native sidebar and title bar.
                VStack(alignment: .leading, spacing: 0) {
                    windowHeader
                    paneContent
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // The Force Click pressure slider lives here, so the Look Up
                // conflict it can raise has to be answered here too; on the
                // island alone the slider just snapped back with no word why.
                .modifier(ForceClickLookupGate(model: model, isOpen: true))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if section.isDetail {
                // A pushed sub-page (the Shortcuts reference under About): the
                // category column steps aside and the page takes the whole panel,
                // so it reads as one level deeper rather than another tab. The
                // header's back pill — now carrying this page's name — walks out.
                // No `.fixedSize(vertical:)` needed here: alone in the column, the
                // pane's own exact height (content, capped at Recent's) is the
                // whole page height.
                        paneContent
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                    // The sidebar drops by the pane's runway too, so the first
                    // category stays level with the pane's first row — the runway
                    // moves BOTH columns down, it doesn't stagger them.
                            sidebar
                                .padding(.top, Self.paneTopRunway)

                            paneContent
                                .padding(.leading, 14)
                        }
                // Take the columns' own height, nothing more: the pane already
                // carries an exact height (content, capped at Recent's), so this
                // no longer unfolds the scroll — it only stops the scroll behind
                // it from stretching the island.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                    }
                }
            }
        }
        .overlay {
            if let id = presentedPromptShortcutID,
               let shortcut = promptShortcuts.first(where: { $0.id == id }) {
                ConfirmationDialogOverlay(
                    onDismiss: { closePromptShortcutEditor(id) }
                ) {
                    promptShortcutCard(shortcut)
                        .frame(width: 372)
                }
                // Settings is inset inside `NotchBody`; without reclaiming that
                // inset, the scrim stops at the settings content and leaves the
                // glass body's side and bottom gutters uncovered.
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: presentedPromptShortcutID)
        // The Force Click gate is NOT mounted here: its scrim has to cover the
        // whole glass panel, and the settings body stops short of the island's
        // edges (the body's own padding showed as uncovered strips down the sides
        // and along the bottom). It hangs off the island itself in `ContentView`,
        // next to the Clear confirmation, on `model.forceClickLookupConflict`.
        .task {
            // A keyless model picked in the ⌘⇧I picker sent us here: adopt the pick,
            // aim the key section at its provider, and unfold it — from here it's the
            // same pending flow the settings picker's own "Add key" runs (the model
            // commits the moment a key lands, and nothing changes before that).
            if let pending = model.pendingModelSetup {
                model.pendingModelSetup = nil
                section = .chat
                pendingModel = PendingModel(provider: pending.provider, id: pending.id)
                setKeyScope(pending.provider)
                keySectionOpen = true
            }
            // Un-throttled freshness check while the user is actually looking at
            // the Version row (one tiny request; failures stay silent).
            updater.check()
            // The model chip may be naming a Claude Code alias — resolve it to the
            // concrete model ("opus" → "Opus 5") without waiting for the picker to
            // be opened. Self-gating and cache-backed; usually a no-op.
            catalog.resolveClaudeAliases()
            await refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appIconAppearanceChanged)) { _ in
            appIconAppearanceRevision &+= 1
        }
        // The values below are copied into view state when the pane opens. The
        // menu bar's model picker and chat ("turn off live activity") can change
        // them while Settings stays open, so re-read them whenever one of those
        // announces a change, and whenever the window comes back to the front.
        .onReceive(NotificationCenter.default.publisher(for: .aiBackendChanged)) { _ in resyncMirrors() }
        .onReceive(NotificationCenter.default.publisher(for: .displayPlacementChanged)) { _ in resyncMirrors() }
        .onReceive(NotificationCenter.default.publisher(for: .dockIconVisibilityChanged)) { _ in resyncMirrors() }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarIconVisibilityChanged)) { _ in resyncMirrors() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if presentedInSettingsWindow { resyncMirrors() }
        }
        // Turning agentic mode off from the Global row retires Chat, Agent, and
        // Stats (see `sidebarSections`). Without this, a user who was reading one
        // of those and then flipped the toggle stayed on a pane with no sidebar
        // row left to point at it.
        .onChange(of: capabilities.agenticModeEnabled) {
            guard !sidebarSections.contains(section), !section.isDetail else { return }
            withAnimation(.easeOut(duration: 0.16)) { section = .media }
        }
        .onChange(of: orAuth.phase) {
            // The OAuth flow just wrote a key from outside this view — sync the
            // cached state, prove the key live (green pill), and load the free
            // model list it unlocks.
            guard orAuth.phase == .connected, keyScope == .openrouter else { return }
            apiKey = APIKeyStore.stored(for: .openrouter)
            editingKey = false
            manualKeyEntry = false
            orAuth.acknowledge()
            // A connect that was blocking a picked model commits that pick now.
            if let pending = pendingModel, pending.provider == .openrouter {
                selectAcrossProviders(provider: .openrouter, model: pending.id)
            } else if provider == .openrouter {
                modelID = APIKeyStore.storedModel(for: .openrouter)
            }
            test()
            Task { await refreshModels() }
        }
    }

    /// The settings body's height — FIXED, one number for every pane. It's sized
    /// so the island is exactly as tall in Settings as it is on Recent: the
    /// immersive recent layout's prompt FLOATS over its scroll surface, so that
    /// whole view is its 320pt list, while Settings stacks a back-pill header
    /// (12 + 26 + 4) and a 12pt gap above its pane, and that chrome comes out of
    /// the same budget. Short panes leave air at the bottom; long ones scroll. It
    /// used to track each pane's measured content height, which meant the island
    /// resized on every category switch (and re-measured on every layout pass) —
    /// a fixed frame is both steadier to look at and cheaper to draw.
    private static let headerChrome: CGFloat = 12 + 26 + 4 + 12
    /// The in-notch pane's fixed height. `nil` in the desktop window, where the
    /// pane takes whatever height the window has: a hard number there capped the
    /// scroll view well short of the window's bottom, so the last rows of a long
    /// category (Chat's Capture group, Agent's shortcut reference) sat below the
    /// clip with dead space under them and no way to scroll to them.
    private var settingsPaneHeight: CGFloat? {
        presentedInSettingsWindow ? nil : NotchBody.immersiveListHeight - Self.headerChrome
    }

    /// Carries the open pane's measured content height out of the scroll view.
    private struct PaneContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// The widest label in the open pane, so every control in it can start at the
    /// same x. Rows used to size their label to its own text (`minWidth: 64` and
    /// `fixedSize`), which left one pane with as many control origins as it had
    /// rows — the ragged right half is what read as clutter. A fixed pixel column
    /// can't do this job: French and Spanish labels are visibly longer than the
    /// English ones, so the number would either clip or waste half the pane.
    /// Carries the scroll viewport's height out of the pane. Separate from
    /// `PaneContentHeightKey` because one is the document and the other the clip;
    /// the taper gating needs both (see `paneOverflows`).
    private struct PaneViewportHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    struct LabelColumnWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Scroll anchor for the key section — the one pane area whose unfold can
    /// push its own fields past the pane's height cap.
    static let keySectionAnchor = "settings.keySection"

    /// The empty inset above the pane's first row, and the length of the top
    /// taper that dissolves into it. The taper is the longer of the two: a 12pt
    /// fade that stopped at the runway's edge read as a hard cut, so it now
    /// starts well above the first row and reaches down past it — matched to the
    /// bottom's 32pt so both edges of the pane dissolve at the same rate. It only
    /// ever draws while the pane is scrolled (`paneScrolledOffTop`), so at rest
    /// the first row is still fully solid.
    private static let paneTopRunway: CGFloat = 14
    private static let paneTopFade: CGFloat = 34
    /// The matching empty inset below the pane's last row, so the bottom taper has
    /// something to dissolve into. Named because `paneOverflows` has to count it.
    private static let paneBottomRunway: CGFloat = 20

    /// Whether the open pane is scrolled off its top — all the top taper needs to
    /// know. A Bool, not the live offset: driving the gradient's LENGTH from the
    /// offset rebuilt the pane's mask on every scroll tick, which is what made
    /// scrolling crawl. This flips once.
    @State private var paneScrolledOffTop = false

    /// The open pane's measured row height, and the height of the scroll viewport
    /// showing it. Both are needed because the viewport is no longer a constant:
    /// in the desktop window it is whatever the window gives us.
    @State private var paneContentHeight: CGFloat = 0
    @State private var paneViewportHeight: CGFloat = 0

    /// Whether the open pane's rows are taller than the room under the runway.
    /// `true` until the viewport has been measured, so a pane that does overflow
    /// never shows an un-tapered first frame.
    private var paneOverflows: Bool {
        guard paneViewportHeight > 0 else { return true }
        // Both runways are empty by definition, so a pane whose only scrollable
        // slack is that padding has nothing for a taper to dissolve — only the
        // rows count. The top runway is still charged against the viewport
        // because it does occupy room the rows can't use.
        return paneContentHeight + Self.paneTopRunway > paneViewportHeight + 0.5
    }

    /// The open section's pane. Lives apart from `body` because it is drawn in
    /// two different frames — in the right-hand column beside the sidebar for a
    /// category, or across the whole panel for a pushed sub-page — and the switch
    /// itself should not have to know which.
    ///
    /// Every category scrolls inside ONE shared frame (see
    /// `settingsPaneHeight`) instead of stretching the island taller: the
    /// Shortcuts reference used to be the only pane with its own fixed-height
    /// scroll; now the whole settings body rides the same ceiling and the same
    /// edge tapers.
    @ViewBuilder
    private var paneContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
            case .chat:
                // Two steps, in the order you make them: pick the backend,
                // then pick one of *its* models. The API key stays supporting
                // cast — folded into `keySection`, which only unfolds when the
                // choice actually needs a key (or the user opens it by hand).
                // Both groups carry a caption: leaving the first one bare (the
                // sidebar does name it) read as a caption that had gone missing.
                Text(L("sidebar.model"))
                    .captionLabel()
                providerRow
                modelRow
                keySection
                customInstructionsRow
                // Web search used to be a category of its own — a whole sidebar
                // entry for two rows. It is the same question this pane already
                // answers (which backend, and its key), so it rides here as a
                // labelled group instead.
                Text(L("sidebar.search"))
                    .captionLabel()
                    .padding(.top, 2)
                searchBackendRow
                // Only the picked backend's key row shows — like the model
                // choice above, one pick, one field to fill. The provider's own
                // search needs none.
                switch searchBackend {
                case nil:        EmptyView()
                case .keenable?: keenableKeyRow
                case .exa?:      exaKeyRow
                case .anysearch?: anySearchKeyRow
                }
                Text("Capture")
                    .captionLabel()
                    .padding(.top, 2)
                copySenseRow
                selectionContextRow
                noteDestinationRow
            case .agent:
                agentSettingsSection
                Text("Keyboard")
                    .captionLabel()
                    .padding(.top, 2)
                shortcutsSection
            case .media:
                mediaSettingsSection
            case .utilities:
                utilitiesSettingsSection
            case .global:
                agenticModeRow
                Text(L("general.appPresence"))
                    .captionLabel()
                    .padding(.top, 2)
                launchAtLoginRow
                dockIconRow
                menuBarIconRow
                permissionsSection
                advancedSection
            case .appearance:
                // Three small, literal groups: visual style, how the notch reacts,
                // and which displays carry it. App-level presence in macOS (launch,
                // Dock, menu bar) lives together in General instead of diluting this
                // page with a second meaning of "show".
                if AppIconStyleFeature.isEnabled || HandwritingFeature.isEnabled {
                    Text(L("appearance.style"))
                        .captionLabel()
                    if AppIconStyleFeature.isEnabled {
                        appIconStyleRow
                    }
                    if HandwritingFeature.isEnabled {
                        handwrittenAnswersRow
                    }
                }
                Text(L("appearance.behavior"))
                    .captionLabel()
                    .padding(.top, 2)
                hoverSensitivityRow
                if ForceClickFeature.isEnabled {
                    forceClickPressureRow
                }
                liveActivityRow
                Text(L("appearance.displays"))
                    .captionLabel()
                    .padding(.top, 2)
                placementRow
            case .stats:
                statsSection
            case .about:
                aboutSection
            case .licenses:
                licensesSection
            }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // How tall this pane's rows actually are, measured before the runway
            // and the bottom inset are added — the number the bottom taper is
            // gated on (see `paneOverflows`).
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PaneContentHeightKey.self,
                                           value: g.size.height)
                }
            )
            // A top RUNWAY — the whole right-hand pane rests a little lower than the
            // sidebar's first item, and this inset is what the top taper dissolves
            // into: a small scroll eats empty space before a row reaches the
            // steep part of the taper (see `paneTopFade`), so rows stay readable
            // on a stray trackpad nudge instead of the pane's top looking
            // covered. The bottom keeps its own runway — that edge tapers at all
            // times.
            .padding(.top, Self.paneTopRunway)
            .padding(.bottom, Self.paneBottomRunway)
            // Zero-size probe on the scroll CONTENT: it reads the real clip view's
            // offset. Only the crossing matters, so state changes at most once per
            // scroll gesture rather than on every tick.
            .onScrollOffsetChange { offset in
                let off = offset > 0.5
                if off != paneScrolledOffTop { paneScrolledOffTop = off }
            }
            }
            .onPreferenceChange(PaneContentHeightKey.self) { height in
                if abs(height - paneContentHeight) > 0.5 { paneContentHeight = height }
            }
            .onPreferenceChange(PaneViewportHeightKey.self) { height in
                if abs(height - paneViewportHeight) > 0.5 { paneViewportHeight = height }
            }
            .onPreferenceChange(LabelColumnWidthKey.self) { width in
                if abs(width - labelColumnWidth) > 0.5 { labelColumnWidth = width }
            }
            .scrollIndicators(.never)
            // In the notch: one fixed height for every pane (see
            // `settingsPaneHeight`) — the island never resizes between categories,
            // and a greedy ScrollView never gets to claim the whole panel. In the
            // desktop window the opposite is wanted: fill it, so the scroll's clip
            // reaches the window's bottom edge and the last row is reachable.
            .frame(height: settingsPaneHeight)
            .frame(maxHeight: presentedInSettingsWindow ? .infinity : nil)
            // How tall the visible pane actually is — the number `paneOverflows`
            // compares the rows against. Read on the scroll container, not its
            // content, so it reports the clip rather than the document.
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PaneViewportHeightKey.self,
                                           value: g.size.height)
                }
            )
            // Key the scroll container by the open section: each category gets
            // its OWN scroll state, so leaving Model scrolled halfway doesn't
            // carry that offset into General (and vice versa) — a fresh scroll
            // always starts at the top of its own content.
            .id(section)
            // A required setup unfolds the key section past the pane's height
            // cap — snap the scroller to it so what just appeared is in view
            // (the anchor lives on `keySection`). The first frame of the unfold
            // lands silently: the animation here would otherwise double the
            // section's own `.easeOut` and stall the open.
            .onChange(of: setupRequired) { _, required in
                guard required, section == .chat else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.keySectionAnchor, anchor: .top) }
            }
            // The top taper exists only once the pane is actually scrolled: a
            // permanent one dimmed the first row of every pane before the user had
            // scrolled anything, and the fade is there to dissolve rows leaving
            // past the back pill — nothing is leaving while the pane sits at top.
            // It starts above the first row and runs long (see `paneTopFade`) so
            // rows thin out gradually on the way past the back pill instead of
            // snapping off at the runway's edge.
            // The bottom taper is gated on the pane actually overflowing — which
            // is what `scrollEdgeFade` documents and what every other scrolling
            // region in the app does. Unconditional, it dimmed the last 32pt of
            // panes that fit perfectly well: About's colophon, and Stats' bottom
            // card, both washed out with nothing below them to dissolve into.
            .scrollEdgeFade(top: paneScrolledOffTop, bottom: paneOverflows,
                            topFade: Self.paneTopFade, bottomFade: 32)
            // A pane swap starts at the top again; the observer only reports on
            // the next bounds change, so clear the flag here.
            .onChange(of: section) {
                paneScrolledOffTop = false
                statsHover = nil
                // The new pane measures its own longest label; keeping the old
                // pane's number would indent the first frame by a width no row
                // here asked for.
                labelColumnWidth = 0
            }
        }
    }

    // MARK: - pi sign-in status

    /// The primary action of the whole onboarding: one click, sign in (or sign
    /// up, free) in the browser, and the key arrives by itself. Slightly brighter
    /// than the surrounding chips because it IS the setup.
    @State var connectHovering = false

    /// The About pane: who the app is before the version mechanics. An identity
    /// block (name, tagline, one-line description) sits above the Version row so
    /// the panel reads as more than a build number, then a quiet links row hands
    /// off to the source and release pages.
}
