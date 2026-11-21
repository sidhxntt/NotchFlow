import AppKit

/// Opens the island while a file drag is still on its way to it.
///
/// The resting notch sits on the top edge of the screen, and a drag that
/// reaches that edge is something macOS can treat as a request for Mission
/// Control — so aiming a file at the closed notch could throw the whole screen
/// into Mission Control instead of landing the drop. Opening the island when
/// the drag comes within `approachDepth` of the notch puts a large drop target
/// *below* the edge, where the file is naturally released.
///
/// A global mouse monitor (no Accessibility permission needed for mouse
/// events) watches drags in other apps. A drag counts only when the system
/// drag pasteboard changed since the mouse went down and carries file URLs —
/// that is what separates a file drag from selecting text or moving a window.
/// Only the pasteboard's *types* are read, never its contents.
@MainActor
final class FileDragProximityMonitor {
    /// How far below the top of the screen the approach zone reaches.
    static let approachDepth: CGFloat = 150
    /// Half the zone's width, either side of the notch's centre.
    static let approachHalfWidth: CGFloat = 230

    struct Zone {
        let display: CGDirectDisplayID
        let rect: NSRect
    }

    private let zones: () -> [Zone]
    /// Returns whether it opened the island (false if it was already open).
    private let onApproach: (CGDirectDisplayID) -> Bool
    private let onDragEnded: (CGDirectDisplayID) -> Void
    /// Any drag that reached a notch was released, wherever it ended.
    private let onRelease: () -> Void

    private var monitors: [Any] = []
    private var changeCountAtMouseDown = 0
    /// The current drag has already reached a notch; it is acted on once.
    private var handledThisDrag = false
    /// The display this drag opened, so the drag's end can fold it back. Nil
    /// when the island was already open — that one is the user's, not ours.
    private var openedForDrag: CGDirectDisplayID?

    init(zones: @escaping () -> [Zone],
         onApproach: @escaping (CGDirectDisplayID) -> Bool,
         onDragEnded: @escaping (CGDirectDisplayID) -> Void,
         onRelease: @escaping () -> Void) {
        self.zones = zones
        self.onApproach = onApproach
        self.onDragEnded = onDragEnded
        self.onRelease = onRelease
    }

    func start() {
        guard monitors.isEmpty else { return }
        let handlers: [(NSEvent.EventTypeMask, @MainActor (FileDragProximityMonitor) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown() }),
            (.leftMouseDragged, { $0.mouseDragged() }),
            (.leftMouseUp, { $0.mouseUp() }),
        ]
        for (mask, handler) in handlers {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }) {
                monitors.append(monitor)
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        handledThisDrag = false
        openedForDrag = nil
    }

    private func mouseDragged() {
        guard !handledThisDrag else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != changeCountAtMouseDown,
              pasteboard.types?.contains(.fileURL) == true else { return }
        let location = NSEvent.mouseLocation
        guard let zone = zones().first(where: { $0.rect.contains(location) }) else { return }
        handledThisDrag = true
        if onApproach(zone.display) { openedForDrag = zone.display }
    }

    private func mouseUp() {
        if handledThisDrag { onRelease() }
        handledThisDrag = false
        guard let display = openedForDrag else { return }
        openedForDrag = nil
        onDragEnded(display)
    }

    /// The approach zone for a notch panel: a band hanging from the top of the
    /// screen, centred on the notch (the panel is centred on it).
    static func zone(for panelFrame: NSRect, display: CGDirectDisplayID) -> Zone {
        Zone(display: display,
             rect: NSRect(x: panelFrame.midX - approachHalfWidth,
                          y: panelFrame.maxY - approachDepth,
                          width: approachHalfWidth * 2,
                          height: approachDepth))
    }
}
