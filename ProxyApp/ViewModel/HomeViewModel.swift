//
//  HomeViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//
import Combine
import Foundation
import AppKit
final class HomeViewModel: ObservableObject {
    @Published var agents: [AgentModel] = []
    
    private var proxyCore: ProxyCore
    @Published var selectedLogID: ProxyLog.ID?
    var selectedLog: ProxyLog? {
        listBasePathRequest().first(where: { $0.id == selectedLogID })
    }
    @Published var filterPath: String?
    @Published var filterIP: String?
    
    init(proxyCore: ProxyCore) {
        self.proxyCore = proxyCore
        self.proxyCore.onNewLog = { [weak self] logs in
            DispatchQueue.main.async {
                self?.addLog(logs)
            }
        }
    }
    
    
    func ipOnEthernet() -> String? {
        return NetworkUtils.getLocalNetworkIPAddress()
    }
    
    func listBasePathRequest() -> [ProxyLog] {
        return agents.first(where: {$0.ip == filterIP})?.basePaths.first(where: {$0.basePath == filterPath})?.logs ?? []
    }
    
    func addLog(_ log: ProxyLog) {
        let ip = log.clientIP
        let basePath = URL(string: log.url)?.host ?? "unknown"
        
        // Cerca l'agent
        if let index = agents.firstIndex(where: { $0.ip.components(separatedBy: ":").first == ip.components(separatedBy: ":").first }) {
            var agent = agents[index]
            agent.ip = ip.components(separatedBy: ":").first ?? "unknown"
            
            // Cerca il base path
            if let baseIndex = agent.basePaths.firstIndex(where: { $0.basePath == basePath }) {
                agent.basePaths[baseIndex].logs.append(log)
            } else {
                // Aggiungi nuovo basePath
                agent.basePaths.append(BasePathModel(basePath: basePath, logs: [log]))
            }
            
            agents[index] = agent
        } else {
            // Nuovo agent
            let base = BasePathModel(basePath: basePath, logs: [log])
            let newAgent = AgentModel(ip: ip, basePaths: [base])
            agents.append(newAgent)
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
