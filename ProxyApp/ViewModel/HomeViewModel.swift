//
//  HomeViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//
import Combine
import Foundation
import AppKit
import SwiftDependency
final class HomeViewModel: BaseViewModel {
    @Published var agents: [AgentModel] = []

    /// New tree-shaped sidebar data. Rebuilt every time logs or bonjour names change.
    @Published var sidebarTree: [SidebarItem] = []

    /// Selection on the new tree sidebar. Drives `filteredLogs`.
    @Published var selectedSidebarItem: SidebarItem?

    /// Authorized apps cached locally so the sidebar lock toggle can read the
    /// current "intercept on/off" state without a round-trip per row.
    @Published var authorizedApps: [AuthorizedApp] = []

    /// Memoized result of filtering `allLogs` by the current sidebar selection.
    /// Recomputed only when `agents` or `selectedSidebarItem` actually change —
    /// NOT on every `selectedLogID` change (which would cause the click-freeze).
    @Published private(set) var filteredLogs: [ProxyLog] = []

    /// Memoized log lookup. Same reasoning as `filteredLogs`: do not iterate
    /// every time the view body recomputes.
    @Published private(set) var selectedLog: ProxyLog?

    private var proxyCore: ProxyCore
    @Published var selectedLogID: ProxyLog.ID?
    @Published var filterPath: String?
    @Published var filterIP: String?

    @InjectProps private var repo: MocksAPI

    private let bonjour = BonjourBrowser()
    private var cancellables = Set<AnyCancellable>()

    /// Pending logs accumulated between flush ticks. The proxy daemon can fire
    /// dozens of WebSocket frames per second; mutating `agents` for each one
    /// fans out a willChange and rebuilds Combine downstream over and over.
    /// We buffer + flush on a single run-loop tick instead.
    private var pendingLogs: [ProxyLog] = []
    private var flushScheduled: Bool = false

    /// Cache of inferred AppIdentity key per log id. AppIdentity.infer is cheap
    /// thanks to regex caching, but it still allocates and tokenises the UA on
    /// each call. Filter passes touch every log, so we look up here first.
    private var appKeyByLogID: [UUID: String] = [:]

    private func appKey(for log: ProxyLog) -> String {
        if let cached = appKeyByLogID[log.id] { return cached }
        let key = AppIdentity.infer(from: log).key
        appKeyByLogID[log.id] = key
        return key
    }

    init(proxyCore: ProxyCore) {
        self.proxyCore = proxyCore
        self.proxyCore.onNewLog = { [weak self] log in
            DispatchQueue.main.async {
                self?.queueLog(log)
            }
        }

        // Rebuild the tree on log/bonjour changes — but debounce so a burst
        // of incoming logs (very common when a sim is polling) collapses into
        // a single O(N) rebuild every ~250ms instead of once per log.
        Publishers.CombineLatest($agents, bonjour.$namesByIP)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, bonjourNames in
                guard let self else { return }
                self.sidebarTree = SidebarTreeBuilder.build(
                    from: self.allLogs,
                    bonjourNames: bonjourNames
                )
            }
            .store(in: &cancellables)

        // Same idea for the filtered logs feeding the table. Selection
        // changes apply immediately (no debounce on the selection branch);
        // it's only the `agents` torrent that we coalesce.
        let throttledAgents = $agents.debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        Publishers.CombineLatest(throttledAgents, $selectedSidebarItem)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.filteredLogs = self.computeFilteredLogs()
            }
            .store(in: &cancellables)

        // Selected log lookup. Two triggers: filteredLogs replaced, or user
        // clicked a different row. Both are infrequent enough to not need a
        // debounce.
        Publishers.CombineLatest($filteredLogs, $selectedLogID)
            .sink { [weak self] logs, id in
                guard let self else { return }
                self.selectedLog = id.flatMap { wanted in logs.first { $0.id == wanted } }
            }
            .store(in: &cancellables)

        bonjour.start()

        Task { await self.refreshAuthorizedApps() }
    }

    deinit {
        // Bonjour browsers are released along with the VM; explicit stop is
        // omitted because deinit runs on an arbitrary actor and BonjourBrowser
        // is @MainActor. NWBrowser cleans itself up on dealloc.
    }

    // MARK: - Sidebar selection → log filtering

    /// Flat list of all logs (one source of truth for the table when a sidebar
    /// item is selected). Built from the per-agent ring buffer.
    var allLogs: [ProxyLog] {
        agents.flatMap { agent in
            agent.basePaths.flatMap { $0.logs }
        }
    }

    /// Logs filtered by whatever is selected in the sidebar tree.
    /// Device → all of its logs. App → app-only. Domain → app + host.
    /// App matching uses the inferred AppIdentity.key so UA-derived buckets
    /// (apps without a real bundle id) work identically to bundle-id buckets.
    private func computeFilteredLogs() -> [ProxyLog] {
        guard let item = selectedSidebarItem else { return allLogs }
        let appKey: String? = {
            guard item.kind == .app || item.kind == .domain else { return nil }
            let comps = item.id.components(separatedBy: "::")
            return comps.count >= 3 ? comps[2] : nil
        }()

        return allLogs.filter { log in
            if let ip = item.clientIPRoot,
               (log.clientIP.components(separatedBy: ":").first ?? log.clientIP) != ip {
                return false
            }
            if item.kind == .device { return true }
            let logKey = self.appKey(for: log)
            if let appKey, appKey != "__generic__" {
                if logKey != appKey { return false }
            } else {
                if !logKey.isEmpty { return false }
            }
            if item.kind == .app { return true }
            return URL(string: log.url)?.host == item.domain
        }
    }

    // MARK: - HTTPS interception toggle

    @MainActor
    func setIntercept(bundleID: String, name: String, on: Bool) async {
        do {
            try await repo.setApps(AuthorizedApp(bundle_id: bundleID, name: name, decrypt_traffic: on))
            await refreshAuthorizedApps()
        } catch {
            print("[HomeViewModel] setIntercept failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func refreshAuthorizedApps() async {
        do {
            self.authorizedApps = try await repo.getApps()
        } catch {
            // Daemon might be down — just keep whatever we had.
        }
    }

    func interceptState(for bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return authorizedApps.first { $0.bundle_id == bundleID }?.decrypt_traffic ?? false
    }
    
    
    /// Cache for the LAN IP. `getifaddrs` is cheap-ish but the SwiftUI toolbar
    /// asks for it on every body recomputation, which adds up. We refresh
    /// lazily once per minute — the interface IP doesn't change faster than
    /// that in any realistic scenario.
    private var cachedLocalIP: String?
    private var cachedLocalIPAt: Date?

    func ipOnEthernet() -> String? {
        if let cachedLocalIP, let at = cachedLocalIPAt,
           Date().timeIntervalSince(at) < 60 {
            return cachedLocalIP
        }
        let ip = NetworkUtils.getLocalNetworkIPAddress()
        cachedLocalIP = ip
        cachedLocalIPAt = Date()
        return ip
    }
    
    func listBasePathRequest() -> [ProxyLog] {
        return agents.first(where: {$0.ip == filterIP})?.basePaths.first(where: {$0.basePath == filterPath})?.logs ?? []
    }
    
    /// Public entry point — kept for source compatibility but routes through
    /// the batch queue so each call no longer hits the published `agents`
    /// array directly.
    func addLog(_ log: ProxyLog) {
        queueLog(log)
    }

    /// Buffer a log and schedule a single flush on the next run-loop tick.
    /// This collapses a burst of incoming frames into one mutation of
    /// `agents`, which is by far the dominant CPU cost when traffic is heavy.
    private func queueLog(_ log: ProxyLog) {
        pendingLogs.append(log)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingLogs()
        }
    }

    private func flushPendingLogs() {
        flushScheduled = false
        let batch = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }

        // Mutate a local copy of `agents`, then assign back once. This emits
        // a single `objectWillChange` instead of one per log.
        var working = agents
        for log in batch {
            insert(log: log, into: &working)
        }
        agents = working
    }

    private func insert(log: ProxyLog, into agents: inout [AgentModel]) {
        let ipRoot = log.clientIP.components(separatedBy: ":").first ?? log.clientIP
        let basePath = URL(string: log.url)?.host ?? "unknown"

        if let index = agents.firstIndex(where: {
            ($0.ip.components(separatedBy: ":").first ?? $0.ip) == ipRoot
        }) {
            agents[index].ip = ipRoot
            if let baseIndex = agents[index].basePaths.firstIndex(where: { $0.basePath == basePath }) {
                agents[index].basePaths[baseIndex].logs.append(log)
            } else {
                agents[index].basePaths.append(BasePathModel(basePath: basePath, logs: [log]))
            }
        } else {
            agents.append(
                AgentModel(ip: ipRoot, basePaths: [BasePathModel(basePath: basePath, logs: [log])])
            )
        }
    }
    
    func exportRequestToTxt(request: ProxyLog) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        let exportText = """
            📦 HTTP Transaction Export
            ============================
            
            📬 REQUEST
            ----------------------------
            🕒 Timestamp: \(formatter.string(from: request.timestamp))
            🔗 URL: \(request.url)
            📬 Method: \(request.method)
            📱 User-Agent: \(request.userAgent ?? "N/A")
            
            🧾 Headers:
            \(request.requestHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            
            📝 Body:
            \(request.requestBody ?? "<empty>")
            
            
            📥 RESPONSE
            ----------------------------
            📡 Status: \(request.statusCode)
            ⏱ Duration: \(String(format: "%.2f", request.responseTime * 1000)) ms
            🧾 Headers:
            \(request.responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            
            📝 Body:
            \(request.responseBody ?? "<empty>")
            """
        
        let panel = NSSavePanel()
        panel.title = "Export HTTP Transaction"
        panel.nameFieldStringValue = "request_export.txt"
        panel.allowedFileTypes = ["txt"]
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Errore durante l’esportazione: \(error)")
            }
        }
    }
}

struct AgentModel: Identifiable, Hashable {
    let id = UUID()
    var ip: String
    var basePaths: [BasePathModel]
}

struct BasePathModel: Identifiable, Hashable {
    let id = UUID()
    let basePath: String
    var logs: [ProxyLog]
    
    static func == (lhs: BasePathModel, rhs: BasePathModel) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        
    }
}
