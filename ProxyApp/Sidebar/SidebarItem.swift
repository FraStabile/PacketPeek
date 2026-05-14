//
//  SidebarItem.swift
//  ProxyApp
//
//  Tree model for the new three-level sidebar: Device → App → Domain.
//
//  The tree is derived deterministically from the flat list of ProxyLog
//  entries. We avoid mutating across the layers — a fresh tree is rebuilt
//  whenever logs change so selection + filtering can rely on identity.
//

import Foundation

enum SidebarKind: Hashable {
    case device
    case app
    case domain
}

struct SidebarItem: Identifiable, Hashable {
    /// Stable identity:
    ///  - device:  "device::<clientIPRoot>"
    ///  - app:     "app::<clientIPRoot>::<bundleID>"
    ///  - domain:  "domain::<clientIPRoot>::<bundleID>::<host>"
    let id: String
    let kind: SidebarKind
    let title: String
    let subtitle: String?

    // Routing values used to filter the log table.
    let clientIPRoot: String?   // populated for device / app / domain
    let bundleID: String?       // populated for app / domain. nil ⇒ "Generic"
    let domain: String?         // populated for domain

    // L1 device-specific
    let deviceKind: DeviceFingerprint.Kind?

    // L3 domain-specific
    let lastSeen: Date?
    let lastStatusCode: Int?
    let logCount: Int

    var children: [SidebarItem]?

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Tree builder

enum SidebarTreeBuilder {

    /// Builds the Device → App → Domain tree from a flat array of logs.
    /// Device names are inferred from User-Agent via `DeviceFingerprint`
    /// and optionally enriched by Bonjour-discovered names keyed on IP.
    static func build(
        from logs: [ProxyLog],
        bonjourNames: [String: String] = [:]
    ) -> [SidebarItem] {

        // Group by client-IP root first (strip the ":port" the daemon attaches).
        let byClient = Dictionary(grouping: logs) { log in
            log.clientIP.components(separatedBy: ":").first ?? log.clientIP
        }

        var devices: [SidebarItem] = []

        for (ipRoot, deviceLogs) in byClient {
            let fingerprint = DeviceFingerprint.infer(
                from: deviceLogs,
                ipRoot: ipRoot,
                bonjourName: bonjourNames[ipRoot]
            )

            // L2 — group by inferred AppIdentity. UA-derived names (e.g. "MyApp"
            // from "MyApp/1.2.3 CFNetwork/…") become first-class buckets even
            // when no real bundle id is available.
            let byApp = Dictionary(grouping: deviceLogs) { AppIdentity.infer(from: $0).key }

            var appNodes: [SidebarItem] = []
            for (appKey, appLogs) in byApp {
                // Take the identity from the first log in the bucket — they all
                // hash to the same key by construction.
                let identity = appLogs.first.map { AppIdentity.infer(from: $0) } ?? .generic

                // L3 — domains.
                let byDomain = Dictionary(grouping: appLogs) { log -> String in
                    URL(string: log.url)?.host ?? "unknown"
                }
                let domainNodes: [SidebarItem] = byDomain
                    .map { host, logsForHost -> SidebarItem in
                        let sorted = logsForHost.sorted { $0.timestamp > $1.timestamp }
                        let latest = sorted.first
                        return SidebarItem(
                            id: "domain::\(ipRoot)::\(appKey)::\(host)",
                            kind: .domain,
                            title: host,
                            subtitle: nil,
                            clientIPRoot: ipRoot,
                            bundleID: identity.bundleID,
                            domain: host,
                            deviceKind: nil,
                            lastSeen: latest?.timestamp,
                            lastStatusCode: latest?.statusCode,
                            logCount: logsForHost.count,
                            children: nil
                        )
                    }
                    .sorted { $0.title < $1.title }

                let appNode = SidebarItem(
                    id: "app::\(ipRoot)::\(appKey.isEmpty ? "__generic__" : appKey)",
                    kind: .app,
                    title: identity.title,
                    subtitle: identity.bundleID,
                    clientIPRoot: ipRoot,
                    bundleID: identity.bundleID,
                    domain: nil,
                    deviceKind: nil,
                    lastSeen: nil,
                    lastStatusCode: nil,
                    logCount: appLogs.count,
                    children: domainNodes
                )
                appNodes.append(appNode)
            }
            // Sort: real bundle ids first (alphabetic), then UA-derived, then Generic.
            appNodes.sort { lhs, rhs in
                func rank(_ item: SidebarItem) -> Int {
                    if item.bundleID != nil { return 0 }
                    if item.title == "Generic / Unknown" { return 2 }
                    return 1
                }
                let lr = rank(lhs), rr = rank(rhs)
                if lr != rr { return lr < rr }
                return lhs.title < rhs.title
            }

            let device = SidebarItem(
                id: "device::\(ipRoot)",
                kind: .device,
                title: fingerprint.displayName,
                subtitle: ipRoot,
                clientIPRoot: ipRoot,
                bundleID: nil,
                domain: nil,
                deviceKind: fingerprint.kind,
                lastSeen: nil,
                lastStatusCode: nil,
                logCount: deviceLogs.count,
                children: appNodes
            )
            devices.append(device)
        }

        return devices.sorted { $0.title < $1.title }
    }

    /// Strips reverse-DNS to a humanish name. `com.apple.Maps` ⇒ "Maps".
    /// Used only when we have no NSWorkspace metadata (remote devices, sim).
    private static func friendlyAppName(for bundleID: String) -> String {
        let last = bundleID.components(separatedBy: ".").last ?? bundleID
        return last
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .prefix(1).uppercased() + last.dropFirst()
    }
}
