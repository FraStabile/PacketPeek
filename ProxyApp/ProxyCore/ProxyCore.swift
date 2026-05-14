//
//  ProxyCore.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//

import Foundation
import Combine
import AppKit

@MainActor
final class ProxyCore: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var lastError: String?
    @Published var logs: [ProxyLog] = []

    var onNewLog: (ProxyLog) -> Void = { _ in }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case retrying(attempt: Int)
        case failed(String)
    }

    private let executableName = "proxycore"
    private var goProcess: Process?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession
    private var reconnectTask: Task<Void, Never>?
    private var receiveLoopTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    private let installer: ExecutableInstaller
    private let auth: PacketPeekAuth
    private let systemProxy = SystemProxyManager.shared

    private var execURL: URL { FileManagerUrls.executableDirectory }
    private var workingDirectory: URL { FileManagerUrls.workingDirectory }

    init(installer: ExecutableInstaller = ExecutableInstaller(),
         auth: PacketPeekAuth = .shared) {
        self.installer = installer
        self.auth = auth
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        // App quit: tear the daemon down synchronously so the user is never
        // left with a stale proxycore holding 8080 or a system proxy still
        // pointing at a dead listener.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdownSynchronously()
        }
    }

    /// Best-effort synchronous shutdown for use at app-quit time, where we
    /// cannot await async tasks. Sends SIGTERM, then SIGKILLs as a fallback,
    /// then synchronously disables the system proxy via osascript.
    private func shutdownSynchronously() {
        stopReceiveLoops()
        if let proc = goProcess, proc.isRunning {
            proc.terminate()
            // Give it ~500ms to exit gracefully, then SIGKILL if still alive.
            let deadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        // Catch any zombie proxycore we may have lost the handle to.
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                             arguments: ["-f", "proxycore"])
        systemProxy.disableSynchronously()
    }

    // MARK: - Process lifecycle

    func startDaemon() {
        guard goProcess == nil else { return }

        // Refuse to start if something else holds 8080/8081 — spawning anyway
        // would exit non-zero and leave the user wondering why the app shows
        // "running" for a moment before flipping off. Tell them explicitly.
        Task { @MainActor in
            if await self.probeHealth() {
                self.lastError = "Port 8081 is already in use. Another proxycore (or app) is running. Kill it and try again: `lsof -i tcp:8081`"
                return
            }
            self.spawnDaemonProcess()
        }
    }

    private func spawnDaemonProcess() {
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            self.lastError = "Cannot create working directory: \(error.localizedDescription)"
            return
        }

        let process = Process()
        process.executableURL = installer.execURL
        process.arguments = []
        process.currentDirectoryURL = workingDirectory

        // Mirror the daemon's stderr to our own stderr (visible in Xcode's
        // console for development). Don't pump it into `lastError`: proxycore
        // logs every intercepted request to stderr, which would otherwise
        // trigger the lastError alert on every single HTTPS connection.
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.goProcess = nil
                if proc.terminationStatus != 0 {
                    self.lastError = "proxycore exited with status \(proc.terminationStatus)"
                }
                self.stopReceiveLoops()
                await self.disableSystemProxy()
            }
        }

        do {
            try process.run()
            goProcess = process
            isRunning = true
            lastError = nil
            startHealthAndConnect()
        } catch {
            lastError = "Failed to launch proxycore: \(error.localizedDescription)"
        }
    }

    func stopDaemon() {
        stopReceiveLoops()
        goProcess?.terminate()
        goProcess = nil
        isRunning = false
        connectionState = .idle
        Task { await disableSystemProxy() }
    }

    private func enableSystemProxy() async {
        do {
            try await systemProxy.enable()
        } catch {
            self.lastError = "Could not enable system proxy: \(error.localizedDescription)"
        }
    }

    private func disableSystemProxy() async {
        do {
            try await systemProxy.disable()
        } catch {
            self.lastError = "Could not disable system proxy: \(error.localizedDescription)"
        }
    }

    // MARK: - Health probe + WebSocket reconnect

    private func startHealthAndConnect() {
        connectionState = .connecting
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            guard let self else { return }
            // Wait until /health responds (max ~10s) before attempting WS.
            let deadline = Date().addingTimeInterval(10)
            while !Task.isCancelled, Date() < deadline {
                if await self.probeHealth() {
                    await self.auth.invalidateCache()
                    await self.enableSystemProxy()
                    self.scheduleReconnect(attempt: 0)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self.connectionState = .failed("Daemon did not respond on 127.0.0.1:8081")
        }
    }

    private func probeHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8081/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func scheduleReconnect(attempt: Int) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if attempt > 0 {
                let backoff = min(pow(2.0, Double(attempt)), 30.0)
                self.connectionState = .retrying(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self.connectWebSocket(attempt: attempt)
        }
    }

    private func connectWebSocket(attempt: Int) async {
        guard isRunning else { return }
        let token = await auth.currentToken()
        var components = URLComponents(string: "ws://127.0.0.1:8081/ws")
        if let token {
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components?.url else {
            connectionState = .failed("Bad WebSocket URL")
            return
        }
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        connectionState = .connected
        await receiveLoop(task: task, attempt: attempt)
    }

    private func receiveLoop(task: URLSessionWebSocketTask, attempt: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    handleWebSocketData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        handleWebSocketData(data)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            // Drop and retry. Cap attempts implicitly via backoff (max 30s).
            if isRunning {
                scheduleReconnect(attempt: attempt + 1)
            } else {
                connectionState = .idle
            }
        }
    }

    private func handleWebSocketData(_ data: Data) {
        do {
            let log = try JSONDecoder().decode(ProxyLog.self, from: data)
            self.logs.append(log)
            self.onNewLog(log)
        } catch {
            NSLog("[PacketPeek] Failed to decode log frame: \(error.localizedDescription)")
        }
    }

    private func stopReceiveLoops() {
        reconnectTask?.cancel()
        receiveLoopTask?.cancel()
        healthTask?.cancel()
        reconnectTask = nil
        receiveLoopTask = nil
        healthTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
}
