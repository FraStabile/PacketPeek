package proxy

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net/http"
	"proxy_core/cert"
	"strings"
	"sync"
	"time"

	"github.com/mssola/user_agent"
)

type RequestLog struct {
	// Request info
	Method         string            `json:"method"`
	URL            string            `json:"url"`
	Protocol       string            `json:"protocol"`
	ClientIP       string            `json:"client_ip"`
	RequestHeaders map[string]string `json:"request_headers"`
	RequestBody    string            `json:"request_body,omitempty"`

	// Response info
	StatusCode      int               `json:"status_code"`
	ResponseHeaders map[string]string `json:"response_headers"`
	ResponseBody    string            `json:"response_body,omitempty"`
	ResponseTime    time.Duration     `json:"response_time_ms"`

	// Timing
	Timestamp time.Time `json:"timestamp"`
	Completed time.Time `json:"completed"`

	// Device info
	UserAgent     string `json:"user_agent,omitempty"`
	DeviceInfo    string `json:"device_info,omitempty"`
	IsSimulator   bool   `json:"is_simulator"`
	AppIdentifier string `json:"app_identifier,omitempty"`
}

type ProxyServer struct {
	certManager *cert.CertManager
	logs        []RequestLog
	mu          sync.RWMutex
	appsManager *MonitoredAppsManager
	clients     map[chan RequestLog]struct{}
}

func (p *ProxyServer) Subscribe() chan RequestLog {
	ch := make(chan RequestLog)
	p.mu.Lock()
	p.clients[ch] = struct{}{}
	p.mu.Unlock()
	return ch
}

func (p *ProxyServer) Unsubscribe(ch chan RequestLog) {
	p.mu.Lock()
	delete(p.clients, ch)
	p.mu.Unlock()
	close(ch)
}

func (p *ProxyServer) notifySubscribers(log RequestLog) {
	p.mu.RLock()
	for ch := range p.clients {
		select {
		case ch <- log:
		default:
			// Skip if channel is full
		}
	}
	p.mu.RUnlock()
}

func (p *ProxyServer) Start(addr string) error {
	return http.ListenAndServe(addr, p)
}

func (p *ProxyServer) addLog(log RequestLog) {
	p.mu.Lock()
	p.logs = append(p.logs, log)
	if len(p.logs) > 1000 { // Keep last 1000 logs
		p.logs = p.logs[1:]
	}
	p.mu.Unlock()

	// Notify subscribers
	p.notifySubscribers(log)
}

func (p *ProxyServer) GetLogs() []RequestLog {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return append([]RequestLog{}, p.logs...)
}

func NewProxyServer(certManager *cert.CertManager) *ProxyServer {
	return &ProxyServer{
		certManager: certManager,
		appsManager: NewMonitoredAppsManager("monitored_apps.json"),
		clients:     make(map[chan RequestLog]struct{}),
	}
}

func (p *ProxyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Create log entry
	logEntry := RequestLog{
		Timestamp:       time.Now(),
		Method:          r.Method,
		URL:             r.URL.String(),
		Protocol:        r.Proto,
		RequestHeaders:  make(map[string]string),
		ResponseHeaders: make(map[string]string),
	}

	// Check if request is from iOS simulator
	logEntry.IsSimulator = strings.Contains(r.UserAgent(), "Simulator")

	// Extract app identifier from headers
	if bundleID := r.Header.Get("X-Bundle-ID"); bundleID != "" {
		logEntry.AppIdentifier = bundleID
	} else if bundleID := r.Header.Get("CFBundleIdentifier"); bundleID != "" {
		logEntry.AppIdentifier = bundleID
	}

	// If it's a CONNECT request, handle HTTPS
	if r.Method == http.MethodConnect {
		p.handleHTTPS(w, r)
		return
	}

	// Always try to capture request body if present
	if r.Body != nil {
		body, err := io.ReadAll(r.Body)
		if err == nil && len(body) > 0 {
			logEntry.RequestBody = string(body)
			// Restore body for forwarding
			r.Body = io.NopCloser(bytes.NewBuffer(body))
		}
	}

	// For HTTP requests, capture headers
	for k, v := range r.Header {
		logEntry.RequestHeaders[k] = strings.Join(v, ", ")
	}

	// Forward the request
	resp, err := http.DefaultTransport.RoundTrip(r)
	if err != nil {
		logEntry.StatusCode = http.StatusBadGateway
		p.addLog(logEntry)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Copy response headers
	for k, v := range resp.Header {
		logEntry.ResponseHeaders[k] = strings.Join(v, ", ")
		w.Header().Set(k, strings.Join(v, ", "))
	}

	// Set status code
	w.WriteHeader(resp.StatusCode)
	logEntry.StatusCode = resp.StatusCode

	// Always try to capture response body if present
	body, err := io.ReadAll(resp.Body)
	if err == nil && len(body) > 0 {
		logEntry.ResponseBody = string(body)
		// Write body to response
		w.Write(body)
	} else {
		// If we couldn't read the body, stream it directly
		io.Copy(w, resp.Body)
	}

	// Complete the log
	logEntry.Completed = time.Now()
	logEntry.ResponseTime = logEntry.Completed.Sub(logEntry.Timestamp)
	p.addLog(logEntry)
}

func (p *ProxyServer) handleHTTPS(w http.ResponseWriter, r *http.Request) {
	log.Printf("[HTTPS] Nuova richiesta da %s a %s", r.RemoteAddr, r.Host)

	// Prepara il log per HTTPS
	logEntry := RequestLog{
		Timestamp:       time.Now(),
		Method:          r.Method,
		URL:             "https://" + r.Host,
		Protocol:        "HTTPS",
		ClientIP:        r.RemoteAddr,
		RequestHeaders:  make(map[string]string),
		ResponseHeaders: make(map[string]string),
		UserAgent:       r.UserAgent(),
	}

	// Copia gli header della richiesta
	for k, v := range r.Header {
		logEntry.RequestHeaders[k] = strings.Join(v, ", ")
	}

	// Aggiungi device info e controlla se è il simulatore
	ua := user_agent.New(r.UserAgent())
	browser, version := ua.Browser()
	logEntry.DeviceInfo = fmt.Sprintf("%s %s / %s %s", ua.Platform(), ua.OS(), browser, version)
	// Controlla se la richiesta viene dal simulatore iOS
	if ua.OS() == "iOS" && strings.Contains(r.UserAgent(), "Simulator") {
		logEntry.IsSimulator = true

		// Cerca di estrarre l'identificatore dell'app
		bundleID := r.Header.Get("X-Bundle-ID")
		if bundleID == "" {
			bundleID = r.Header.Get("CFBundleIdentifier")
		}
		if bundleID == "" {
			// Prova a estrarre dal User-Agent
			if parts := strings.Split(r.UserAgent(), "CFNetwork"); len(parts) > 1 {
				if app := strings.TrimSpace(parts[0]); app != "" {
					bundleID = app
				}
			}
		}

	}

	// Step 2: Hijack the connection
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		logEntry.StatusCode = http.StatusInternalServerError
		p.addLog(logEntry)
		http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
		return
	}

	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		logEntry.StatusCode = http.StatusInternalServerError
		p.addLog(logEntry)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer clientConn.Close()

	// Step 3: Generate certificate for host
	cert, err := p.certManager.GenerateCertificate(r.Host)
	if err != nil {
		logEntry.StatusCode = http.StatusInternalServerError
		p.addLog(logEntry)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Step 4: Send 200 OK to client
	_, err = clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	if err != nil {
		logEntry.StatusCode = http.StatusInternalServerError
		p.addLog(logEntry)
		return
	}

	// Step 5: Start TLS server for client
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{*cert},
	}
	tlsConn := tls.Server(clientConn, tlsConfig)
	defer tlsConn.Close()

	// Step 6: Create a buffered reader for the TLS connection
	reader := bufio.NewReader(tlsConn)

	// Step 7: Read and handle HTTPS requests
	for {
		// Read the request
		req, err := http.ReadRequest(reader)
		if err != nil {
			if err != io.EOF {
				log.Printf("Error reading request: %v", err)
			}
			break
		}

		// Create new log entry for this request
		reqLog := RequestLog{
			Timestamp:       time.Now(),
			Method:          req.Method,
			URL:             "https://" + r.Host + req.URL.String(),
			Protocol:        "HTTPS",
			ClientIP:        r.RemoteAddr,
			RequestHeaders:  make(map[string]string),
			ResponseHeaders: make(map[string]string),
			UserAgent:       req.UserAgent(),
		}

		// Capture request headers
		for k, v := range req.Header {
			reqLog.RequestHeaders[k] = strings.Join(v, ", ")
		}

		// Always try to capture request body
		if req.Body != nil {
			var bodyReader io.Reader = req.Body

			// Check if request is gzipped
			if req.Header.Get("Content-Encoding") == "gzip" {
				gzReader, err := gzip.NewReader(req.Body)
				if err == nil {
					bodyReader = gzReader
					defer gzReader.Close()
				}
			}

			// Read the body (decompressed if gzipped)
			body, err := io.ReadAll(bodyReader)
			if err == nil && len(body) > 0 {
				reqLog.RequestBody = string(body)
				// Restore body for forwarding
				req.Body = io.NopCloser(bytes.NewBuffer(body))
			}
		}

		// Create transport for the outgoing request
		transport := &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}

		// Create a new client with our transport
		client := &http.Client{Transport: transport}

		// Create a new request to forward
		outReq, err := http.NewRequest(req.Method, reqLog.URL, req.Body)
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			continue
		}

		// Copy headers to the new request
		outReq.Header = req.Header

		// Send the request
		resp, err := client.Do(outReq)
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			continue
		}

		// Capture response details
		reqLog.StatusCode = resp.StatusCode
		for k, v := range resp.Header {
			reqLog.ResponseHeaders[k] = strings.Join(v, ", ")
		}

		// Always try to capture response body
		if resp.Body != nil {
			var bodyReader io.Reader = resp.Body

			// Check if response is gzipped
			if resp.Header.Get("Content-Encoding") == "gzip" {
				gzReader, err := gzip.NewReader(resp.Body)
				if err == nil {
					bodyReader = gzReader
					defer gzReader.Close()
				}
			}

			// Read the body (decompressed if gzipped)
			body, err := io.ReadAll(bodyReader)
			if err == nil && len(body) > 0 {
				reqLog.ResponseBody = string(body)
				// Restore body for forwarding
				resp.Body = io.NopCloser(bytes.NewBuffer(body))
			}
		}

		// Write response back to client
		if err := resp.Write(tlsConn); err != nil {
			log.Printf("Error writing response: %v", err)
			break
		}

		// Complete the log
		reqLog.Completed = time.Now()
		reqLog.ResponseTime = reqLog.Completed.Sub(reqLog.Timestamp)
		p.addLog(reqLog)
	}
}
