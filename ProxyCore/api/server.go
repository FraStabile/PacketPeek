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
	mockManager *proxy.MockManager
}

func NewAPIServer(proxyServer *proxy.ProxyServer) *APIServer {
	return &APIServer{
		proxyServer: proxyServer,
		appsManager: proxy.NewMonitoredAppsManager("monitored_apps.json"),
		mockManager: proxy.NewMockManager("mocks.json"),
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
	http.HandleFunc("/api/mocks", s.handleMocks)     // GET e POST
	http.HandleFunc("/api/mocks/", s.handleMockByID) // attenzione allo slash finale!

	s.serveStaticFiles()
	return http.ListenAndServe(addr, nil)
}

func (s *APIServer) handleMockByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/mocks/")
	if id == "" {
		http.Error(w, "Missing ID", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		err := s.mockManager.DeleteMockByID(id)
		if err != nil {
			http.Error(w, "Mock not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *APIServer) handleMocks(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		mocks := s.mockManager.ListMocks()
		json.NewEncoder(w).Encode(mocks)
	case http.MethodPost:
		var mock proxy.MockResponse
		if err := json.NewDecoder(r.Body).Decode(&mock); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}
		error := s.mockManager.AddMock(mock)
		if error == nil {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
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
func (s *APIServer) serveStaticFiles() {
	// Servi i file statici dalla cartella corrente
	fs := http.FileServer(http.Dir("."))
	http.Handle("../static/", http.StripPrefix("/static/", fs))
}

func (s *APIServer) handleWelcome(w http.ResponseWriter, r *http.Request) {
	html := `
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PacketPeek - Success</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: #f7f7f7;
            color: #333;
            max-width: 900px;
            margin: 40px auto;
            padding: 0 20px;
            line-height: 1.6;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.05);
            border-radius: 8px;
        }

        h1 {
            font-size: 36px;
            margin-bottom: 15px;
            text-align: center;
            color: #333;
        }

        .success {
            color: #27ae60;
            font-size: 24px;
            margin-bottom: 30px;
            text-align: center;
            font-weight: bold;
        }

        p {
            font-size: 18px;
            text-align: center;
            margin-bottom: 20px;
        }

        .links {
            margin-top: 40px;
            text-align: center;
            padding-bottom: 40px;
			spa
        }

        .links a {
            display: inline-block;
            margin-right: 20px;
            padding: 12px 25px;
            background-color: #3498db;
            color: white;
            text-decoration: none;
            border-radius: 30px;
            font-size: 16px;
            font-weight: 500;
            transition: all 0.3s;
			margin-bottom: 20px;
        }

        .links a:hover {
            background-color: #2980b9;
        }

        .footer {
            margin-top: 50px;
            text-align: center;
            font-size: 14px;
            color: rgba(0, 0, 0, 0.6);
        }

        .footer a {
            color: #3498db;
            text-decoration: none;
            font-weight: 600;
        }

        .footer a:hover {
            text-decoration: underline;
        }

        .icon-container {
            text-align: center;
            margin-bottom: 20px;
        }

        .icon-container img {
            width: 80px;
            height: 80px;
            border-radius: 50%;
            border: 2px solid #3498db;
            padding: 10px;
            background-color: white;
        }
    </style>
</head>
<body>
    <h1>PacketPeek - Proxy</h1>
    <div class="success">✅ Sei connesso al Proxy</div>
    <p>Per utilizzare PacketPeek, devi installare il certificato CA sul tuo dispositivo:</p>
    <div class="links">
        <a href="/cert/ios">Scarica certificato per iOS Simulator</a>
        <a href="/cert/macos">Scarica certificato per macOS</a>
    </div>
</body>
</html>
`

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
		w.WriteHeader(http.StatusOK)

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
