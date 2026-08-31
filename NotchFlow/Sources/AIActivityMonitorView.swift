import SwiftUI

/// A compact monitor for the AI accounts and sessions currently visible to
/// NotchFlow. Context comes from the agents' transcripts; usage rows are
/// provider-reported consumption collected locally, never guessed plan quotas.
struct AIActivityMonitorView: View {
    @ObservedObject var sessions: AgentSessionActivityStore
    @ObservedObject var tasks: AgentTaskManager
    @State private var selectedID: String?
    @State private var selectedProvider = "Codex"
    @State private var visibility = AIActivityProjectVisibility()
    private static let providerPages = ["Codex", "Claude", "Chat"]
    /// The scrollable body's height, matched to the File tray's (`NotchShelfView`)
    /// so the AI tab is the same compact surface as Utilities rather than a
    /// panel-length list.
    private static let listHeight: CGFloat = 122

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let entries = projectEntries.filter { visibility.isVisible($0.id) }
            let selected = entries.first(where: { $0.id == selectedID }) ?? entries.first
            EqualHeightUtilitiesLayout(spacing: 10) {
                projectList(entries: entries, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                projectDetail(entry: selected)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        }
    }

    /// Historical Codex usage is persisted in TokenMeter; live sessions join
    /// the same project immediately so Claude and Codex never split merely
    /// because one provider has not yet emitted a usage record.
    private var projectEntries: [TokenMeter.ProjectActivity] {
        var entries = TokenMeter.shared.projectActivities()
        let live = sessions.sessions.map { (AIActivityProject.display($0.projectName), $0.source.displayName) }
            + tasks.tasks.map { ($0.folder.lastPathComponent, $0.engine.displayName) }
        for (project, provider) in live {
            if let index = entries.firstIndex(where: { $0.project == project }) {
                let current = entries[index]
                let providers = Array(Set(current.providers + [provider])).sorted()
                entries[index] = .init(id: current.id, project: current.project, providers: providers,
                                       sessionCount: current.sessionCount + 1,
                                       contextUsed: current.contextUsed, contextWindow: current.contextWindow)
            } else {
                entries.append(.init(id: project, project: project, providers: [provider], sessionCount: 1,
                                     contextUsed: nil, contextWindow: nil))
            }
        }
        return entries.sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    private func projectList(entries: [TokenMeter.ProjectActivity], selected: TokenMeter.ProjectActivity?) -> some View {
        card(
            title: "AI activity",
            caption: "\(TokenMeter.shared.reading.total.formatted()) recorded tokens",
            headerActionTitle: visibility.hiddenCount > 0 ? "Show hidden projects (\(visibility.hiddenCount))" : nil,
            headerAction: {
                withAnimation(.easeOut(duration: 0.18)) {
                    visibility.reset()
                }
            }
        ) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                    Button { withAnimation(.easeOut(duration: 0.18)) { selectedID = entry.id } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder.fill").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(entry.id == selected?.id ? Tokens.accent : Tokens.text3).frame(width: 15)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.project).font(.sf(10.5, weight: .semibold)).lineLimit(1)
                                Text(entry.providers.joined(separator: " · ")).font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("\(entry.sessionCount) \(entry.sessionCount == 1 ? "session" : "sessions")")
                                .font(.sf(9.5, weight: .semibold)).foregroundStyle(Tokens.text3).lineLimit(1)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain).foregroundStyle(Tokens.text2)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(entry.id == selected?.id ? Tokens.accent.opacity(0.15) : Color.white.opacity(0.04)))
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            visibility.hide(entry.id)
                            if selectedID == entry.id { selectedID = nil }
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Tokens.text3)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(entry.project) from AI activity")
                    }
                }
                }
            }
            // Bounded here, not on the layout outside. This is what File tray and
            // Calendar do (`NotchShelfView`, `NotchUtilitiesView`): cap the SCROLL
            // body so the card has an intrinsic height the layout can measure, and
            // the surface stays the same size whether there are two projects or
            // twenty. Sized to match the File tray's own scroll region so the two
            // tabs read as the same kind of surface.
            .frame(height: Self.listHeight)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func projectDetail(entry: TokenMeter.ProjectActivity?) -> some View {
        card(title: "Usage") {
            // Bounded to the same body height as the list beside it. Both cards
            // are equalised by the layout, so leaving this one to grow would set
            // the whole surface's height no matter how short the list was — the
            // usage breakdown alone runs to eight rows. Capping both is what
            // keeps the tab the same compact size as Utilities.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 7) {
                    detailContent(entry: entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.listHeight)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func detailContent(entry: TokenMeter.ProjectActivity?) -> some View {
        Group {
            if let entry {
                Text(entry.project).font(.sf(12, weight: .semibold)).foregroundStyle(Tokens.text1).lineLimit(1)
                providerCarousel
                statRow("Sessions", entry.sessionCount.formatted())
                if entry.providers.map(Self.usageProvider).contains(selectedProvider), let used = entry.contextUsed {
                    let window = max(used, entry.contextWindow ?? used)
                    statRow("Context", "\(used.formatted()) / \(window.formatted())")
                    statRow("Context remaining", max(0, window - used).formatted())
                    statRow("Context used", "\(Int((Double(used) / Double(max(1, window)) * 100).rounded()))%")
                }
                Divider().overlay(Color.white.opacity(0.08))
                let fiveHour = TokenMeter.shared.usage(provider: selectedProvider, window: .fiveHours, project: entry.project)
                let week = TokenMeter.shared.usage(provider: selectedProvider, window: .week, project: entry.project)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(selectedProvider) usage").font(.sf(10.5, weight: .semibold)).foregroundStyle(Tokens.text2)
                    usageRow(title: "5-hour window", reading: fiveHour)
                    usageRow(title: "This week", reading: week)
                }
            }
        }
    }

    private var providerCarousel: some View {
        HStack(spacing: 5) {
            ForEach(Self.providerPages, id: \.self) { provider in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selectedProvider = provider }
                } label: {
                    Text(provider)
                        .font(.sf(9.5, weight: .semibold))
                        .foregroundStyle(provider == selectedProvider ? Tokens.text1 : Tokens.text3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(provider == selectedProvider ? Tokens.accent.opacity(0.18) : Color.white.opacity(0.05),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(provider) usage")
            }
            Spacer(minLength: 0)
        }
    }

    private func usageRow(title: String, reading: TokenMeter.UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3)
                Spacer(minLength: 4)
                Text(reading.total.formatted() + " tokens")
                    .font(.sf(9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tokens.text1)
            }
            HStack(spacing: 6) {
                Text("In \(reading.input.formatted()) · Out \(reading.output.formatted())")
                    .font(.sf(8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.text4)
                Spacer(minLength: 4)
                Text("Resets \(resetLabel(reading.endsAt))")
                    .font(.sf(8.5, weight: .medium))
                    .foregroundStyle(Tokens.text4)
            }
        }
    }

    private func card<Content: View>(title: String, caption: String? = nil,
                                     headerActionTitle: String? = nil,
                                     headerAction: (() -> Void)? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title).font(.sf(11, weight: .semibold)).foregroundStyle(Tokens.text3)
                Spacer(minLength: 4)
                if let headerActionTitle, let headerAction {
                    Button(headerActionTitle, action: headerAction)
                        .buttonStyle(.plain)
                        .font(.sf(9.5, weight: .semibold))
                        .foregroundStyle(Tokens.accent)
                        .lineLimit(1)
                } else if let caption {
                    Text(caption).font(.sf(9, weight: .medium)).foregroundStyle(Tokens.text4).lineLimit(1)
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.sf(10.5, weight: .medium)).foregroundStyle(Tokens.text2)
            Spacer(minLength: 6)
            Text(value).font(.sf(10, weight: .semibold).monospacedDigit()).foregroundStyle(Tokens.text1).lineLimit(1)
        }
    }

    private func resetLabel(_ end: Date, now: Date = .now) -> String {
        let seconds = max(0, end.timeIntervalSince(now))
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(1, minutes))m"
    }

    private static func usageProvider(for name: String) -> String {
        switch name {
        case "Claude Code": "Claude"
        default: name
        }
    }
}
