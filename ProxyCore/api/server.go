package api

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"proxy_core/proxy"

	"github.com/gorilla/websocket"
)

const (
	maxJSONBody    = 4 << 20 // 4 MiB cap for control-plane POST bodies
	wsPingPeriod   = 30 * time.Second
	wsReadDeadline = 90 * time.Second
)

type APIServer struct {
	proxyServer *proxy.ProxyServer
	upgrader    websocket.Upgrader
	clients     map[*websocket.Conn]struct{}
	mu          sync.Mutex
	token       string
	runtimeDir  string
}

// NewAPIServer wires up the control plane. The bearer token (written to
// <runtimeDir>/api.token, 0600) is always required on /logs, /ws and /api/*:
// loopback binding alone does not stop other local processes, or a browser
// page via DNS rebinding / a LAN client via the proxy, from reaching the API.
func NewAPIServer(proxyServer *proxy.ProxyServer, token, runtimeDir string) *APIServer {
	return &APIServer{
		proxyServer: proxyServer,
		token:       token,
		runtimeDir:  runtimeDir,
		clients:     make(map[*websocket.Conn]struct{}),
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			CheckOrigin:     allowLoopbackOrigin,
		},
	}
}

// ActiveClients returns the number of connected WebSocket clients (the UI).
// The daemon's idle watcher treats any connected client as activity.
func (s *APIServer) ActiveClients() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.clients)
}

// HTTPServer returns a configured *http.Server bound to addr. Caller runs ListenAndServe.
func (s *APIServer) HTTPServer(addr string) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth) // unauthenticated — daemon liveness probe
	mux.HandleFunc("/welcome", s.handleWelcome)
	mux.HandleFunc("/cert/ios", s.handleCert)
	mux.HandleFunc("/cert/macos", s.handleCert)
	mux.HandleFunc("/cert/ca.pem", s.handleCert)

	mux.Handle("/logs", s.auth(http.HandlerFunc(s.handleGetLogs)))
	mux.Handle("/ws", s.auth(http.HandlerFunc(s.handleWebSocket)))
	mux.Handle("/api/apps", s.auth(http.HandlerFunc(s.handleApps)))
	mux.Handle("/api/apps/", s.auth(http.HandlerFunc(s.handleAppOperation)))
	mux.Handle("/api/mocks", s.auth(http.HandlerFunc(s.handleMocks)))
	mux.Handle("/api/mocks/", s.auth(http.HandlerFunc(s.handleMockByID)))

	_, port, _ := net.SplitHostPort(addr)
	handler := checkHost(port, checkOrigin(jsonContentTypeOnPost(noStoreHeaders(mux))))
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0, // 0 → WS-friendly; per-handler timeouts apply
		IdleTimeout:       2 * time.Minute,
	}
}

// auth is the bearer-token middleware. Accepts the token either via the
// Authorization: Bearer <token> header or a ?token= query param (the latter
// is needed for the WebSocket handshake, where JS clients can't set headers).
func (s *APIServer) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := bearerFromRequest(r)
		if s.token == "" || !constTimeEqual(got, s.token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func bearerFromRequest(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	return r.URL.Query().Get("token")
}

func constTimeEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func isLoopbackHostname(h string) bool {
	switch strings.ToLower(h) {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

// allowLoopbackOrigin accepts a missing Origin (native clients such as
// ProxyApp's URLSession) or an origin whose host is exactly a loopback name.
// The host is parsed, not prefix-matched: "http://localhost.evil.com" and
// "http://127.0.0.1.nip.io" are rejected. "null" (sandboxed iframes, file://)
// is rejected too.
func allowLoopbackOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return false
	}
	return isLoopbackHostname(u.Hostname())
}

// checkOrigin applies allowLoopbackOrigin to every request, not just the WS
// upgrade, so a web page can't drive the REST API cross-origin.
func checkOrigin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowLoopbackOrigin(r) {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// checkHost rejects requests whose Host header isn't a loopback name on the
// API port. A DNS-rebinding page (evil.com → 127.0.0.1) still sends
// "Host: evil.com:8081", so it is refused here.
func checkHost(port string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, p, err := net.SplitHostPort(r.Host)
		if err != nil || p != port || !isLoopbackHostname(host) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func noStoreHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

// jsonContentTypeOnPost caps write bodies and requires Content-Type
// application/json on them. A browser can't send that cross-origin without a
// CORS preflight (which we never approve), so "simple" form/text POSTs are out.
func jsonContentTypeOnPost(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch {
			r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
			mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil || mt != "application/json" {
				http.Error(w, "expected application/json", http.StatusUnsupportedMediaType)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}

// ---- handlers ----

func (s *APIServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *APIServer) handleGetLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, s.proxyServer.GetLogs())
}

func (s *APIServer) handleMocks(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, s.proxyServer.MockManager().ListMocks())
	case http.MethodPost:
		var mock proxy.MockResponse
		if err := json.NewDecoder(r.Body).Decode(&mock); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if err := s.proxyServer.MockManager().AddMock(mock); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleMockByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/mocks/")
	if id == "" || strings.Contains(id, "/") {
		http.Error(w, "missing or invalid id", http.StatusBadRequest)
		return
	}
	switch r.Method {
	case http.MethodDelete:
		if err := s.proxyServer.MockManager().DeleteMockByID(id); err != nil {
			http.Error(w, "mock not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleApps(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, s.proxyServer.AppsManager().ListApps())
	case http.MethodPost:
		var app proxy.MonitoredApp
		if err := json.NewDecoder(r.Body).Decode(&app); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if err := s.proxyServer.AppsManager().AddApp(app); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleAppOperation(w http.ResponseWriter, r *http.Request) {
	bundleID := strings.TrimPrefix(r.URL.Path, "/api/apps/")
	if bundleID == "" || strings.Contains(bundleID, "/") {
		http.Error(w, "bundle id required", http.StatusBadRequest)
		return
	}
	switch r.Method {
	case http.MethodGet:
		if app, exists := s.proxyServer.AppsManager().GetApp(bundleID); exists {
			writeJSON(w, http.StatusOK, app)
		} else {
			http.Error(w, "app not found", http.StatusNotFound)
		}
	case http.MethodDelete:
		if err := s.proxyServer.AppsManager().RemoveApp(bundleID); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade failed: %v", err)
		return
	}

	s.mu.Lock()
	s.clients[conn] = struct{}{}
	s.mu.Unlock()

	logChan := s.proxyServer.Subscribe()

	// Reader side: only consumes pongs and detects client disconnect.
	conn.SetReadLimit(1 << 20)
	_ = conn.SetReadDeadline(time.Now().Add(wsReadDeadline))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(wsReadDeadline))
	})

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			if _, _, err := conn.NextReader(); err != nil {
				return
			}
		}
	}()

	pingTicker := time.NewTicker(wsPingPeriod)
	defer pingTicker.Stop()

	cleanup := func() {
		s.proxyServer.Unsubscribe(logChan)
		s.mu.Lock()
		delete(s.clients, conn)
		s.mu.Unlock()
		_ = conn.Close()
	}

	for {
		select {
		case <-done:
			cleanup()
			return
		case <-pingTicker.C:
			if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				cleanup()
				return
			}
		case entry, ok := <-logChan:
			if !ok {
				cleanup()
				return
			}
			_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := conn.WriteJSON(entry); err != nil {
				cleanup()
				return
			}
		}
	}
}

func (s *APIServer) handleCert(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", "attachment; filename=packetpeek-ca.pem")
	http.ServeFile(w, r, s.proxyServer.CertManager().CertPath())
}

func (s *APIServer) handleWelcome(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(welcomeHTML))
}

// runtimeFilePath is unused publicly but kept so external entry points can locate
// the runtime dir consistently if needed in future endpoints.
func (s *APIServer) runtimeFilePath(name string) string {
	return filepath.Join(s.runtimeDir, name)
}

const welcomeHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>PacketPeek</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 720px; margin: 60px auto; padding: 0 24px; line-height: 1.55; color: #1c1c1e; }
h1 { font-weight: 600; }
.ok { color: #2e7d32; font-weight: 600; }
a.btn { display: inline-block; padding: 10px 16px; margin: 8px 8px 8px 0; background: #007aff; color: white; text-decoration: none; border-radius: 8px; font-weight: 500; }
a.btn:hover { background: #0a64d6; }
code { background: #f2f2f7; padding: 2px 6px; border-radius: 4px; }
ol li { margin: 6px 0; }
</style>
</head>
<body>
<h1>PacketPeek API</h1>
<p class="ok">✅ Control plane is running on loopback.</p>
<p>Use the desktop app to manage the proxy. The cert endpoints below are
public so devices on the LAN (via the proxy port) can install the CA.</p>
<p>
<a class="btn" href="/cert/ios">Download CA (iOS)</a>
<a class="btn" href="/cert/macos">Download CA (macOS)</a>
</p>
</body>
</html>`
