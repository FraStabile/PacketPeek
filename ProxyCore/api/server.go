package api

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"os"
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
	requireAuth bool
	runtimeDir  string
}

// NewAPIServer wires up the control plane. The token is written to disk so a
// future client can attach it as a Bearer header; enforcement is opt-in via
// requireAuth so the MVP can ship without breaking the existing Swift client.
// Loopback binding already protects against off-host attackers.
func NewAPIServer(proxyServer *proxy.ProxyServer, token, runtimeDir string) *APIServer {
	requireAuth := os.Getenv("PACKETPEEK_AUTH") == "required"
	return &APIServer{
		proxyServer: proxyServer,
		token:       token,
		requireAuth: requireAuth,
		runtimeDir:  runtimeDir,
		clients:     make(map[*websocket.Conn]struct{}),
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			CheckOrigin:     allowLoopbackOrigin,
		},
	}
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

	return &http.Server{
		Addr:              addr,
		Handler:           jsonContentTypeOnPost(noStoreHeaders(mux)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0, // 0 → WS-friendly; per-handler timeouts apply
		IdleTimeout:       2 * time.Minute,
	}
}

// auth is the bearer-token middleware. Accepts the token either via the
// Authorization: Bearer <token> header or a ?token= query param (the latter
// is needed for the WebSocket handshake, where JS clients can't set headers).
// Bypassed entirely when requireAuth=false (default), at which point we still
// generate and write the token so clients can opt in.
func (s *APIServer) auth(next http.Handler) http.Handler {
	if !s.requireAuth {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := bearerFromRequest(r)
		if !constTimeEqual(got, s.token) {
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

// allowLoopbackOrigin lets WS connections through only when the Origin header is
// empty (native clients), missing, or points at a loopback address.
func allowLoopbackOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	o := strings.ToLower(origin)
	return strings.HasPrefix(o, "http://127.0.0.1") ||
		strings.HasPrefix(o, "http://localhost") ||
		strings.HasPrefix(o, "https://127.0.0.1") ||
		strings.HasPrefix(o, "https://localhost") ||
		strings.HasPrefix(o, "file://")
}

func noStoreHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func jsonContentTypeOnPost(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Cap POST/PUT/DELETE bodies. Cheap and avoids surprises.
		if r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch {
			r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
			if ct := r.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(ct, "application/json") {
				// Allow form/text bodies through for now, but log noisy mismatches.
				if !strings.HasPrefix(ct, "application/x-www-form-urlencoded") &&
					!strings.HasPrefix(ct, "text/") {
					http.Error(w, "expected application/json", http.StatusUnsupportedMediaType)
					return
				}
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
