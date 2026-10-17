# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**PacketPeek** is a macOS MITM proxy for inspecting and mocking HTTP/HTTPS traffic. It has two tiers:
- **ProxyApp** — SwiftUI macOS app (frontend, Xcode target `PacketPeek`, scheme `ProxyApp`)
- **ProxyCore** — Go daemon (proxy server + REST/WebSocket API)

## Build Commands

### ProxyCore (Go backend)
```bash
cd ProxyCore/
go build -o proxycore .       # build binary
go test ./...                  # run tests (add -race when touching proxy.go)
go test ./proxy -run TestName  # single test (tests live next to code in proxy/, api/, main_test.go)
```

`ProxyCore/` also holds local runtime leftovers (`ca.key`, `ca.pem`, `mocks.json`, `*.log`, `proxycore`) — not source; don't edit or commit them.

### ProxyApp (Swift/Xcode)
```bash
xcodebuild -scheme ProxyApp -configuration Debug build
xcodebuild test -scheme ProxyApp -destination 'platform=macOS'
xcodebuild test -scheme ProxyApp -destination 'platform=macOS' -only-testing:ProxyAppTests/<Class>/<method>  # single test
```

`AGENTS.md` (Codex) is an older, partly stale copy of this file (e.g. `/tmp` PID file, `localhost` API) — this file is the source of truth.

The Xcode build phase **"Build proxycore (Go)"** recompiles the daemon from `ProxyCore/` on every build and writes it to `ProxyApp/ProxyCore/proxycore`, which is copied into the app bundle. That binary is a build artifact (gitignored) — never edit or commit it.

## Architecture

### Communication Model
- **Proxy port**: `:8080` on all interfaces — intercepts HTTP/HTTPS from this Mac and LAN devices
- **API port**: `127.0.0.1:8081` (loopback only) — REST + WebSocket consumed by ProxyApp
- **ProxyApp → ProxyCore**: REST via `NetworkLayer/MocksAPI.swift` (Papyrus), provider built in `NetworkLayer/MainProvider.swift`
- **ProxyCore → ProxyApp**: WebSocket push at `ws://127.0.0.1:8081/ws` (live log stream)

### Daemon lifecycle (real flow)
1. On launch `Utils/ExecutableInstaller.swift` copies the bundled `proxycore` to `~/Library/Application Support/PacketPeek/proxycore` when its SHA-256 differs.
2. `ProxyCore/ProxyCore.swift` (`@MainActor ObservableObject`) starts it as a **child `Process`** (no launchctl/LaunchAgent), working dir = runtime dir. It probes `GET /health`, then enables the macOS system proxy (`Utils/SystemProxyManager.swift`) and connects the WebSocket with exponential-backoff reconnect.
3. `stopDaemon()` / app quit: SIGTERM (SIGKILL fallback at quit), system proxy disabled.
4. **Idle shutdown**: `main.go` exits after 5 min with no proxy traffic, no in-flight requests/tunnels **and no connected WebSocket client** (i.e. it never idles out while the UI is attached). Idle exit uses **exit code 3** (`exitCodeIdle`); `ProxyCore.swift`'s `terminationHandler` maps that to `ConnectionState.stoppedIdle` ("Stopped (idle)" banner + pill) and disables the system proxy so the Mac doesn't lose network. Any other non-zero exit is surfaced as `lastError`.
5. `main.go` funnels SIGINT/SIGTERM, idle, and listener errors into `waitForShutdown()`, then shuts servers down, removes the PID file and `os.Exit`s.

### ProxyCore internals (Go)
- `main.go` — lifecycle above; writes PID file and a fresh API token on every start.
- `proxy/proxy.go` — core MITM: hijacks CONNECT for HTTPS, forwards HTTP, 1,000-entry in-memory log, notifies WS subscribers. Bodies are **streamed** in both directions; only the first 1 MiB per body is kept for the log (`proxy/body_capture.go`). Upstream uses `Transport.RoundTrip` (no total timeout, no redirect following).
- `proxy/target_guard.go` — SSRF guard: refuses loopback / `localhost` / this Mac's IPs on 8080/8081, both up-front (403) and at dial time on the resolved IP.
- `proxy/mock_manager.go` — mock rules, checked **before** forwarding. Match = method + hostname (port ignored, case-insensitive) + path. Exact rules compare `URL.Path` (query ignored); regex rules run on `RequestURI()` (path+query). `AddMock` upserts by id, then by method+host+path. Persisted atomically to `mocks.json`.
- `cert/manager.go` — root CA (`ca.pem`/`ca.key`) + per-host leaf certs on the fly (SNI-aware).
- `api/server.go` — REST (logs, apps, mocks), cert download, WS upgrade. Middleware: Host header must be `127.0.0.1|localhost|::1:8081` (anti DNS rebinding), Origin must be absent or exactly loopback, POST/PUT/PATCH require `application/json`, and **bearer token always required** on `/logs`, `/ws`, `/api/*` (`/health`, `/welcome`, `/cert/*` are public).

### ProxyApp internals (Swift)
`ProxyAppApp.swift` owns top-level StateObjects. `ContentView.swift` is a `NavigationSplitView`: sidebar groups traffic by IP/domain; detail pane shows a connection banner, filterable request table and selected log detail.

`HomeViewModel.swift` owns the hierarchy **AgentModel (IP) → BasePathModel (domain) → [ProxyLog]**, fed by `ProxyCore.onNewLog`.

`Utils/PacketPeekAuth.swift` reads the API token from the runtime dir (5 s cache); `MainProvider` attaches it to every Papyrus request and retries once on 401 (token rotates on daemon restart).

Dependency injection uses **SwiftDependency** (service locator) registered in `Utils/DependecyManager.swift`.

## Ports & Persistence

Runtime dir = `~/Library/Application Support/PacketPeekRuntime/` (`FileManagerUrls.workingDirectory`).

| Resource | Value |
|---|---|
| Proxy port | 8080 (all interfaces) |
| API/WS port | 8081 (127.0.0.1 only) |
| Daemon binary | `~/Library/Application Support/PacketPeek/proxycore` |
| PID file | `<runtime>/packetpeek.pid` |
| API token | `<runtime>/api.token` (0600, regenerated each start) |
| Mock rules | `<runtime>/mocks.json` |
| Monitored apps | `<runtime>/monitored_apps.json` |
| App settings | `<runtime>/settings.json` |
| Root CA | `<runtime>/ca.pem` + `ca.key` — never commit, never delete casually (devices trust it) |
| Daemon logs | stderr, mirrored to Xcode's console by `ProxyCore.swift` |

Calling the API by hand:
```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/PacketPeekRuntime/api.token)" http://127.0.0.1:8081/api/mocks
```

## Key Design Decisions

- HTTPS interception works by **TCP hijacking at the CONNECT request**; a dynamic cert is signed by the local CA. Clients must trust the CA: LAN devices open `http://<mac-ip>:8080/welcome` (served by the proxy port; the API is loopback-only).
- Mock matching runs **before** forwarding: if `MockManager.Match()` hits, the response is synthesized locally (with `latency_ms`), the real request is never sent, and the log entry has `mocked: true`.
- `response_time_ms` in `RequestLog` is fractional milliseconds (`proxy.Milliseconds`), not a `time.Duration`.
- Because the proxy is LAN-reachable, anything that lets a proxied request reach `127.0.0.1` is a security bug — keep `target_guard.go` in the path for new forwarding code.
