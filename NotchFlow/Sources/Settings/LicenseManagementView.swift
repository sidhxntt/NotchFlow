import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// The license card always lives in Settings → About, so activation and
/// deactivation use the same shared state whether the product is available or
/// restricted after a trial expires.
struct LicenseManagementView: View {
    @ObservedObject var service: LicenseService

    @State private var licenseKey = ""
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(statusTitle)
                            .font(.headline)
                        if service.state.shouldRestrictSettingsToAbout {
                            Text(L("license.settings.locked"))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(statusBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch service.state {
            case .checking:
                ProgressView(L("license.checking"))
                    .controlSize(.small)
            case .licensed:
                if service.hasActivatedLicense {
                    Button(isWorking ? L("license.deactivating") : L("license.deactivate"),
                           role: .destructive) {
                        deactivate()
                    }
                    .disabled(isWorking)
                }
            case .trial, .blocked:
                activationControls
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("License error: \(errorMessage)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    private var activationControls: some View {
        if case .blocked(reason: .configurationUnavailable) = service.state {
            EmptyView()
        } else if case .blocked(reason: .secureStorageUnavailable) = service.state {
            EmptyView()
        } else {
            HStack {
                if let checkoutURL = service.beginCheckout() {
                    Button(L("license.buy"), systemImage: "cart") {
                        NSWorkspace.shared.open(checkoutURL)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L("license.activating"))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("license.key"))
                    .font(.subheadline)
                    .bold()
                SecureField(L("license.key.placeholder"), text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                Text(L("license.email"))
                    .font(.subheadline)
                    .bold()
                TextField(L("license.email.placeholder"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .onSubmit { activate() }
                Button(isWorking ? L("license.activating") : L("license.activate"),
                       systemImage: "key") {
                    activate()
                }
                .disabled(isWorking || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .checking: "clock"
        case .trial: "hourglass"
        case .licensed: "checkmark.seal.fill"
        case .blocked: "lock.fill"
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .licensed: .green
        case .blocked: .orange
        case .checking, .trial: .secondary
        }
    }

    private var statusTitle: String {
        switch service.state {
        case .checking: L("license.title")
        case .trial: L("license.trial")
        case .licensed: L("license.licensed")
        case .blocked(reason: .trialExpired): L("license.blocked.title")
        case .blocked: L("license.title")
        }
    }

    private var statusBody: String {
        switch service.state {
        case .checking: L("license.checking")
        case .trial(let remaining): remaining == 1
            ? L("license.trial.remaining.one")
            : L("license.trial.remaining", Int64(remaining))
        case .licensed: L("license.licensed.body")
        case .blocked(reason: .licenseInvalid): L("license.invalid.body")
        case .blocked(reason: .configurationUnavailable): L("license.configuration.body")
        case .blocked(reason: .secureStorageUnavailable): L("license.storage.body")
        case .blocked: L("license.blocked.body")
        }
    }

    private func activate() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await service.activate(key: licenseKey, email: email)
                licenseKey = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deactivate() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await service.deactivateCurrentMac()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
