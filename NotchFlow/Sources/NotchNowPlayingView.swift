import AppKit
import SwiftUI

/// NotchFlow-native rendering of the now-playing capability.
/// It shares the root panel's black/glass language.
struct NotchNowPlayingView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var capabilities: NotchCapabilityStore
    @State private var pendingSeek: TimeInterval?

    var body: some View {
        Group {
            if capabilities.media.hasTrack { activePlayer(capabilities.media) }
            else { emptyPlayer }
        }
        .buttonStyle(.plain)
        .padding(capabilities.media.hasTrack ? 14 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !capabilities.media.hasTrack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.setPanelControlInteraction(true) }
                .onEnded { _ in model.setPanelControlInteraction(false) }
        )
        .onDisappear { model.setPanelControlInteraction(false) }
        .task {
            await capabilities.refresh()
        }
    }

    private var emptyPlayer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                Text("Nothing playing").font(.sf(12.5, weight: .semibold))
            }.foregroundStyle(Tokens.text2)
            Text("Start listening in a player to see controls here.")
                .font(.sf(10.5, weight: .regular)).foregroundStyle(Tokens.text3)
            if let error = capabilities.mediaError {
                Text(error)
                    .font(.sf(9.5, weight: .medium))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { playerShortcut(.spotify); playerShortcut(.appleMusic) }
        }
    }

    private func playerShortcut(_ source: MediaSource) -> some View {
        Button { capabilities.launchMedia(source) } label: {
            HStack(spacing: 6) {
                sourceIcon(source, size: 18)
                Text(source.displayName).font(.sf(10.5, weight: .semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule())
        }
    }

    private func activePlayer(_ media: MediaState) -> some View {
        HStack(alignment: .center, spacing: 16) {
            artwork(for: media, size: 104)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.sf(12.5, weight: .semibold)).lineLimit(1)
                    Text("\(media.source.displayName) · \(media.artist)")
                        .font(.sf(10.5, weight: .regular)).foregroundStyle(Tokens.text3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { capabilities.launchMedia(media) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }

                // Browser sessions (`.nowPlaying`) commonly report a duration of 0
                // when the website's Media Session API hasn't (yet, or ever) supplied
                // one — that must not hide the whole scrubber row, only make dragging
                // pointless. `max(..., 1)` also keeps the range non-degenerate: a
                // literal `0...0` Slider renders inert in SwiftUI even when it is
                // otherwise shown.
                let hasKnownDuration = media.duration > 0
                Slider(value: Binding(get: { pendingSeek ?? media.position }, set: { pendingSeek = $0 }),
                       in: 0...max(media.duration, media.position, 1),
                       onEditingChanged: { editing in
                           guard !editing, let position = pendingSeek else { return }
                           pendingSeek = nil
                           Task { await capabilities.performMedia(.seek(position)) }
                       })
                    .tint(Tokens.text2)
                    .disabled(!hasKnownDuration)
                HStack {
                    Text(time(pendingSeek ?? media.position))
                    Spacer()
                    Text(hasKnownDuration ? time(media.duration) : "--:--")
                }
                    .font(.sf(9, weight: .medium)).foregroundStyle(Tokens.text3)

                HStack(spacing: 16) {
                    Spacer()
                    Button { Task { await capabilities.performMedia(.previous) } } label: { Image(systemName: "backward.fill") }
                    Button { Task { await capabilities.performMedia(.playPause) } } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 26, height: 26).background(Color.white.opacity(0.14), in: Circle())
                    }
                    Button { Task { await capabilities.performMedia(.next) } } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        }
    }

    @ViewBuilder private func artwork(for media: MediaState, size: CGFloat) -> some View {
        if let data = media.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else { fallbackArtwork(for: media.source, size: size) }
    }

    @ViewBuilder private func fallbackArtwork(for source: MediaSource, size: CGFloat) -> some View {
        if source == .spotify || source == .appleMusic {
            Image(source == .spotify ? "SpotifyMark" : "AppleMusicMark")
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.indigo.opacity(0.72), Color.black.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: source == .nowPlaying ? "globe" : "music.note")
                .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
        }
    }

    @ViewBuilder private func sourceIcon(_ source: MediaSource, size: CGFloat) -> some View {
        if source == .spotify {
            Image("SpotifyMark")
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if source == .appleMusic {
            Image("AppleMusicMark")
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.indigo, in: Circle())
        }
    }

    private func time(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
