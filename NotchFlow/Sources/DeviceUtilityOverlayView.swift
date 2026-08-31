import SwiftUI
import AVFoundation

/// What is running low, and where sound goes — the two things this card
/// answers, left and right, the same split `NotchUtilitiesView` uses for the
/// File tray and Calendar.
struct DeviceUtilityOverlayView: View {
    @ObservedObject var system: SystemUtilityService
    @ObservedObject private var capabilities = UtilityCapabilityService.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow
            HStack(alignment: .top, spacing: 12) {
                batteryColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                outputColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(alignment: .top, spacing: 12) {
                hardwareColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                volumesAndCameraColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = system.deviceActionError {
                Text(error)
                    .font(.sf(9.5, weight: .medium))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .task {
            system.refreshOutputDevices()
            await system.refreshBatteries()
            system.refreshDeviceDetails()
        }
        .onDisappear { capabilities.stopWebcam() }
    }

    private var headerRow: some View {
        HStack {
            Label("Devices", systemImage: "laptopcomputer.and.iphone")
                .font(.sf(13, weight: .bold))
                .foregroundStyle(Tokens.text1)
            Spacer()
            closeButton
        }
    }

    // MARK: - Batteries

    private var batteryColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading("Battery", symbol: "battery.100percent")
            if system.batteries.isEmpty {
                Text(L("utilities.devices.none")).font(.sf(11, weight: .regular)).foregroundStyle(Tokens.text3)
            } else {
                VStack(spacing: 5) {
                    ForEach(system.batteries) { battery in
                        HStack(spacing: 7) {
                            // The device-type glyph stays put whether or not it's
                            // charging — swapping it for a bare bolt (the old
                            // behavior) lost "which device is this" right when the
                            // row is most likely to be glanced at (plugged in to
                            // top up before heading out).
                            Image(systemName: battery.symbolName)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 16)
                            Text(battery.name).font(.sf(11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            if battery.isCharging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(battery.percent.map { "\($0)%" } ?? "—")
                                .font(.sf(10.5, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(battery.isCharging ? Color.green : (battery.isLow ? Color.orange : Tokens.text2))
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.05)))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(battery.name), \(battery.percent.map { "\($0) percent" } ?? "unknown level")"
                            + (battery.isCharging ? ", \(L("utilities.devices.charging"))" : ""))
                    }
                }
            }
            if system.batteries.contains(where: { $0.name == "Mac" }) {
                batteryDetailRows
            }
        }
    }

    private var batteryDetailRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let time = system.batteryDetails.estimatedTimeLabel {
                detailRow("Battery", time)
            }
            if let capacity = system.batteryDetails.maximumCapacityPercent {
                detailRow("Capacity", "\(capacity)%")
            }
            if let cycles = system.batteryDetails.cycleCount {
                detailRow("Cycles", "\(cycles)")
            }
            let health = system.batteryDetails.health?.trimmingCharacters(in: .whitespacesAndNewlines)
            detailRow("Battery health", health?.isEmpty == false ? health! : "Unavailable")
        }
        .padding(.horizontal, 3)
    }

    // MARK: - Output

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading(L("utilities.output"), symbol: "hifispeaker.fill")

            VStack(spacing: 5) {
                ForEach(system.outputDevices) { device in
                    let isCurrent = device.id == system.currentOutputDeviceID
                    Button {
                        system.selectOutputDevice(device.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isCurrent ? Tokens.accent : Tokens.text3)
                            Text(device.name).font(.sf(11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isCurrent ? Tokens.accent.opacity(0.12) : Color.white.opacity(0.05)))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Local hardware

    private var hardwareColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("This Mac", symbol: "laptopcomputer")
            detailRow("Model", system.overview.modelName)
            detailRow("System", system.overview.macOSVersion)
            detailRow("Uptime", system.overview.uptimeLabel)
            if system.overview.displays.isEmpty {
                detailRow("Displays", "—")
            } else {
                detailRow("Displays", system.overview.displaySummary)
                ForEach(system.overview.displays) { display in
                    detailRow(display.name, display.resolution)
                }
            }
        }
    }

    private var volumesAndCameraColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("External devices", symbol: "externaldrive.fill")
            if system.removableVolumes.isEmpty {
                Text("No removable drives connected")
                    .font(.sf(10, weight: .regular)).foregroundStyle(Tokens.text3)
            } else {
                ForEach(system.removableVolumes) { volume in
                    HStack(spacing: 5) {
                        Button { system.revealVolume(volume) } label: {
                            Text(volume.name).lineLimit(1)
                        }
                        .buttonStyle(.plain).foregroundStyle(Tokens.text2)
                        Text(volume.capacityLabel).font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3)
                        Spacer(minLength: 2)
                        Button { system.ejectVolume(volume) } label: {
                            Image(systemName: "eject.fill").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Tokens.text3)
                        .accessibilityLabel("Eject \(volume.name)")
                    }
                    .font(.sf(10, weight: .medium))
                }
            }
            cameraControl
        }
    }

    private var cameraControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Color.white.opacity(0.06)).padding(.top, 2)
            HStack {
                Label("Camera preview", systemImage: "video")
                    .font(.sf(10, weight: .medium)).foregroundStyle(Tokens.text2)
                Spacer()
                Button(capabilities.webcamSession == nil ? "Open" : "Close") {
                    if capabilities.webcamSession == nil {
                        Task { await capabilities.startWebcam() }
                    } else {
                        capabilities.stopWebcam()
                    }
                }
                .buttonStyle(.plain).font(.sf(10, weight: .semibold)).foregroundStyle(Tokens.accent)
            }
            if let session = capabilities.webcamSession {
                CameraPreview(session: session)
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(label).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).lineLimit(1).multilineTextAlignment(.trailing)
        }
        .font(.sf(10, weight: .medium))
        .foregroundStyle(Tokens.text3)
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.sf(11, weight: .bold))
            .foregroundStyle(Tokens.text1)
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

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
    }
}

private final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
