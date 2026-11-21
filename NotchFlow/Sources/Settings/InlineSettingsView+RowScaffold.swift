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
    // MARK: - Row scaffold

    /// A label-on-the-left, control-on-the-right row, sized so the provider and
    /// model menus line up. Pass `info` to hang a collapsed ⓘ note right after the
    /// label — the same mark the answer footer uses for the model that replied.
    /// One label + control line.
    ///
    /// `aligned` opts the row into the pane's shared label column: it reports its
    /// natural label width up through `LabelColumnWidthKey` and takes the widest
    /// one back, so every control in the pane starts at the same x. Off by
    /// default — panes whose rows nest (`keySection`, `permissionsSection`) are
    /// left on the old self-sizing behaviour until this is proven on Appearance.
    ///
    /// The measurement and the width are deliberately on DIFFERENT views: the
    /// inner stack stays `fixedSize()` and is what gets measured, the resolved
    /// column width is applied to a wrapper around it. Reporting from the same
    /// view the frame sizes would feed the preference back into itself and
    /// oscillate.
    @ViewBuilder
    func settingRow<Content: View>(
        label: String,
        info: String? = nil,
        aligned: Bool = false,
        verticalAlignment: VerticalAlignment = .firstTextBaseline,
        forceStacked: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // Popup menus and file paths have an intrinsic width. Squeezing a long
        // label and one of those controls into a single line made their hit areas
        // overlap in narrow panes. Prefer the compact inline form, but stack the
        // control below its label as soon as it cannot genuinely fit.
        if forceStacked {
            VStack(alignment: .leading, spacing: 7) {
                settingLabel(label, info: info)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: verticalAlignment, spacing: 12) {
                    settingLabel(label, info: info, aligned: aligned)
                    content()
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 7) {
                    settingLabel(label, info: info)
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The label half of a setting line, extracted so the rows that don't use
    /// `settingRow`'s layout (the placement cards) can still sit in the column.
    func settingLabel(
        _ label: String,
        info: String? = nil,
        aligned: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .fixedSize()
            if let info {
                SettingInfo(info)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: LabelColumnWidthKey.self,
                                       value: aligned ? g.size.width : 0)
            }
        )
        // `nil` keeps the row at its own width until the first measurement.
        .frame(width: aligned && labelColumnWidth > 0 ? labelColumnWidth : nil,
               alignment: .leading)
    }
    // MARK: - Logic (mirrors the old SettingsView)

    /// Fetch the *current* provider's live model list into `ModelCatalogStore`, so the
    /// picker shows what the vendor serves right now for the provider in effect.
    /// Keyless providers keep their bundled shortlist (the picker falls back to
    /// `availableModels`). Cheap and cancel-safe — `ModelCatalog.fetch` caches per
    /// provider+key for an hour, so this doesn't re-hit the network unless the key
    /// changed or the cache actually expired.
    @MainActor
    func refreshModels() async {
        let target = provider
        // Curated manifest first (no-op when fresh): keyless providers still get
        // the hot-updated bundled shortlist through `availableModels`.
        await RemoteModelManifest.refreshIfDue()
        guard target == provider else { return }
        // The custom endpoint fetches on its URL alone — its key is optional, and
        // its `/v1/models` is where its model ids have to come from.
        let optionalKey = target == .custom && CustomProvider.chatEndpoint != nil
        guard let key = APIKeyStore.current(for: target)
                ?? (optionalKey ? "" : nil) else { return }
        loadingModels = true
        let live = await ModelCatalog.fetch(for: target, apiKey: key)
        // Stop the spinner unconditionally — an early return on the staleness
        // guard below used to strand it spinning forever after a mid-fetch
        // provider switch.
        loadingModels = false
        // Guard against a stale response after the user switched providers.
        guard target == provider else { return }
        if let live { catalog.adopt(live, for: target) }
    }
    // MARK: - Cross-provider picker

    /// Pick a model from the cross-provider picker: switch the selected provider
    /// (reusing `selectProvider`, which re-syncs every provider-scoped row), then
    /// save the chosen model under it. Selecting a model within the *current*
    /// provider skips the switch and just persists the model.
    func selectAcrossProviders(provider newProvider: Provider, model id: String) {
        pendingModel = nil   // any committed pick settles the pending ask
        if newProvider != provider {
            // `selectProvider` resets `modelID` to that provider's stored model;
            // override it with the id the user actually clicked.
            selectProvider(newProvider)
        }
        modelID = id
        APIKeyStore.saveModel(id, for: newProvider)
        // The custom endpoint's Model ID field is another view of the same stored
        // value — keep it in step when the pick came from the picker.
        if newProvider == .custom { customModel = id }
        // An explicit pick is a "recently used" model from the user's point of
        // view — record it so the Ask chip's quick menu keeps it after the
        // selection moves on (picks made here used to vanish from the menu).
        AskModelMRU.record(provider: newProvider, model: id)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    /// Probe the *stored* key of the key section's provider and surface the
    /// verdict. Test is only offered once a key is saved, so it always checks
    /// what's on disk — never an unsaved draft. Guarded via `canTest`.
    func test() {
        guard canTest else { return }
        let target = keyScope
        let key = APIKeyStore.current(for: target) ?? APIKeyStore.stored(for: target)
        testing = true
        testResult = nil
        Task {
            let result = await ConnectivityTest.run(provider: target, apiKey: key)
            await MainActor.run {
                // Drop a stale result if the user retargeted the section mid-flight.
                guard target == keyScope else { return }
                testing = false
                withAnimation(.easeOut(duration: 0.2)) { testResult = result }
            }
        }
    }

    /// Persist the key being edited for the key section's provider. When that key
    /// was blocking a picked model (the pending flow), the pick commits here —
    /// paste, save, and the model you asked for is live.
    func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingKey, !trimmed.isEmpty else { return }
        APIKeyStore.save(apiKey, for: keyScope)
        apiKey = APIKeyStore.stored(for: keyScope)
        withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
        withAnimation(.easeOut(duration: 0.18)) { saved = true }
        if let pending = pendingModel, pending.provider == keyScope {
            selectAcrossProviders(provider: pending.provider, model: pending.id)
        } else {
            NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        }
        // A newly-saved key may unlock the live model list — refresh it.
        Task { await refreshModels() }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { saved = false }
        }
    }
}
