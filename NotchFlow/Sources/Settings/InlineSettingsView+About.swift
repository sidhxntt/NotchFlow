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
    // MARK: - About
    // MARK: - Stats

    /// Settings → **Stats**. The pane is a pure function of the archive, so this
    /// holds nothing but the folded digest and refreshes it when the archive
    /// grows under it (an answer can land while the pane is open).
    var statsSection: some View {
        Group {
            if let stats {
                StatsPane(digest: stats, tokens: statsTokens, hovered: $statsHover)
            } else {
                // Deliberately blank until the first fold lands: the archive
                // decodes asynchronously at launch, and flashing "no activity
                // yet" for a frame before the numbers arrive reads as a bug.
                Color.clear.frame(height: 1)
            }
        }
        .task(id: statsFingerprint) { await refreshStats() }
    }

    /// What has to change for the digest to be stale. Not `history.count` alone:
    /// a follow-up on an open thread rewrites that thread in place and re-files it
    /// at the head, so the row count doesn't move while the word count does — the
    /// pane would sit there showing the figure from before the answer.
    private var statsFingerprint: some Hashable {
        struct Fingerprint: Hashable { let count: Int; let newest: Date? }
        return Fingerprint(count: model.history.count, newest: model.history.first?.t)
    }

    /// Fold the archive off the main thread. It's a few milliseconds over today's
    /// archives, but the walk is unbounded — it grows with every answer the app
    /// ever gives — and the panel it would block is an animating one.
    private func refreshStats() async {
        let items = model.history
        let digest = await Task.detached(priority: .userInitiated) {
            StatsDigest.make(from: items)
        }.value
        stats = digest
        // The token figure is the one number on the pane that isn't folded from
        // the archive — it's the meter's own running total (see `TokenMeter`),
        // re-read on the same beat, since the answer that grew the archive is
        // also the request that moved the meter.
        statsTokens = TokenMeter.shared.reading
    }

    var aboutSection: some View {
        let content = aboutContent
        return VStack(alignment: .leading, spacing: 14) {
            // 1 — Identity: who the app is, with the version and its update
            // action right beside the name so "what you're running / is it
            // current" reads as one thought instead of three scattered lines.
            HStack(alignment: .center, spacing: 12) {
                // AppIconStyle supplies the native bundle icon for Original and
                // the selected catalog artwork for Dot. Neither preview reads
                // `NSApp.applicationIconImage`, whose live Dock rendering can add
                // a system treatment inside this dark panel.
                let iconStyle = AppIconStyle.current
                if let icon = iconStyle.image ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(iconStyle.previewScale)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.name)
                        .font(.brand(18))
                        .foregroundStyle(Tokens.text1)

                    Text(content.tagline)
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(UpdaterService.currentVersion)
                            .font(.sf(12, weight: .medium))
                            .foregroundStyle(Tokens.text4)
                        // Hairline between the version and its update action, so
                        // the two sit as one row without running together.
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 0.5, height: 11)
                        updateArea
                    }
                }

                Spacer(minLength: 0)
            }

            LicenseManagementView(service: license)

            // 2 — Where else to go: the pages that open here, then the rail of
            // places that leave.
            aboutLinks(content: content)

            // 3 — Attribution. Not one of the things you *do* from About, so it
            // sits below the rail as a footnote — the last line of the pane, in
            // the place a colophon belongs.
            AboutFootnoteLink(title: L("about.licenses")) {
                withAnimation(.easeOut(duration: 0.16)) {
                    section = .licenses
                }
            }
            .padding(.top, 2)
        }
    }

    /// The whole update story in one slot, right under the version number where
    /// it belongs: at rest a quiet "Check for updates" link, and every state that
    /// follows — checking, "up to date", "Update to X", updating, failed — swaps
    /// through this same spot rather than scattering across the panel. Because a
    /// newer version and the manual-check confirmation share the slot, they read
    /// as one continuous action instead of two unrelated controls.
    ///
    /// The faces differ in width, weight, and height (the failure pill especially),
    /// so any positional transition makes them jump. Deliberately plain: one face
    /// cross-fades into the next in place — opacity only, no drift, no spring — so
    /// switching states never shifts anything around it.
    private var updateArea: some View {
        ZStack(alignment: .leading) {
            updateContent
                .id(updateSlot)
                .transition(.opacity)
        }
        // Text and the small spinner report slightly different intrinsic
        // heights. Keep their shared row fixed so starting a check cannot nudge
        // the identity stack by a fraction of a point.
        .frame(height: 16, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: updateSlot)
    }

    /// Which face the update slot is showing. Collapsing phase + manualCheck into
    /// one enum gives `updateArea` a single value to key the cross-fade on, so
    /// SwiftUI treats each face as a distinct view that fades in and out.
    private enum UpdateSlot: Hashable {
        case rest, checking, upToDate, available(String), updating, failed
    }

    private var updateSlot: UpdateSlot {
        // A retry started from the failed slot shows its own spinner; `.failed`
        // would otherwise hold the slot until the check came back.
        if updater.manualCheck == .checking, updater.phase != .updating { return .checking }
        switch updater.phase {
        case .available(let v): return .available(v)
        case .updating:         return .updating
        case .failed:           return .failed
        case .unknown, .upToDate:
            switch updater.manualCheck {
            case .checking: return .checking
            case .upToDate: return .upToDate
            case .idle:     return .rest
            }
        }
    }

    @ViewBuilder
    private var updateContent: some View {
        switch updateSlot {
        case .available(let v):
            aboutLink(L("about.update.to", v), weight: .semibold) {
                updater.update()
            }
        case .updating:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(L("about.updating"))
                    .font(.sf(12, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
            }
        case .failed:
            HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(UpdaterService.releaseNotesPage)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Tokens.danger)
                        .frame(width: 6, height: 6)
                    Text(L("about.updateFailed"))
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(Tokens.danger.opacity(0.92))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(Tokens.danger.opacity(0.12)))
                .overlay(Capsule(style: .continuous).strokeBorder(Tokens.danger.opacity(0.22), lineWidth: 0.5))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open release notes")
            // A background check that failed once (offline, a GitHub hiccup)
            // must not take the way to check again with it.
            aboutLink(L("about.updateRetry")) {
                updater.checkManually()
            }
            }
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(L("about.checking"))
                    .font(.sf(11.5, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
        case .upToDate:
            Text(L("about.upToDate"))
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .task {
                    // Let the confirmation linger, then recede to the link.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    updater.clearManualConfirmation()
                }
        case .rest:
            aboutLink(L("about.checkForUpdates")) {
                updater.checkManually()
            }
        }
    }

    /// The primary About actions expose the developer, social profile, and
    /// feedback destination without burying any of them in another menu.
    private func aboutLinks(content: AboutContentConfiguration) -> some View {
        VStack(spacing: 0) {
            if aboutURL(content.aboutMeURL) != nil || aboutURL(content.xURL) != nil || aboutURL(content.feedbackURL) != nil {
                HStack(spacing: 9) {
                if let aboutMePage = aboutURL(content.aboutMeURL) {
                    AboutSocialButton(kind: .aboutMe,
                                      title: "About Me") {
                        NSWorkspace.shared.open(aboutMePage)
                    }
                }
                if let xPage = aboutURL(content.xURL) {
                    AboutSocialButton(kind: .x,
                                      title: L("about.followX")) {
                        NSWorkspace.shared.open(xPage)
                    }
                }
                if let feedbackPage = aboutURL(content.feedbackURL) {
                    AboutSocialButton(kind: .feedback,
                                      title: L("about.feedback")) {
                        NSWorkspace.shared.open(feedbackPage)
                    }
                }
                Spacer(minLength: 0)
                }
            }

            VStack(spacing: 0) {
                if let website = aboutURL(content.website) {
                    AboutUtilityButton(title: "Website", leaves: true) {
                        NSWorkspace.shared.open(website)
                    }
                    aboutUtilitySeparator
                }

                AboutUtilityButton(title: L("about.whatsNew"), leaves: false) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.openWhatsNew(on: nil)
                    }
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.replayIntro"), leaves: false) {
                    replayIntro()
                }

                if let privacyPage = aboutURL(content.privacyURL) {
                    aboutUtilitySeparator

                    AboutUtilityButton(title: L("about.privacy"), leaves: true) {
                        NSWorkspace.shared.open(privacyPage)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 12)
        }
    }

    private var aboutContent: AboutContentConfiguration {
        AboutContentConfiguration.bundled()
    }

    private func aboutURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    private var aboutUtilitySeparator: some View {
        Rectangle()
            .fill(.white.opacity(0.065))
            .frame(height: 0.5)
            .padding(.leading, 11)
    }

    /// Attribution stays on its own level instead of hiding behind the replay
    /// button's hover help. This makes the bundled recording's author, source,
    /// licence, and the fact that it was edited continuously visible.
    var licensesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("about.music"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("classicals.de") {
                    NSWorkspace.shared.open(URL(string: "https://www.classicals.de")!)
                }
                aboutLink("CC BY 4.0") {
                    NSWorkspace.shared.open(URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }

            Text(L("about.thinkingOrbs"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("thinking-orbs") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Jakubantalik/thinking-orbs")!)
                }
                aboutLink("MIT License") {
                    NSWorkspace.shared.open(URL(string: "https://opensource.org/license/mit")!)
                }
            }

            // The two answer-gallery interactions (the fanning image stack and
            // the image modal it opens into) are ports of Interaction Kit's web
            // components — the geometry, springs and thresholds are theirs.
            Text(L("about.interactionKit"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("Interaction Kit") {
                    NSWorkspace.shared.open(URL(string: "https://interactionkit.org")!)
                }
                aboutLink("MIT License") {
                    NSWorkspace.shared.open(URL(string: "https://opensource.org/license/mit")!)
                }
            }

            // The bundled Latin handwriting face (Settings → Appearance,
            // "Handwritten answers"). The OFL asks that the licence travel with
            // the software that ships the font.
            Text(L("about.handwritingFont"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("Caveat") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/googlefonts/caveat")!)
                }
                aboutLink("SIL OFL 1.1") {
                    NSWorkspace.shared.open(URL(string: "https://openfontlicense.org")!)
                }
            }
        }
    }

    private enum AboutSocialKind {
        case aboutMe, x, feedback
    }

    /// Each primary action swaps its familiar mark for a matching action glyph
    /// on hover, keeping the three destinations visually consistent.
    private struct AboutSocialButton: View {
        let kind: AboutSocialKind
        let title: String
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var accent: Color {
            switch kind {
            case .aboutMe:
                Color(red: 245 / 255, green: 166 / 255, blue: 35 / 255)
            case .x:
                Color(red: 249 / 255, green: 24 / 255, blue: 128 / 255)
            case .feedback:
                Color(red: 81 / 255, green: 153 / 255, blue: 252 / 255)
            }
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 9) {
                    ZStack {
                        brandMark
                            .foregroundStyle(Tokens.text2)
                            .opacity(hovering ? 0 : 1)
                            .offset(y: reduceMotion ? 0 : (hovering ? -13 : 0))
                            .scaleEffect(reduceMotion ? 1 : (hovering ? 0.8 : 1))

                        actionMark
                            .opacity(hovering ? 1 : 0)
                            .offset(y: reduceMotion ? 0 : (hovering ? 0 : 13))
                            .scaleEffect(reduceMotion ? 1 : (hovering ? 1 : 0.8))
                    }
                    .frame(width: 17, height: 17)

                    Text(title)
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .background(
                    Capsule()
                        .fill(.white.opacity(hovering ? 0.075 : 0.04))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.5)
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(AboutSocialPressStyle())
            .scaleEffect(reduceMotion ? 1 : (hovering ? 1.02 : 1))
            .onHover { inside in
                hovering = inside
                // One tap as the button catches under the cursor — the same one
                // the island gets when it snaps open. Only on the way in;
                // leaving is passive.
                if inside { Haptics.alignment() }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72),
                       value: hovering)
        }

        @ViewBuilder
        private var brandMark: some View {
            switch kind {
            case .aboutMe:
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18, weight: .medium))
            case .x:
                Image("XMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            case .feedback:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 15, weight: .medium))
            }
        }

        /// Hover replaces each resting mark with the action it represents.
        @ViewBuilder
        private var actionMark: some View {
            switch kind {
            case .aboutMe:
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            case .x:
                // heart.fill sits smaller in its box than star.fill at the same
                // point size, so it takes a notch more to read equal.
                Image(systemName: "heart.fill")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(accent)
            case .feedback:
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    private struct AboutSocialPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.68),
                           value: configuration.isPressed)
        }
    }

    /// One of the four secondary About destinations. They return to the original
    /// one-action-per-row rhythm, grouped together underneath the social row.
    private struct AboutUtilityButton: View {
        let title: String
        let leaves: Bool
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: leaves ? "arrow.up.right" : "chevron.right")
                        .font(.system(size: leaves ? 8.5 : 9, weight: .semibold))
                        .foregroundStyle(Tokens.text4)
                        .opacity(hovering ? 1 : 0.6)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 33, maxHeight: 33)
                .background(Color.white.opacity(hovering ? 0.05 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }

    /// The colophon link under the rail: the rows' hover grammar (quiet text
    /// brightening to text1) with none of their chrome — no row height, no
    /// chevron — so it reads as a footnote rather than a fifth action.
    private struct AboutFootnoteLink: View {
        let title: String
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text4)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }

    /// Play the first-run intro again from About. The once-ever flag is left
    /// untouched — this is an on-demand replay, not an onboarding reset.
    private func replayIntro() {
        let display = model.activeDisplay
        let screen = NSScreen.screens.first { $0.displayID == display } ?? NSScreen.main
        guard let screen else { return }
        model.fullClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            NSApp.activate(ignoringOtherApps: true)
            IntroAnimation.shared.play(on: screen) {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                    model.mode = .idle
                    model.openPanel(on: screen.displayID)
                }
            }
        }
    }

    private func aboutLink(_ title: String, weight: Font.Weight = .medium,
                           action: @escaping () -> Void) -> some View {
        AboutTextLink(title: title, weight: weight, action: action)
    }

    /// The quiet text-link species used throughout About. It stays visually light,
    /// but unlike inert body copy it now answers the pointer consistently.
    private struct AboutTextLink: View {
        let title: String
        let weight: Font.Weight
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.sf(12, weight: weight))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        }
    }

    var footer: some View {
        Group {
            if envOverride {
                Text(L("model.footer.env", keyScope.envVarName))
            } else {
                Text(footerText)
            }
        }
        .font(.sf(11))
        .foregroundStyle(Tokens.text3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    /// Footer help with the signup host as a clickable link, built as an
    /// `AttributedString` so the sentence stays one `Text` while only the host
    /// opens the signup page. Scoped to the key section's provider — it explains
    /// the key field above it. The pre/post fragments are localized; the host
    /// itself is the literal domain, so it stays the same in every language.
    private var footerText: AttributedString {
        if keyScope == .openrouter {
            // The free-by-default story: connect once, the key lives in the
            // user's own account, and the daily cap is theirs alone.
            var text = AttributedString(L("model.footer.openrouter.pre"))
            var host = AttributedString("openrouter.ai")
            host.link = URL(string: "https://openrouter.ai")
            host.foregroundColor = Tokens.text2
            text.append(host)
            text.append(AttributedString(L("model.footer.openrouter.post")))
            return text
        }
        // The custom endpoint has no key console to link to — the footer explains
        // what the fields above accept, and that the key is optional.
        if keyScope == .custom { return AttributedString(L("model.custom.footer")) }
        var text = AttributedString(L("model.footer.byok.pre"))
        var host = AttributedString(keyScope.signupHost)
        host.link = keyScope.signupURL
        host.foregroundColor = Tokens.text2
        text.append(host)
        text.append(AttributedString(L("model.footer.byok.post")))
        return text
    }
}
