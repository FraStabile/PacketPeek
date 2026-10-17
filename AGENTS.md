# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

**PacketPeek** is a macOS MITM proxy for inspecting and mocking HTTP/HTTPS traffic. It has two tiers:
- **ProxyApp** — SwiftUI macOS app (frontend)
- **ProxyCore** — Go daemon (proxy server + REST/WebSocket API)

## Build Commands

### ProxyCore (Go backend)
```bash
cd ProxyCore/
go build -o proxycore .       # build binary
go test ./...                  # run tests
```

### ProxyApp (Swift/Xcode)
```bash
xcodebuild -scheme ProxyApp -configuration Debug build
xcodebuild test -scheme ProxyApp -destination 'platform=macOS'
```

## Architecture

### Communication Model
- **Proxy port**: 8080 — intercepts HTTP/HTTPS traffic from configured devices
- **API port**: 8081 — REST + WebSocket served by ProxyCore, consumed by ProxyApp
- **ProxyApp → ProxyCore**: REST calls via `NetworkLayer/MocksAPI.swift` (Papyrus)
- **ProxyCore → ProxyApp**: WebSocket push at `ws://localhost:8081/ws` (live log stream)

### ProxyCore internals (Go)
`main.go` manages the daemon lifecycle: PID file at `/tmp/packetpeek.pid`, idle timeout after 5 min, SIGINT/SIGTERM handling.

Key packages:
- `proxy/proxy.go` — core MITM: hijacks CONNECT for HTTPS, forwards HTTP, logs to a 1,000-entry ring buffer, notifies WebSocket subscribers
- `proxy/mock_manager.go` — intercepts requests before forwarding; matches by method + host + path (exact or regex); persists to `mocks.json`
- `cert/manager.go` — generates a root CA (`ca.pem`/`ca.key`) and per-host TLS certs on the fly (SNI-aware)
- `api/server.go` — REST endpoints for logs, apps, mocks, cert download + WebSocket upgrade

### ProxyApp internals (Swift)
`ProxyAppApp.swift` owns top-level StateObjects. `ContentView.swift` is a `NavigationSplitView`: sidebar groups traffic by IP/domain; detail pane shows filterable request table + selected log detail.

`HomeViewModel.swift` owns the hierarchy: **AgentModel (IP) → BasePathModel (domain) → [ProxyLog]**. It consumes the WebSocket stream and re-publishes via Combine.

`ProxyCore/ProxyManager.swift` controls the daemon via `launchctl load/unload` and tests connectivity by opening a TCP socket to `localhost:8080`.

`Utils/ExecutableInstaller.swift` extracts the embedded `proxycore` binary from the app bundle and installs it to `~/Library/Application Support/ProxyApp/`.

Dependency injection uses **SwiftDependency** (service locator) registered in `Utils/DependecyManager.swift`.

## Ports & Persistence

| Resource | Value |
|---|---|
| Proxy port | 8080 |
| API/WS port | 8081 |
| PID file | `/tmp/packetpeek.pid` |
| LaunchAgent label | `com.proxyapp.proxycore` |
| Mock rules | `ProxyCore/mocks.json` |
| Monitored apps | `ProxyCore/monitored_apps.json` |
| Root CA | `ProxyCore/ca.pem` + `ca.key` |
| Daemon logs | `ProxyCore/proxy.out.log` / `proxy.err.log` |

## Key Design Decisions

- The Go binary is **embedded in the app bundle** at build time and extracted on first run — changes to ProxyCore must be recompiled and the binary replaced in the bundle.
- HTTPS interception works by **TCP hijacking at the CONNECT request**; a dynamic cert is signed by the bundled CA. Clients must trust the CA cert (downloadable from `http://<mac-ip>:8081/welcome`).
- Mock matching runs **before** forwarding: if `MockManager.Match()` returns a result, the response is synthesized locally and the real request is never sent.
- The daemon auto-exits after 5 minutes of no traffic; ProxyApp restarts it on demand via `launchctl`.
