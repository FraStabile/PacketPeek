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
	upstreamDialTimeout    = 10 * time.Second
	upstreamTLSHandshake   = 10 * time.Second
	upstreamResponseHeader = 60 * time.Second
	upstreamIdleConn       = 90 * time.Second
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

	// Mocked is true when the response was synthesized from a mock rule and
	// the request never reached the real server.
	Mocked bool `json:"mocked"`
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
	// allowLoopbackTargets disables checkTarget. Tests only: their upstreams
	// are httptest servers on 127.0.0.1.
	allowLoopbackTargets bool
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
		// Refuses loopback / control-port targets after DNS resolution (see target_guard.go).
		DialContext: guardedDialContext(&net.Dialer{
			Timeout:   upstreamDialTimeout,
			KeepAlive: 30 * time.Second,
		}),
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

func (p *ProxyServer) checkTarget(hostport, defaultPort string) error {
	if p.allowLoopbackTargets {
		return nil
	}
	return checkTarget(hostport, defaultPort)
}

func (p *ProxyServer) MockManager() *MockManager          { return p.mockManager }
func (p *ProxyServer) AppsManager() *MonitoredAppsManager { return p.appsManager }
func (p *ProxyServer) CertManager() *cert.CertManager     { return p.certManager }

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

	target, defaultPort := r.URL.Host, "80"
	if r.Method == http.MethodConnect {
		defaultPort = "443"
	}
	if target == "" {
		target = r.Host
	}
	if err := p.checkTarget(target, defaultPort); err != nil {
		log.Printf("Refused %s to %s from %s: %v", r.Method, sanitizeLogValue(target), sanitizeLogValue(r.RemoteAddr), err)
		logEntry.StatusCode = http.StatusForbidden
		p.addLog(logEntry)
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}

	if r.Method == http.MethodConnect {
		p.handleHTTPS(w, r)
		return
	}

	for k, v := range r.Header {
		logEntry.RequestHeaders[k] = strings.Join(v, ", ")
	}

	// Request body: streamed upstream, only the first maxLoggedBodyBytes are kept for the log.
	reqBody := newHeadBuffer()
	reqEncoding := r.Header.Get("Content-Encoding")

	// Plain HTTP mock interception (CONNECT path handles HTTPS separately).
	if mockResp, _ := p.mockManager.Match(r.Method, hostnameOnly(r.Host), r.URL); mockResp != nil {
		captureAndDrain(r.Body, reqBody)
		logEntry.RequestBody = reqBody.String(reqEncoding)
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
	if r.Body != nil && r.Body != http.NoBody {
		outReq.Body = teeBody(r.Body, reqBody)
	}

	resp, err := p.upstream.RoundTrip(outReq)
	logEntry.RequestBody = reqBody.String(reqEncoding)
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

	// Stream to the client (flushing each chunk, for SSE), keeping a bounded copy for the log.
	respBody := newHeadBuffer()
	_, _ = io.Copy(newFlushWriter(w), io.TeeReader(resp.Body, respBody))
	logEntry.ResponseBody = respBody.String(resp.Header.Get("Content-Encoding"))

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
	m.Delay()
	ct := m.EffectiveContentType()
	w.Header().Set("Content-Type", ct)
	w.Header().Set("X-Mock-Response", "true")
	w.WriteHeader(m.EffectiveStatus())
	_, _ = w.Write([]byte(m.Response))

	entry.Mocked = true
	entry.StatusCode = m.EffectiveStatus()
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
	// The captured body may be truncated, so a short read is expected: keep
	// whatever decoded cleanly.
	out, err := io.ReadAll(io.LimitReader(gz, maxLoggedBodyBytes))
	if err != nil && len(out) == 0 {
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

		reqBody := newHeadBuffer()
		reqEncoding := req.Header.Get("Content-Encoding")

		// Mock match: method + hostname (no port) + path; see MockManager.Match.
		if mockResp, _ := p.mockManager.Match(req.Method, hostnameOnly(r.Host), req.URL); mockResp != nil {
			// Consume the body so the next request on this connection parses cleanly.
			captureAndDrain(req.Body, reqBody)
			reqLog.RequestBody = reqBody.String(reqEncoding)
			mockResp.Delay()
			writeMockToTLSConn(tlsConn, mockResp)
			reqLog.Mocked = true
			reqLog.StatusCode = mockResp.EffectiveStatus()
			reqLog.ResponseHeaders = map[string]string{"X-Mock-Response": "true", "Content-Type": mockResp.EffectiveContentType()}
			reqLog.ResponseBody = mockResp.Response
			reqLog.Completed = time.Now()
			reqLog.ResponseTime = reqLog.Completed.Sub(reqLog.Timestamp)
			p.addLog(reqLog)
			continue
		}

		// The request body is streamed upstream (never fully buffered).
		var body io.ReadCloser = http.NoBody
		if req.ContentLength != 0 {
			body = teeBody(req.Body, reqBody)
		}
		outURL := "https://" + r.Host + req.URL.RequestURI()
		outReq, err := http.NewRequestWithContext(req.Context(), req.Method, outURL, body)
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			return
		}
		outReq.ContentLength = req.ContentLength // -1 when the client sent chunked
		// Copy request headers, but strip hop-by-hop entries.
		for k, v := range req.Header {
			if isHopHeader(k) {
				continue
			}
			outReq.Header[k] = v
		}

		// RoundTrip, not http.Client: no total timeout (would kill long
		// downloads / SSE; the transport's dial/TLS/header timeouts still
		// apply) and no redirect following (the client must see the 3xx).
		resp, err := p.upstream.RoundTrip(outReq)
		reqLog.RequestBody = reqBody.String(reqEncoding)
		if err != nil {
			reqLog.StatusCode = http.StatusBadGateway
			p.addLog(reqLog)
			writeBadGateway(tlsConn, err)
			return
		}

		reqLog.StatusCode = resp.StatusCode
		for k, v := range resp.Header {
			reqLog.ResponseHeaders[k] = strings.Join(v, ", ")
		}

		// Stream the response to the client as it arrives. resp.Write keeps
		// upstream framing (Content-Length, chunked, or close-delimited) and
		// copies the body chunk by chunk; tls.Conn writes are not buffered,
		// so chunked / SSE bodies reach the client immediately. A bounded
		// copy goes to the log via the tee.
		respBody := newHeadBuffer()
		resp.Body = teeBody(resp.Body, respBody)
		writeErr := resp.Write(tlsConn)
		resp.Body.Close()
		reqLog.ResponseBody = respBody.String(resp.Header.Get("Content-Encoding"))
		reqLog.Completed = time.Now()
		reqLog.ResponseTime = reqLog.Completed.Sub(reqLog.Timestamp)
		p.addLog(reqLog)

		if writeErr != nil {
			log.Printf("Error writing tunneled response: %v", sanitizeError(writeErr))
			return
		}
		// Close-delimited response (or Connection: close): the tunnel ends here.
		if resp.Close || req.Close {
			return
		}
	}
}

// writeBadGateway answers a tunneled request whose upstream failed, so the
// client gets a response instead of a silently dropped connection.
func writeBadGateway(conn *tls.Conn, cause error) {
	body := []byte("upstream error: " + sanitizeError(cause))
	resp := &http.Response{
		StatusCode:    http.StatusBadGateway,
		ProtoMajor:    1,
		ProtoMinor:    1,
		Close:         true,
		ContentLength: int64(len(body)),
		Body:          io.NopCloser(bytes.NewReader(body)),
		Header:        http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
	}
	_ = resp.Write(conn)
}

// writeMockToTLSConn frames a mock response via http.Response.Write to avoid
// CRLF / header-injection from attacker-controlled body or content-type.
func writeMockToTLSConn(conn *tls.Conn, m *MockResponse) {
	body := []byte(m.Response)
	status := m.EffectiveStatus()
	resp := &http.Response{
		Status:        fmt.Sprintf("%d %s", status, http.StatusText(status)),
		StatusCode:    status,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Header: http.Header{
			"Content-Type":    []string{m.EffectiveContentType()},
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
