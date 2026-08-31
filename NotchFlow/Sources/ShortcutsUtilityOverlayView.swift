import SwiftUI

/// The user's own Shortcuts, listed live — nobody has to design for this one,
/// whatever they have built simply shows up.
///
/// Two columns rather than one list: the card is wide and short, and a dozen
/// names in a single column would leave the right half empty. `LazyVGrid`
/// balances into left and right on its own, at any count, rather than this view
/// having to split the array itself.
struct ShortcutsUtilityOverlayView: View {
    @StateObject private var shortcuts = ShortcutsCatalog()
    @State private var runError: String?
    let close: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    /// Favourites shown here, in this order, matched by exact name against the
    /// user's live Shortcuts list — a curated handful rather than everything
    /// `shortcuts list` returns, so the card stays a menu the user chose rather
    /// than a dump of whatever they've accumulated.
    static let favourites: [String] = [
        "QR Your Wi-Fi",
        "Water Eject",
        "Morning Summary",
        "Shazam shortcut"
    ]

    /// Filters the live list down to `favourites`, preserving favourites' order
    /// rather than whatever order `shortcuts list` happened to return. A
    /// favourite that no longer exists (deleted, renamed) is skipped silently.
    static func curated(from names: [String]) -> [String] {
        let matches = favourites.compactMap { favourite in
            names.first { $0.caseInsensitiveCompare(favourite) == .orderedSame }
        }
        return matches.isEmpty ? Array(names.prefix(favourites.count)) : matches
    }

    private var curatedNames: [String] { Self.curated(from: shortcuts.names) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(curatedNames, id: \.self) { name in
                    Button {
                        ShortcutsCatalog.run(name) { runError = $0 }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold))
                            Text(name).font(.sf(11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 9)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text2)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
                }
                createShortcutTile
            }
            if let runError {
                Text(runError).font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.danger).lineLimit(2)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .task { await shortcuts.load() }
    }

    private var headerRow: some View {
        HStack {
            Label(L("utilities.shortcut"), systemImage: "bolt.fill")
                .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
            Spacer()
            closeButton
        }
    }

    /// Not a favourite — a permanent extra tile that opens Shortcuts to build a
    /// new one, so the card stays a launcher for creation too rather than only
    /// a list of what already exists.
    private var createShortcutTile: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.system(size: 10, weight: .semibold))
                Text(L("utilities.shortcuts.create")).font(.sf(11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.accent)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Tokens.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.sf(10, weight: .bold))
                .frame(width: 25, height: 25)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Tokens.text3)
        .accessibilityLabel(L("utilities.power.close"))
    }
}
