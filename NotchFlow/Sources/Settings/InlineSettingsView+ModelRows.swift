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
    /// Step one: **which backend answers.** A plain menu of every provider, split
    /// into the ones that can answer right now and the ones that still need a key —
    /// so the useful half is never buried among a dozen unconfigured vendors.
    ///
    /// Picking an unconfigured provider is a legitimate move (it's how you get to a
    /// new vendor's key field): the switch goes through, and `keySection` unfolds
    /// itself on the spot because `setupRequired` now holds.
    var providerRow: some View {
        settingRow(label: L("model.provider")) {
            GlassMenu(title: provider.displayName) {
                let ready = Provider.offered.filter(providerReady)
                let unready = Provider.offered.filter { !providerReady($0) }
                if !ready.isEmpty {
                    SwiftUI.Section(L("model.picker.configured")) {
                        ForEach(ready) { p in
                            Button { selectProvider(p) } label: {
                                menuOption(p.displayName, selected: p == provider)
                            }
                        }
                    }
                }
                if !unready.isEmpty {
                    SwiftUI.Section(L("model.picker.unconfigured")) {
                        ForEach(unready) { p in
                            Button { selectProvider(p) } label: {
                                menuOption(p.displayName, selected: p == provider)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Step two: **which of that provider's models.** The picker card is the same
    /// one the ⌘⇧I summon opens, locked to the chosen provider — its search and its
    /// fold both work over that provider's catalog alone.
    var modelRow: some View {
        settingRow(label: L("model.label")) {
            HStack(spacing: 6) {
                // The chip anchors the model picker as a native popover.
                // A popover opens in its own window outside the island's tracking
                // area, so `model.isModelPickerOpen` suspends the panel's
                // leave-collapse for as long as it's up (see NotchModel).
                Button {
                    modelPickerOpen = true
                } label: {
                    HStack(spacing: 7) {
                        // The model wears its vendor mark and reads by name — the
                        // chip is about the model, not the plumbing behind it.
                        VendorLogo(vendor: ModelRatings.vendor(for: effectiveModelID,
                                                              provider: provider),
                                   fallback: effectiveModelID)
                            .frame(width: 15, height: 15)
                        // Claude Code's ids are rolling aliases — the chip names the
                        // concrete model behind one ("Opus 5"), not the family word.
                        Text(ModelRatings.prettyName(for: effectiveModelID,
                                                     provider: provider))
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.sf(10, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 9)
                    .frame(height: 30)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                // The system's own menu, dropped from the chip — the provider is
                // settled one row up, so it lists that provider's models flat.
                .modelMenu(isPresented: $modelPickerOpen,
                           models: catalog.rows(selected: provider),
                           selectedProvider: provider,
                           selectedID: effectiveModelID,
                           lockedProvider: provider,
                           onSelect: { prov, id in
                               selectAcrossProviders(provider: prov, model: id)
                           },
                           onConfigure: { m in
                               // "Add key" on a keyless model: remember the pick, open
                               // the key section on that provider, and select the
                               // model the moment its key lands. The active backend
                               // stays untouched until then.
                               pendingModel = PendingModel(provider: m.provider, id: m.info.id)
                               setKeyScope(m.provider)
                               withAnimation(.easeOut(duration: 0.16)) { keySectionOpen = true }
                           })
                .onChange(of: modelPickerOpen) {
                    // Fill the list with each keyed provider's live models when the
                    // menu opens (the bundled list shows now; the refresh lands for
                    // the next open).
                    if modelPickerOpen { Task { await catalog.loadAll() } }
                    // Suspend the panel's leave-collapse while the menu is up so
                    // moving the pointer into it (a separate window) never folds the
                    // settings out from under it.
                    model.isModelPickerOpen = modelPickerOpen
                }
                // Manual refresh: the automatic paths are all cached (the curated
                // manifest for 6h, a vendor's `/v1/models` for an hour, the CLI
                // catalogs for the whole launch), which is right until a model ships
                // mid-session and the list you're looking at is the stale one. One
                // tap re-asks every backend. Doubles as the load indicator — the
                // spinner it replaces was this same slot.
                Button {
                    Task { await manualRefreshModels() }
                } label: {
                    ZStack {
                        if modelsBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.sf(11, weight: .semibold))
                                .foregroundStyle(Tokens.text3)
                        }
                    }
                    // Square frame so the chip style's capsule resolves to a true
                    // circle rather than a vertical oval.
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .disabled(modelsBusy)
                .help(L("model.refresh"))
                .opacity(refreshVisible ? 1 : 0)
                .allowsHitTesting(refreshVisible)
            }
        }
        // Fine print: the arrow shows on the row it belongs to rather than sitting
        // beside the chip all day. It stays put while a refresh runs, so the pointer
        // wandering off mid-fetch doesn't take the spinner with it.
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                modelRowHovering = hovering
            }
        }
    }

    /// Whether the refresh arrow is on screen — hovered, or busy and therefore
    /// owed an indicator.
    private var refreshVisible: Bool { modelRowHovering || modelsBusy }

    /// Either refresh is running — the button wears the spinner for both, so the
    /// row never shows two indicators for one idea.
    private var modelsBusy: Bool { loadingModels || refreshingModels }

    /// The refresh button's action: re-ask **everything** the model list is built
    /// from — the curated manifest, every keyed provider's live `/v1/models` (the
    /// custom endpoint included), the CLI backends' catalogs and Claude Code's
    /// alias probe — ignoring every TTL along the way (see `loadAll(force:)`).
    @MainActor
    private func manualRefreshModels() async {
        guard !refreshingModels else { return }
        refreshingModels = true
        await catalog.loadAll(force: true)
        refreshingModels = false
    }
}
