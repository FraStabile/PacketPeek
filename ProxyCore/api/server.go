package api

import (
	"encoding/json"
	"log"
	"net/http"
	"proxy_core/proxy"
	"strings"
	"sync"

	"github.com/gorilla/websocket"
)

type APIServer struct {
	proxyServer *proxy.ProxyServer
	appsManager *proxy.MonitoredAppsManager
	upgrader    websocket.Upgrader
	clients     map[*websocket.Conn]struct{}
	mu          sync.RWMutex
}

func NewAPIServer(proxyServer *proxy.ProxyServer) *APIServer {
	return &APIServer{
		proxyServer: proxyServer,
		appsManager: proxy.NewMonitoredAppsManager("monitored_apps.json"),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				return true // Allow all origins for development
			},
		},
		clients: make(map[*websocket.Conn]struct{}),
	}
}

func (s *APIServer) Start(addr string) error {
	http.HandleFunc("/logs", s.handleGetLogs)
	http.HandleFunc("/ws", s.handleWebSocket)
	http.HandleFunc("/welcome", s.handleWelcome)
	http.HandleFunc("/cert/ios", s.handleIOSCert)
	http.HandleFunc("/cert/macos", s.handleMacOSCert)
	http.HandleFunc("/api/apps", s.handleApps)
	http.HandleFunc("/api/apps/", s.handleAppOperation)
	
	return http.ListenAndServe(addr, nil)
}

func (s *APIServer) handleGetLogs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.proxyServer.GetLogs())
}

func (s *APIServer) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Failed to upgrade connection: %v", err)
		return
	}
	defer conn.Close()

	// Subscribe to proxy logs
	logChan := s.proxyServer.Subscribe()
	defer func() {
		s.proxyServer.Unsubscribe(logChan)
		s.mu.Lock()
		delete(s.clients, conn)
		s.mu.Unlock()
		conn.Close()
	}()

	// Send logs to client
	for logMessage := range logChan {
		err := conn.WriteJSON(logMessage)
		if err != nil {
			log.Println(err)
			return
		}
	}
}

func (s *APIServer) handleWelcome(w http.ResponseWriter, r *http.Request) {
	html := `
<!DOCTYPE html>
<html>
<head>
    <title>ProxyCore - Welcome</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            max-width: 800px;
            margin: 40px auto;
            padding: 0 20px;
            line-height: 1.6;
            color: #333;
        }
        .success {
            color: #2ecc71;
            font-size: 24px;
            margin-bottom: 30px;
        }
        .links {
            margin-top: 30px;
        }
        .links a {
            display: inline-block;
            margin-right: 20px;
            padding: 10px 20px;
            background-color: #3498db;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            transition: background-color 0.3s;
        }
        .links a:hover {
            background-color: #2980b9;
        }
    </style>
</head>
<body>
    <h1>ProxyCore</h1>
    <div class="success">✅ Sei connesso al Proxy</div>
    <p>Per utilizzare il proxy HTTPS, devi installare il certificato CA sul tuo dispositivo:</p>
    <div class="links">
        <a href="/cert/ios">Scarica certificato per iOS Simulator</a>
        <a href="/cert/macos">Scarica certificato per MacOS</a>
    </div>
</body>
</html>`

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(html))
}

func (s *APIServer) handleIOSCert(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", "attachment; filename=proxy-ca.pem")
	http.ServeFile(w, r, "ca.pem")
}

func (s *APIServer) handleMacOSCert(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", "attachment; filename=proxy-ca.pem")
	http.ServeFile(w, r, "ca.pem")
}

func (s *APIServer) handleApps(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		// Lista tutte le app monitorate
		apps := s.appsManager.ListApps()
		json.NewEncoder(w).Encode(apps)

	case http.MethodPost:
		// Aggiungi una nuova app
		var app proxy.MonitoredApp
		if err := json.NewDecoder(r.Body).Decode(&app); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := s.appsManager.AddApp(app); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleAppOperation(w http.ResponseWriter, r *http.Request) {
	// Estrai il bundle ID dall'URL
	bundleID := strings.TrimPrefix(r.URL.Path, "/api/apps/")
	if bundleID == "" {
		http.Error(w, "Bundle ID required", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		// Ottieni dettagli di un'app
		if app, exists := s.appsManager.GetApp(bundleID); exists {
			json.NewEncoder(w).Encode(app)
		} else {
			http.Error(w, "App not found", http.StatusNotFound)
		}

	case http.MethodDelete:
		// Rimuovi un'app
		if err := s.appsManager.RemoveApp(bundleID); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}
