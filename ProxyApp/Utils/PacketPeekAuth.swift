//
//  PacketPeekAuth.swift
//  ProxyApp
//
//  Reads the bearer token produced by the Go daemon on startup. The token file
//  lives at FileManagerUrls.apiTokenURL with 0600 permissions; we cache it in
//  memory and reload when invalidateCache() is called (e.g. after a daemon
//  restart). The Go API always requires it on /logs, /ws and /api/* (only
//  /health, /welcome and /cert/* are public). MainProvider attaches it to
//  every Papyrus request; ProxyCore attaches it to the WebSocket handshake.
//

import Foundation

actor PacketPeekAuth {
    static let shared = PacketPeekAuth()

    private var cached: String?
    private var cachedAt: Date?
    private let ttl: TimeInterval = 5

    private init() {}

    func currentToken() -> String? {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        return reloadFromDisk()
    }

    func invalidateCache() {
        cached = nil
        cachedAt = nil
    }

    @discardableResult
    private func reloadFromDisk() -> String? {
        let url = FileManagerUrls.apiTokenURL
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            cached = nil
            cachedAt = Date()
            return nil
        }
        cached = token
        cachedAt = Date()
        return token
    }
}
