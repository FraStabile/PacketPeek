//
//  SimulatorCertificateView.swift
//  ProxyApp
//
//  Lists every booted iOS Simulator and lets the user install the PacketPeek
//  root CA into each, with an explicit "Reboot" follow-up — many apps cache
//  the trust chain in memory, so a fresh boot is the most reliable way to
//  pick up the new root.
//

import SwiftUI

struct SimulatorCertificateView: View {
    @StateObject private var integration = SimulatorIntegration()
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Install PacketPeek CA on iOS Simulator")
                    .font(.headline)
                Spacer()
                Button {
                    Task { try? await integration.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh booted simulators")
            }

            if integration.bootedSimulators.isEmpty {
                ContentUnavailableView(
                    "No booted simulators",
                    systemImage: "iphone.slash",
                    description: Text("Boot an iOS Simulator from Xcode, then refresh.")
                )
                .frame(minHeight: 200)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(integration.bootedSimulators) { sim in
                            row(for: sim)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 220)
            }

            if let msg = errorMessage {
                Text(msg)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            do { try await integration.refresh() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func row(for sim: SimulatorIntegration.Simulator) -> some View {
        let status = integration.statusByUDID[sim.udid] ?? .notInstalled
        let isBusy = integration.busyUDIDs.contains(sim.udid)

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sim.name).font(.body)
                Text(prettyRuntime(sim.runtime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge(for: status)

            actionButton(for: sim, status: status, isBusy: isBusy)
                .frame(minWidth: 96)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: SimulatorIntegration.InstallStatus) -> some View {
        switch status {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .needsRebootSuggested:
            Label("Installed — reboot suggested", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .staleCA:
            Label("CA changed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .notInstalled:
            Label("Not installed", systemImage: "circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private func actionButton(for sim: SimulatorIntegration.Simulator,
                              status: SimulatorIntegration.InstallStatus,
                              isBusy: Bool) -> some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch status {
            case .notInstalled, .staleCA:
                Button("Install") { perform { try await integration.install(udid: sim.udid) } }
                    .buttonStyle(.borderedProminent)
            case .needsRebootSuggested:
                Button("Reboot") { perform { try await integration.reboot(udid: sim.udid) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            case .installed:
                Button("Re-install") { perform { try await integration.install(udid: sim.udid) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                errorMessage = nil
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5".
    private func prettyRuntime(_ raw: String) -> String {
        let suffix = raw.components(separatedBy: ".").last ?? raw
        let parts = suffix.components(separatedBy: "-")
        guard parts.count >= 3 else { return suffix }
        let platform = parts[0]
        let version = parts.dropFirst().joined(separator: ".")
        return "\(platform) \(version)"
    }
}
