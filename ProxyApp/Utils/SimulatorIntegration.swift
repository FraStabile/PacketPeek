//
//  SimulatorIntegration.swift
//  ProxyApp
//
//  Automates "trust the PacketPeek root CA in every booted iOS Simulator" so the
//  user doesn't have to download the .pem inside the sim and bounce through
//  Settings → General → About → Certificate Trust Settings.
//
//  Flow:
//   1. shell out to `xcrun simctl list -j devices booted` to enumerate UDIDs
//   2. for each, `xcrun simctl keychain <udid> add-root-cert <ca.pem>`
//
//  Requires Xcode command line tools installed (xcrun on PATH).
//

import Foundation
import CryptoKit

@MainActor
final class SimulatorIntegration: ObservableObject {
    enum SimulatorError: LocalizedError {
        case xcrunMissing
        case noBootedSimulators
        case caCertMissing(URL)
        case command(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .xcrunMissing:
                return "Xcode command-line tools are not installed (xcrun not found)."
            case .noBootedSimulators:
                return "No booted iOS Simulator detected. Boot a simulator first."
            case .caCertMissing(let url):
                return "CA certificate not found at \(url.path). Start the daemon at least once so it is generated."
            case .command(let cmd, let code, let output):
                return "`\(cmd)` exited with status \(code): \(output)"
            }
        }
    }

    enum InstallStatus: Equatable {
        case notInstalled
        case installed          // CA fingerprint matches what we last installed
        case needsRebootSuggested // installed in this session, reboot not yet performed
        case staleCA            // we installed something but CA fingerprint changed since
    }

    struct Simulator: Identifiable, Hashable {
        let udid: String
        let name: String
        let runtime: String
        var id: String { udid }
    }

    @Published private(set) var bootedSimulators: [Simulator] = []
    @Published private(set) var lastResult: String?
    /// Per-UDID install state for the current sheet session.
    @Published private(set) var statusByUDID: [String: InstallStatus] = [:]
    @Published private(set) var busyUDIDs: Set<String> = []

    /// Keys a UDID against the CA fingerprint that was last installed there.
    /// Persisted so the status survives app restarts but invalidates if the CA is regenerated.
    private let installedDefaultsKey = "PacketPeek.simulator.installedCAByUDID"
    /// UDIDs that received an install in the current app session and have not been rebooted yet.
    private var pendingRebootUDIDs: Set<String> = []

    func refresh() async throws {
        let json = try await runXcrun(args: ["simctl", "list", "-j", "devices", "booted"])
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]] else {
            self.bootedSimulators = []
            return
        }

        var out: [Simulator] = []
        for (runtime, devices) in devicesByRuntime {
            for d in devices {
                guard let udid = d["udid"] as? String,
                      let name = d["name"] as? String else { continue }
                let state = (d["state"] as? String) ?? ""
                if state.lowercased() == "booted" {
                    out.append(Simulator(udid: udid, name: name, runtime: runtime))
                }
            }
        }
        self.bootedSimulators = out.sorted { $0.name < $1.name }
        recomputeStatuses()
    }

    private func recomputeStatuses() {
        let currentFingerprint = caFingerprint()
        let installed = (UserDefaults.standard.dictionary(forKey: installedDefaultsKey) as? [String: String]) ?? [:]
        var next: [String: InstallStatus] = [:]
        for sim in bootedSimulators {
            if let stored = installed[sim.udid] {
                if currentFingerprint != nil && stored == currentFingerprint {
                    next[sim.udid] = pendingRebootUDIDs.contains(sim.udid) ? .needsRebootSuggested : .installed
                } else {
                    next[sim.udid] = .staleCA
                }
            } else {
                next[sim.udid] = .notInstalled
            }
        }
        self.statusByUDID = next
    }

    /// SHA-256 of the CA file contents. Used to invalidate the per-UDID
    /// "installed" record when the CA is regenerated (so the user is prompted
    /// to re-install instead of being told they're good).
    private func caFingerprint() -> String? {
        let url = FileManagerUrls.caCertURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.sha256Hex()
    }

    /// Installs the CA into a single simulator and records the CA fingerprint.
    func install(udid: String) async throws {
        let caURL = FileManagerUrls.caCertURL
        guard FileManager.default.fileExists(atPath: caURL.path) else {
            throw SimulatorError.caCertMissing(caURL)
        }
        busyUDIDs.insert(udid)
        defer { busyUDIDs.remove(udid) }

        _ = try await runXcrun(args: ["simctl", "keychain", udid, "add-root-cert", caURL.path])

        if let fp = caFingerprint() {
            var installed = (UserDefaults.standard.dictionary(forKey: installedDefaultsKey) as? [String: String]) ?? [:]
            installed[udid] = fp
            UserDefaults.standard.set(installed, forKey: installedDefaultsKey)
        }
        pendingRebootUDIDs.insert(udid)
        recomputeStatuses()
    }

    /// Shuts down + boots the simulator. `simctl boot` is non-blocking; we
    /// briefly poll the device list so the UI can flip back to "installed".
    func reboot(udid: String) async throws {
        busyUDIDs.insert(udid)
        defer { busyUDIDs.remove(udid) }

        _ = try? await runXcrun(args: ["simctl", "shutdown", udid])
        _ = try await runXcrun(args: ["simctl", "boot", udid])

        pendingRebootUDIDs.remove(udid)
        // Give the sim a moment to come back, then refresh the booted list.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        try? await refresh()
    }

    /// Installs the CA into every booted simulator's keychain. Idempotent —
    /// `simctl keychain add-root-cert` succeeds even if the cert is already trusted.
    func installCAInAllBooted() async throws {
        try await refresh()
        guard !bootedSimulators.isEmpty else { throw SimulatorError.noBootedSimulators }

        let caURL = FileManagerUrls.caCertURL
        guard FileManager.default.fileExists(atPath: caURL.path) else {
            throw SimulatorError.caCertMissing(caURL)
        }

        var installed: [String] = []
        for sim in bootedSimulators {
            _ = try await runXcrun(args: ["simctl", "keychain", sim.udid, "add-root-cert", caURL.path])
            installed.append("\(sim.name) [\(sim.runtime)]")
        }
        lastResult = "Trusted CA in: " + installed.joined(separator: ", ")
    }

    /// Sets the HTTP/HTTPS proxy on the booted simulators to point at the host Mac.
    /// Returns the proxy URL so the caller can show it to the user.
    func proxyAddressForLAN() -> String {
        if let ip = NetworkUtils.getLocalNetworkIPAddress() {
            return "\(ip):8080"
        }
        return "127.0.0.1:8080"
    }

    // MARK: - Process helpers

    private func runXcrun(args: [String]) async throws -> String {
        let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrunURL.path) else {
            throw SimulatorError.xcrunMissing
        }
        return try await runProcess(executable: xcrunURL, args: args)
    }

    private func runProcess(executable: URL, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { proc in
                let stdout = (try? out.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let stderr = (try? err.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    let combined = stderr.isEmpty ? stdout : stderr
                    cont.resume(throwing: SimulatorError.command(
                        ([executable.path] + args).joined(separator: " "),
                        proc.terminationStatus,
                        combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

private extension Data {
    func sha256Hex() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
