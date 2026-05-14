package proxy

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"proxy_core/cert"

	"github.com/mssola/user_agent"
)

const (
	// Maximum body size captured for logging. Bodies larger than this are truncated
	// in the log only — the bytes still flow through to the client/server.
	maxLoggedBodyBytes = 1 << 20 // 1 MiB

	// Upstream transport timeouts. Generous so SSE/streaming requests survive,
	// strict enough that a dead upstream releases the goroutine.
	upstreamDialTimeout      = 10 * time.Second
	upstreamTLSHandshake     = 10 * time.Second
	upstreamResponseHeader   = 60 * time.Second
	upstreamIdleConn         = 90 * time.Second
)

type RequestLog struct {
	Method         string            `json:"method"`
	URL            string            `json:"url"`
	Protocol       string            `json:"protocol"`
	ClientIP       string            `json:"client_ip"`
	RequestHeaders map[string]string `json:"request_headers"`
	RequestBody    string            `json:"request_body,omitempty"`

	StatusCode      int               `json:"status_code"`
	ResponseHeaders map[string]string `json:"response_headers"`
	ResponseBody    string            `json:"response_body,omitempty"`
	ResponseTime    time.Duration     `json:"response_time_ms"`

	Timestamp time.Time `json:"timestamp"`
	Completed time.Time `json:"completed"`

	UserAgent     string `json:"user_agent,omitempty"`
	DeviceInfo    string `json:"device_info,omitempty"`
	IsSimulator   bool   `json:"is_simulator"`
	AppIdentifier string `json:"app_identifier,omitempty"`
}

type ProxyServer struct {
	certManager *cert.CertManager
	logs        []RequestLog
	mu          sync.Mutex
	appsManager *MonitoredAppsManager
	clients     map[chan RequestLog]struct{}
	clientsMu   sync.Mutex
	mockManager *MockManager
	runtimeDir  string

	upstream *http.Transport
}

func NewProxyServer(certManager *cert.CertManager, runtimeDir string) *ProxyServer {
	if runtimeDir == "" {
		runtimeDir = "."
	}
	return &ProxyServer{
		certManager: certManager,
		appsManager: NewMonitoredAppsManager(filepath.Join(runtimeDir, "monitored_apps.json")),
		clients:     make(map[chan RequestLog]struct{}),
		mockManager: NewMockManager(filepath.Join(runtimeDir, "mocks.json")),
		runtimeDir:  runtimeDir,
		upstream:    newUpstreamTransport(),
	}
}

func newUpstreamTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   upstreamDialTimeout,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   upstreamTLSHandshake,
		ResponseHeaderTimeout: upstreamResponseHeader,
		IdleConnTimeout:       upstreamIdleConn,
		ExpectContinueTimeout: 1 * time.Second,
		MaxIdleConns:          100,
		// InsecureSkipVerify is intentional: this is a MITM proxy. We can't validate
		// the upstream cert against our CA. Documented and opt-in-able in settings.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12},
	}
}

func (p *ProxyServer) MockManager() *MockManager           { return p.mockManager }
func (p *ProxyServer) AppsManager() *MonitoredAppsManager  { return p.appsManager }
func (p *ProxyServer) CertManager() *cert.CertManager      { return p.certManager }

func (p *ProxyServer) Subscribe() chan RequestLog {
	ch := make(chan RequestLog, 64)
	p.clientsMu.Lock()
	p.clients[ch] = struct{}{}
	p.clientsMu.Unlock()
	return ch
}

func (p *ProxyServer) Unsubscribe(ch chan RequestLog) {
	p.clientsMu.Lock()
	if _, ok := p.clients[ch]; ok {
		delete(p.clients, ch)
		close(ch)
	}
	p.clientsMu.Unlock()
}

func (p *ProxyServer) notifySubscribers(entry RequestLog) {
	p.clientsMu.Lock()
	for ch := range p.clients {
		select {
		case ch <- entry:
		default:
			// drop if subscriber is slow; don't block the publisher
		}
	}
	p.clientsMu.Unlock()
}

func (p *ProxyServer) addLog(entry RequestLog) {
	p.mu.Lock()
	p.logs = append(p.logs, entry)
	if len(p.logs) > 1000 {
		p.logs = p.logs[len(p.logs)-1000:]
	}
	p.mu.Unlock()
	p.notifySubscribers(entry)
}

func (p *ProxyServer) GetLogs() []RequestLog {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]RequestLog, len(p.logs))
	copy(out, p.logs)
	return out
}

// sanitizeLogValue strips CR/LF so user-controlled values can't forge log lines.
func sanitizeLogValue(s string) string {
	r := strings.NewReplacer("\r", "\\r", "\n", "\\n")
	return r.Replace(s)
}

// truncateForLog caps a string at maxLoggedBodyBytes for the log copy.
func truncateForLog(b []byte) string {
	if len(b) <= maxLoggedBodyBytes {
		return string(b)
	}
	return string(b[:maxLoggedBodyBytes]) + fmt.Sprintf("\n…[truncated %d bytes]", len(b)-maxLoggedBodyBytes)
}

func (p *ProxyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Serve the cert / welcome endpoints when a phone hits the proxy port
	// (the API control plane is loopback-only, so this is the LAN-reachable surface).
	if r.Method != http.MethodConnect {
		if p.serveLocalAsset(w, r) {
			return
		}
	}

	logEntry := RequestLog{
		Timestamp:       time.Now(),
		Method:          r.Method,
		URL:             r.URL.String(),
		Protocol:        r.Proto,
		ClientIP:        r.RemoteAddr,
		RequestHeaders:  make(map[string]string),
		ResponseHeaders: make(map[string]string),
		UserAgent:       r.UserAgent(),
	}
	logEntry.IsSimulator = strings.Contains(r.UserAgent(), "Simulator")

	if bundleID := r.Header.Get("X-Bundle-ID"); bundleID != "" {
		logEntry.AppIdentifier = bundleID
	} else if bundleID := r.Header.Get("CFBundleIdentifier"); bundleID != "" {
		logEntry.AppIdentifier = bundleID
	}

	if r.Method == http.MethodConnect {
		p.handleHTTPS(w, r)
		return
	}

	// Capture request body for logging (cap at maxLoggedBodyBytes).
	if r.Body != nil {
		body, err := io.ReadAll(r.Body)
		if err == nil && len(body) > 0 {
			logEntry.RequestBody = truncateForLog(body)
			r.Body = io.NopCloser(bytes.NewBuffer(body))
		}
	}

	for k, v := range r.Header {
		logEntry.RequestHeaders[k] = strings.Join(v, ", ")
	}

	// Plain HTTP mock interception (CONNECT path handles HTTPS separately).
	if mockResp, _ := p.mockManager.Match(r.Method, r.Host, r.URL.RequestURI()); mockResp != nil {
		p.serveMockHTTP(w, mockResp, &logEntry)
		return
	}

	// Forward through hardened transport.
	outReq := r.Clone(r.Context())
	outReq.RequestURI = ""
	if outReq.URL.Scheme == "" {
		outReq.URL.Scheme = "http"
	}
	if outReq.URL.Host == "" {
		outReq.URL.Host = r.Host
	}

	resp, err := p.upstream.RoundTrip(outReq)
	if err != nil {
		logEntry.StatusCode = http.StatusBadGateway
		p.addLog(logEntry)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, v := range resp.Header {
		logEntry.ResponseHeaders[k] = strings.Join(v, ", ")
		for _, vv := range v {
			w.Header().Add(k, vv)
		}
	}
	w.WriteHeader(resp.StatusCode)
	logEntry.StatusCode = resp.StatusCode

	// Tee the body to the client and (truncated) to the log.
	var logBuf bytes.Buffer
	limited := io.LimitReader(resp.Body, maxLoggedBodyBytes+1)
	tee := io.TeeReader(limited, &logBuf)
	if _, err := io.Copy(w, tee); err != nil {
		// client likely went away; we keep what we logged so far
	}
	if logBuf.Len() > maxLoggedBodyBytes {
		logEntry.ResponseBody = truncateForLog(logBuf.Bytes())
	} else {
		logEntry.ResponseBody = decodeIfGzip(resp.Header.Get("Content-Encoding"), logBuf.Bytes())
	}

	// If the body was larger than the limit, drain the remaining bytes to the client
	// without buffering further into the log.
	_, _ = io.Copy(w, resp.Body)

	logEntry.Completed = time.Now()
	logEntry.ResponseTime = logEntry.Completed.Sub(logEntry.Timestamp)
	p.addLog(logEntry)
}

// serveLocalAsset handles non-proxy GETs to /welcome and /cert/* when the proxy
// port is hit directly (e.g. user types http://<mac-lan-ip>:8080/welcome on a phone).
func (p *ProxyServer) serveLocalAsset(w http.ResponseWriter, r *http.Request) bool {
	// Only handle when the request is targeting the proxy itself (no Host header
	// pointing to a remote, or Host matches a local interface). To keep things
	// simple, gate on path and the absence of an absolute-form URL.
	if r.URL.IsAbs() {
		return false
	}
	switch {
	case r.URL.Path == "/welcome":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(welcomeHTML))
		return true
	case r.URL.Path == "/cert/ios", r.URL.Path == "/cert/macos", r.URL.Path == "/cert/ca.pem":
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Header().Set("Content-Disposition", "attachment; filename=packetpeek-ca.pem")
		http.ServeFile(w, r, p.certManager.CertPath())
		return true
	}
	return false
}

// serveMockHTTP frames a mocked response correctly via http.Response.Write
// (no manual byte construction = no CRLF injection / smuggling risk).
func (p *ProxyServer) serveMockHTTP(w http.ResponseWriter, m *MockResponse, entry *RequestLog) {
	if m.LatencyMs > 0 {
		time.Sleep(time.Duration(m.LatencyMs) * time.Millisecond)
	}
	ct := m.ContentType
	if ct == "" {
		ct = "application/json"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("X-Mock-Response", "true")
	if m.StatusCode == 0 {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(m.StatusCode)
	}
	_, _ = w.Write([]byte(m.Response))

	entry.StatusCode = m.StatusCode
	entry.ResponseHeaders = map[string]string{
		"Content-Type":    ct,
		"X-Mock-Response": "true",
	}
	entry.ResponseBody = m.Response
	entry.Completed = time.Now()
	entry.ResponseTime = entry.Completed.Sub(entry.Timestamp)
	p.addLog(*entry)
}

func decodeIfGzip(encoding string, body []byte) string {
	if !strings.Contains(strings.ToLower(encoding), "gzip") {
		return string(body)
	}
	gz, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return string(body)
	}
	defer gz.Close()
	out, err := io.ReadAll(io.LimitReader(gz, maxLoggedBodyBytes))
	if err != nil {
		return string(body)
	}
	return string(out)
}

func (p *ProxyServer) handleHTTPS(w http.ResponseWriter, r *http.Request) {
	log.Printf("[HTTPS] new request from %s to %s", sanitizeLogValue(r.RemoteAddr), sanitizeLogValue(r.Host))

	parentLog := RequestLog{
		Timestamp:       time.Now(),
		Method:          r.Method,
		URL:             "https://" + r.Host,
		Protocol:        "HTTPS",
		ClientIP:        r.RemoteAddr,
		RequestHeaders:  make(map[string]string),
		ResponseHeaders: make(map[string]string),
		UserAgent:       r.UserAgent(),
	}
	for k, v := range r.Header {
		parentLog.RequestHeaders[k] = strings.Join(v, ", ")
	}
	ua := user_agent.New(r.UserAgent())
	browser, version := ua.Browser()
	parentLog.DeviceInfo = fmt.Sprintf("%s %s / %s %s", ua.Platform(), ua.OS(), browser, version)
	if ua.OS() == "iOS" && strings.Contains(r.UserAgent(), "Simulator") {
		parentLog.IsSimulator = true
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		parentLog.StatusCode = http.StatusInternalServerError
		p.addLog(parentLog)
		http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		parentLog.StatusCode = http.StatusInternalServerError
		p.addLog(parentLog)
		return
	}
	defer clientConn.Close()

	leaf, err := p.certManager.GenerateCertificate(r.Host)
	if err != nil {
		parentLog.StatusCode = http.StatusInternalServerError
		p.addLog(parentLog)
		return
	}

	if _, err := clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		parentLog.StatusCode = http.StatusInternalServerError
		p.addLog(parentLog)
		return
	}

	tlsConfig := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{*leaf},
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			if hello.ServerName == "" {
				return leaf, nil
			}
			return p.certManager.GenerateCertificate(hello.ServerName)
		},
	}
	tlsConn := tls.Server(clientConn, tlsConfig)
	defer tlsConn.Close()

	reader := bufio.NewReader(tlsConn)
	client := &http.Client{
		Transport: p.upstream,
		Timeout:   2 * time.Minute,
	}

	for {
		req, err := http.ReadRequest(reader)
		if err != nil {
			if err != io.EOF {
				log.Printf("Error reading tunneled request: %v", sanitizeError(err))
			}
			return
		}

		reqLog := RequestLog{
			Timestamp:       time.Now(),
			Method:          req.Method,
			URL:             "https://" + r.Host + req.URL.RequestURI(),
			Protocol:        "HTTPS",
			ClientIP:        r.RemoteAddr,
			RequestHeaders:  make(map[string]string),
			ResponseHeaders: make(map[string]string),
			UserAgent:       req.UserAgent(),
			IsSimulator:     parentLog.IsSimulator,
			DeviceInfo:      parentLog.DeviceInfo,
		}
		for k, v := range req.Header {
			reqLog.RequestHeaders[k] = strings.Join(v, ", ")
		}

		var bodyBytes []byte
		if req.Body != nil {
			bodyBytes, _ = io.ReadAll(req.Body)
			req.Body.Close()
			if len(bodyBytes) > 0 {
				logged := bodyBytes
				if ct := req.Header.Get("Content-Encoding"); strings.Contains(strings.ToLower(ct), "gzip") {
					if gz, err := gzip.NewReader(bytes.NewReader(bodyBytes)); err == nil {
						if decoded, err := io.ReadAll(io.LimitReader(gz, maxLoggedBodyBytes)); err == nil {
							logged = decoded
						}
						gz.Close()
					}
				}
				reqLog.RequestBody = truncateForLog(logged)
			}
		}

		// Mock match uses method + host + path?query.
		if mockResp, _ := p.mockManager.Match(req.Method, r.Host, req.URL.RequestURI()); mockResp != nil {
			writeMockToTLSConn(tlsConn, mockResp)
			reqLog.StatusCode = mockResp.StatusCode
			reqLog.ResponseHeaders = map[string]string{"X-Mock-Response": "true", "Content-Type": mockResp.ContentType}
			reqLog.ResponseBody = mockResp.Response
			reqLog.Completed = time.Now()
			reqLog.ResponseTime = reqLog.Completed.Sub(reqLog.Timestamp)
			p.addLog(reqLog)
			continue
		}

		outURL := "https://" + r.Host + req.URL.RequestURI()
		outReq, err := http.NewRequestWithContext(req.Context(), req.Method, outURL, bytes.NewReader(bodyBytes))
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			continue
		}
		// Copy request headers, but strip hop-by-hop entries.
		for k, v := range req.Header {
			if isHopHeader(k) {
				continue
			}
			outReq.Header[k] = v
		}

		resp, err := client.Do(outReq)
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			continue
		}

		reqLog.StatusCode = resp.StatusCode
		for k, v := range resp.Header {
			reqLog.ResponseHeaders[k] = strings.Join(v, ", ")
		}

		// Buffer the response for logging (bounded), then forward original bytes verbatim.
		respBytes, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		logged := respBytes
		if len(respBytes) > maxLoggedBodyBytes {
			logged = respBytes[:maxLoggedBodyBytes]
		}
		reqLog.ResponseBody = decodeIfGzip(resp.Header.Get("Content-Encoding"), logged)

		// Reassemble a response and write it back to the TLS tunnel.
		resp.Body = io.NopCloser(bytes.NewReader(respBytes))
		resp.ContentLength = int64(len(respBytes))
		if err := resp.Write(tlsConn); err != nil {
			log.Printf("Error writing tunneled response: %v", sanitizeError(err))
			p.addLog(reqLog)
			return
		}

		reqLog.Completed = time.Now()
		reqLog.ResponseTime = reqLog.Completed.Sub(reqLog.Timestamp)
		p.addLog(reqLog)
	}
}

// writeMockToTLSConn frames a mock response via http.Response.Write to avoid
// CRLF / header-injection from attacker-controlled body or content-type.
func writeMockToTLSConn(conn *tls.Conn, m *MockResponse) {
	body := []byte(m.Response)
	ct := m.ContentType
	if ct == "" {
		ct = "application/json"
	}
	status := m.StatusCode
	if status == 0 {
		status = http.StatusOK
	}
	resp := &http.Response{
		Status:        fmt.Sprintf("%d %s", status, http.StatusText(status)),
		StatusCode:    status,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Header: http.Header{
			"Content-Type":    []string{ct},
			"X-Mock-Response": []string{"true"},
		},
	}
	_ = resp.Write(conn)
}

func isHopHeader(name string) bool {
	switch http.CanonicalHeaderKey(name) {
	case "Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate",
		"Proxy-Authorization", "Te", "Trailer", "Transfer-Encoding", "Upgrade":
		return true
	}
	return false
}

func sanitizeError(err error) string {
	if err == nil {
		return ""
	}
	return sanitizeLogValue(err.Error())
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
<h1>PacketPeek Proxy</h1>
<p class="ok">✅ You are connected to the proxy.</p>
<p>Install the root CA on your device, then trust it.</p>
<p>
<a class="btn" href="/cert/ios">Download CA (iOS)</a>
<a class="btn" href="/cert/macos">Download CA (macOS)</a>
</p>
<h3>iOS Simulator</h3>
<ol>
<li>Run on the host Mac:<br><code>xcrun simctl keychain booted add-root-cert /path/to/packetpeek-ca.pem</code></li>
<li>Or use the “Configure iOS Simulator” button inside the PacketPeek app.</li>
</ol>
<h3>Physical iOS device</h3>
<ol>
<li>Set Wi-Fi proxy to this Mac's IP at port <code>8080</code>.</li>
<li>Open this page on the device, tap the iOS button above to install the profile.</li>
<li>Settings → General → About → Certificate Trust Settings → enable PacketPeek CA.</li>
</ol>
<h3>macOS</h3>
<ol>
<li>Download the macOS button above.</li>
<li>Open Keychain Access → System → drag the .pem → set “Always Trust”.</li>
<li>System Settings → Network → Proxies → HTTP/HTTPS = <code>127.0.0.1:8080</code>.</li>
</ol>
</body>
</html>`
