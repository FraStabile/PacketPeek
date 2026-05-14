//
//  SystemProxyManager.swift
//  ProxyApp
//
//  Drives macOS system-wide HTTP/HTTPS proxy on all active network services so
//  that the iOS Simulator (which inherits the host's network settings) routes
//  through PacketPeek without any per-device configuration.
//
//  Privilege model: `networksetup -setwebproxy*` needs root. We shell out via
//  `osascript ... with administrator privileges`, which shows the standard
//  macOS auth dialog once and caches the right for ~5 minutes — subsequent
//  toggles within that window are silent. We batch all mutations into one
//  AppleScript invocation so the user sees a single prompt per session.
//
//  Crash safety: each time we enable, we persist the list of services we
//  touched in UserDefaults. On the next launch, ProxyCore disables them if
//  the daemon is not actually running anymore.
//

import Foundation

@MainActor
final class SystemProxyManager {
    static let shared = SystemProxyManager()

    private let host = "127.0.0.1"
    private let port = 8080
    private let defaultsKey = "PacketPeek.systemProxy.enabledServices"

    private(set) var isEnabled: Bool = false

    /// Enables HTTP + HTTPS proxy on every active network service.
    /// Triggers a single admin password prompt (cached by macOS afterwards).
    func enable() async throws {
        let services = try activeNetworkServices()
        guard !services.isEmpty else { return }

        var lines: [String] = []
        for svc in services {
            let q = svc.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("/usr/sbin/networksetup -setwebproxy \"\(q)\" \(host) \(port)")
            lines.append("/usr/sbin/networksetup -setsecurewebproxy \"\(q)\" \(host) \(port)")
            lines.append("/usr/sbin/networksetup -setwebproxystate \"\(q)\" on")
            lines.append("/usr/sbin/networksetup -setsecurewebproxystate \"\(q)\" on")
        }
        try await runAsAdmin(shell: lines.joined(separator: " && "))
        UserDefaults.standard.set(services, forKey: defaultsKey)
        isEnabled = true
    }

    /// Disables HTTP + HTTPS proxy on the services we previously enabled (or
    /// all currently active ones if we have no record).
    func disable() async throws {
        let services = UserDefaults.standard.stringArray(forKey: defaultsKey)
            ?? (try? activeNetworkServices())
            ?? []
        guard !services.isEmpty else {
            isEnabled = false
            return
        }

        var lines: [String] = []
        for svc in services {
            let q = svc.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("/usr/sbin/networksetup -setwebproxystate \"\(q)\" off")
            lines.append("/usr/sbin/networksetup -setsecurewebproxystate \"\(q)\" off")
        }
        try await runAsAdmin(shell: lines.joined(separator: " ; "))
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        isEnabled = false
    }

    /// Called at app launch: if a previous session left proxy ON but the
    /// daemon is not running, clear it so the user isn't stranded offline.
    func cleanupStaleStateIfNeeded() async {
        guard UserDefaults.standard.stringArray(forKey: defaultsKey) != nil else { return }
        try? await disable()
    }

    /// Synchronous variant for app-quit, where we cannot await. Builds the
    /// same osascript and runs it via `Process.waitUntilExit()`.
    func disableSynchronously() {
        let services = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !services.isEmpty else {
            isEnabled = false
            return
        }
        var lines: [String] = []
        for svc in services {
            let q = svc.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("/usr/sbin/networksetup -setwebproxystate \"\(q)\" off")
            lines.append("/usr/sbin/networksetup -setsecurewebproxystate \"\(q)\" off")
        }
        let shell = lines.joined(separator: " ; ")
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        isEnabled = false
    }

    // MARK: - Helpers

    private func activeNetworkServices() throws -> [String] {
        // `networksetup -listnetworkserviceorder` lists services with their
        // hardware port + device. A service whose device is empty or whose
        // line is prefixed with "*" (disabled) must be skipped.
        let output = try runSync(executable: "/usr/sbin/networksetup",
                                 args: ["-listnetworkserviceorder"])
        var services: [String] = []
        let lines = output.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Service header looks like: "(1) Wi-Fi"  — disabled ones start with "(*)".
            if let range = line.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
                let name = String(line[range.upperBound...])
                // Next line is "(Hardware Port: ..., Device: enX)" — require Device non-empty.
                let detail = i + 1 < lines.count ? lines[i + 1] : ""
                if detail.contains("Device:"),
                   let dev = detail.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " )")),
                   !dev.isEmpty {
                    services.append(name)
                }
                i += 2
            } else {
                i += 1
            }
        }
        return services
    }

    private func runAsAdmin(shell: String) async throws {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        _ = try await runProcess(executable: "/usr/bin/osascript", args: ["-e", script])
    }

    private func runSync(executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SystemProxyManager", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: out])
        }
        return out
    }

    private func runProcess(executable: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
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
                    cont.resume(throwing: NSError(
                        domain: "SystemProxyManager",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: combined.trimmingCharacters(in: .whitespacesAndNewlines)]
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
