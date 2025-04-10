//
//  ProxyCore.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//

import Foundation
import Combine

class ProxyCore: ObservableObject {
    private var goProcess: Process?
    @Published var isRunning: Bool = false
    private let executableName = "proxycore"
    private var webSocketTask: URLSessionWebSocketTask?
    private var cancellables = Set<AnyCancellable>()
    
    @Published var logs: [ProxyLog] = []
        
    // Path di installazione finale del binario
    private var execURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AstroProxy/\(executableName)")
    }
    
    // Directory di lavoro del processo (dove può scrivere file)
    private var workingDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AstroProxyRuntime")
    }
    
    init() {
        installExecutableIfNeeded()
    }
    
    // MARK: - Installazione Binario
    
    private func installExecutableIfNeeded() {
        let fileManager = FileManager.default
        
        guard !isExecutableInstalled(at: execURL) else { return }
        
        guard let sourceURL = Bundle.main.resourceURL?.appendingPathComponent(executableName) else {
            print("⚠️ Binario non trovato nel bundle.")
            return
        }
        
        do {
            try fileManager.createDirectory(at: execURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: execURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
            print("✅ Binario installato con successo.")
        } catch {
            print("❌ Errore durante l'installazione del binario:", error)
        }
    }
    
    private func isExecutableInstalled(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
    
    // MARK: - Start / Stop del processo
    
    func startDaemon() {
        let process = Process()
        process.executableURL = execURL
        process.arguments = [] // Aggiungi argomenti se necessari
        
        // Imposta working directory scrivibile
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            print("❌ Impossibile creare working directory:", error)
            return
        }
        process.currentDirectoryURL = workingDirectory
        
        
        // Termination handler
        process.terminationHandler = { [weak self] proc in
            print("ℹ️ proxycore terminato con codice: \(proc.terminationStatus)")
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.goProcess = nil
            }
        }
        
        do {
            try process.run()
            goProcess = process
            isRunning = true
            connectWebSocket()
            print("🚀 Processo proxycore avviato con PID \(process.processIdentifier)")
        } catch {
            print("❌ Errore avviando proxycore:", error)
        }
    }
    
    func stopDaemon() {
        goProcess?.terminate()
        isRunning = false
        goProcess = nil
        disconnectWebSocket()
        print("🛑 proxycore arrestato.")
    }
    
    
    func connectWebSocket(retries: Int = 5) {
        guard retries > 0 else {
            print("❌ Raggiunto il numero massimo di tentativi per la connessione WebSocket.")
            return
        }
        
        guard let url = URL(string: "ws://localhost:8081/ws") else {
            print("❌ URL WebSocket non valido")
            return
        }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        
        webSocketTask?.resume()
        print("🔌 Tentativo di connessione WebSocket...")
        
        // Aggiungi un piccolo ritardo tra i tentativi
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.webSocketTask?.state != .running {
                print("❌ Tentativo di connessione WebSocket fallito. Riprovo...")
                self?.connectWebSocket(retries: retries - 1)
            } else {
                print("🔌 WebSocket connessa")
                self?.receiveWebSocketMessages()
            }
        }
    }
    
    func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        print("🔌 WebSocket disconnessa")
    }
    
    private func receiveWebSocketMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("❌ Errore WebSocket:", error)
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.handleWebSocketData(data)
                case .string(let text):
                    guard let data = text.data(using: .utf8) else { return }
                    self?.handleWebSocketData(data)
                @unknown default:
                    print("❓ Messaggio WebSocket sconosciuto")
                }
            }
            
            // Continuiamo ad ascoltare
            self?.receiveWebSocketMessages()
        }
    }
    
    private func handleWebSocketData(_ data: Data) {
        do {
            let log = try JSONDecoder().decode(ProxyLog.self, from: data)
            DispatchQueue.main.async {
                self.logs.append(log)
                print(self.logs.count)
            }
        } catch {
            print("❌ Errore parsing log:", error)
        }
    }
}
