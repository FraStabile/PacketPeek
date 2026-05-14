//
//  BonjourBrowser.swift
//  ProxyApp
//
//  Discovers iOS-class devices on the LAN via `_apple-mobdev2._tcp` and
//  `_companion-link._tcp` and exposes a dictionary [ipv4: humanName] for the
//  sidebar to enrich device labels. Pure best-effort: anything that fails or
//  times out is silently dropped — the sidebar still works without it.
//

import Foundation
import Network
import Combine

@MainActor
final class BonjourBrowser: ObservableObject {
    @Published private(set) var namesByIP: [String: String] = [:]

    private var browsers: [NWBrowser] = []
    private let types = [
        "_apple-mobdev2._tcp",
        "_companion-link._tcp",
        "_rdlink._tcp"
    ]

    func start() {
        guard browsers.isEmpty else { return }
        for type in types {
            startBrowser(for: type)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    // MARK: - Private

    private func startBrowser(for type: String) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                Task { @MainActor in self.resolve(result) }
            }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }

        let conn = NWConnection(to: result.endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let ip = Self.extractIPv4(from: conn.currentPath?.remoteEndpoint) {
                    Task { @MainActor in
                        self?.namesByIP[ip] = Self.prettify(name)
                    }
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        // Keep connections short-lived: we only need the resolved IP, not a
        // real channel. Cap at 3s.
        conn.start(queue: .main)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            conn.cancel()
        }
    }

    nonisolated private static func extractIPv4(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .name(let name, _):
            return name
        default:
            return nil
        }
    }

    /// "Francesco\\032s\\032iPhone" → "Francesco's iPhone".
    private static func prettify(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\032", with: " ")
           .replacingOccurrences(of: "\\.", with: ".")
    }
}
