package proxy

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"proxy_core/cert"
)

// newTestProxy returns a proxy front-end (httptest server) whose upstream
// transport may reach loopback, since test upstreams live on 127.0.0.1.
func newTestProxy(t *testing.T) (*ProxyServer, *httptest.Server) {
	t.Helper()
	cm, err := cert.NewCertManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxyServer(cm, t.TempDir())
	p.allowLoopbackTargets = true
	p.upstream.DialContext = (&net.Dialer{Timeout: 5 * time.Second}).DialContext
	front := httptest.NewServer(p)
	t.Cleanup(front.Close)
	return p, front
}

func proxiedClient(t *testing.T, front *httptest.Server) *http.Client {
	t.Helper()
	u, _ := url.Parse(front.URL)
	return &http.Client{Transport: &http.Transport{
		Proxy:           http.ProxyURL(u),
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}}
}

// slowStreamHandler writes "chunk-1", then waits for release before writing
// "chunk-2". A proxy that buffers the whole body can never deliver chunk-1.
func slowStreamHandler(release <-chan struct{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "data: chunk-1\n\n")
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-time.After(10 * time.Second): // safety net; the test releases earlier
		}
		io.WriteString(w, "data: chunk-2\n\n")
	}
}

func assertStreams(t *testing.T, client *http.Client, target string, release chan struct{}) {
	t.Helper()
	type result struct {
		resp  *http.Response
		br    *bufio.Reader
		first string
		err   error
	}
	// Time the whole request → first chunk: with a buffering proxy even the
	// response headers only arrive once the upstream body is complete.
	got := make(chan result, 1)
	go func() {
		resp, err := client.Get(target)
		if err != nil {
			got <- result{err: err}
			return
		}
		br := bufio.NewReader(resp.Body)
		line, err := br.ReadString('\n')
		got <- result{resp, br, line, err}
	}()

	var r result
	select {
	case r = <-got:
	case <-time.After(2 * time.Second):
		close(release)
		t.Fatal("first chunk not delivered while the upstream was still streaming: response is buffered")
	}
	close(release)
	if r.err != nil {
		t.Fatal(r.err)
	}
	defer r.resp.Body.Close()
	if r.resp.StatusCode != http.StatusOK || !strings.Contains(r.first, "chunk-1") {
		t.Fatalf("status %d, first line %q", r.resp.StatusCode, r.first)
	}
	rest, _ := io.ReadAll(r.br)
	if !strings.Contains(string(rest), "chunk-2") {
		t.Fatalf("missing chunk-2, got %q", rest)
	}
}

func TestHTTPSStreamsChunkedResponse(t *testing.T) {
	release := make(chan struct{})
	upstream := httptest.NewTLSServer(slowStreamHandler(release))
	defer upstream.Close()
	_, front := newTestProxy(t)
	assertStreams(t, proxiedClient(t, front), upstream.URL+"/stream", release)
}

func TestHTTPStreamsChunkedResponse(t *testing.T) {
	release := make(chan struct{})
	upstream := httptest.NewServer(slowStreamHandler(release))
	defer upstream.Close()
	_, front := newTestProxy(t)
	assertStreams(t, proxiedClient(t, front), upstream.URL+"/stream", release)
}

// Bodies larger than the log cap must reach both ends intact while the log
// copy is truncated to maxLoggedBodyBytes.
func TestHTTPSLargeBodiesAreStreamedAndLogTruncated(t *testing.T) {
	const size = 3 * maxLoggedBodyBytes
	payload := bytes.Repeat([]byte("x"), size)

	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, _ := io.ReadAll(r.Body)
		if len(got) != size {
			t.Errorf("upstream received %d request bytes, want %d", len(got), size)
		}
		w.Write(payload)
	}))
	defer upstream.Close()
	p, front := newTestProxy(t)
	client := proxiedClient(t, front)

	resp, err := client.Post(upstream.URL+"/upload", "application/octet-stream", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if len(got) != size {
		t.Fatalf("client received %d bytes, want %d", len(got), size)
	}

	// Close idle tunnels so the log entry is surely written.
	client.CloseIdleConnections()
	var entry *RequestLog
	deadline := time.Now().Add(2 * time.Second)
	for entry == nil && time.Now().Before(deadline) {
		for _, l := range p.GetLogs() {
			if strings.HasSuffix(l.URL, "/upload") {
				l := l
				entry = &l
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if entry == nil {
		t.Fatal("no log entry for /upload")
	}
	for name, body := range map[string]string{"request": entry.RequestBody, "response": entry.ResponseBody} {
		if len(body) > maxLoggedBodyBytes+100 || !strings.Contains(body, "[truncated") {
			t.Errorf("%s body in log: %d bytes, truncated marker=%v", name, len(body), strings.Contains(body, "[truncated"))
		}
	}
}

// Inside the tunnel, redirects must be passed through, not followed.
func TestHTTPSDoesNotFollowRedirects(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/old" {
			http.Redirect(w, r, "/new", http.StatusFound)
			return
		}
		io.WriteString(w, "new")
	}))
	defer upstream.Close()
	_, front := newTestProxy(t)
	client := proxiedClient(t, front)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	resp, err := client.Get(upstream.URL + "/old")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status %d, want 302 passed through", resp.StatusCode)
	}
}

// connectRaw opens a raw TCP connection to the proxy and sends CONNECT.
func connectRaw(t *testing.T, front *httptest.Server) (net.Conn, *bufio.Reader) {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(front.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	io.WriteString(conn, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
	br := bufio.NewReader(conn)
	line, err := br.ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatalf("CONNECT reply = %q, %v", line, err)
	}
	for { // drain headers
		l, err := br.ReadString('\n')
		if err != nil || l == "\r\n" {
			break
		}
	}
	return conn, br
}

// waitClosed fails unless the server closes conn within d.
func waitClosed(t *testing.T, conn net.Conn, br *bufio.Reader, d time.Duration) {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(d))
	if _, err := br.ReadByte(); err == nil {
		t.Fatal("unexpected data from proxy")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("silent tunnel not closed by the proxy in time")
	}
}

func TestTunnelHandshakeTimeoutClosesSilentClient(t *testing.T) {
	p, front := newTestProxy(t)
	p.tunnelHandshakeTimeout = 200 * time.Millisecond
	conn, br := connectRaw(t, front) // never starts the TLS handshake
	waitClosed(t, conn, br, 3*time.Second)
}

func TestTunnelIdleTimeoutClosesKeepAliveClient(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok")
	}))
	t.Cleanup(upstream.Close)
	p, front := newTestProxy(t)
	p.upstream.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	p.tunnelIdleTimeout = 300 * time.Millisecond

	host := strings.TrimPrefix(upstream.URL, "https://")
	conn, err := net.Dial("tcp", strings.TrimPrefix(front.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "CONNECT "+host+" HTTP/1.1\r\nHost: "+host+"\r\n\r\n")
	br := bufio.NewReader(conn)
	for {
		l, err := br.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if l == "\r\n" {
			break
		}
	}
	tc := tls.Client(conn, &tls.Config{InsecureSkipVerify: true})
	io.WriteString(tc, "GET / HTTP/1.1\r\nHost: "+host+"\r\n\r\n")
	tbr := bufio.NewReader(tc)
	resp, err := http.ReadResponse(tbr, nil)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	// Keep-alive connection now idle: the proxy must close it.
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := tbr.ReadByte(); err == nil {
		t.Fatal("unexpected data")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("idle tunnel not closed by the proxy")
	}
}

// activeTracker wraps h counting ServeHTTP calls still running (a hijacked
// CONNECT tunnel stays "active" until handleHTTPS returns), mirroring main's inFlight.
func activeTracker(h http.Handler, active *atomic.Int64) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		h.ServeHTTP(w, r)
	})
}

func waitZero(t *testing.T, a *atomic.Int64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for a.Load() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("active = %d, want 0", a.Load())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestSilentTunnelReleasesInFlight(t *testing.T) {
	cm, err := cert.NewCertManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxyServer(cm, t.TempDir())
	p.tunnelHandshakeTimeout = 200 * time.Millisecond
	var active atomic.Int64
	front := httptest.NewServer(activeTracker(p, &active))
	defer front.Close()

	conn, br := connectRaw(t, front)
	if active.Load() != 1 {
		t.Fatalf("active = %d while tunnel open, want 1", active.Load())
	}
	waitClosed(t, conn, br, 3*time.Second)
	waitZero(t, &active)
}

// A client that sends headers and half a body, then stalls, must be dropped.
func TestStalledBodyTunnelClosedAndInFlightZero(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
	}))
	defer upstream.Close()
	cm, err := cert.NewCertManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxyServer(cm, t.TempDir())
	p.allowLoopbackTargets = true
	p.upstream.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	p.tunnelIdleTimeout = 300 * time.Millisecond
	var active atomic.Int64
	front := httptest.NewServer(activeTracker(p, &active))
	defer front.Close()

	host := strings.TrimPrefix(upstream.URL, "https://")
	conn, err := net.Dial("tcp", strings.TrimPrefix(front.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "CONNECT "+host+" HTTP/1.1\r\nHost: "+host+"\r\n\r\n")
	br := bufio.NewReader(conn)
	for {
		l, err := br.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if l == "\r\n" {
			break
		}
	}
	tc := tls.Client(conn, &tls.Config{InsecureSkipVerify: true})
	io.WriteString(tc, "POST / HTTP/1.1\r\nHost: "+host+"\r\nContent-Length: 1000\r\n\r\nhalf")
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := bufio.NewReader(tc).ReadByte(); err == nil {
		// a 502 may legitimately be written before closing
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("stalled-body tunnel not closed by the proxy")
	}
	waitZero(t, &active)
}

func TestIdleConnRenewsDeadlineOnActivity(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	ic := newIdleConn(a, 300*time.Millisecond)
	go func() {
		for i := 0; i < 4; i++ { // 600ms total > timeout, but never idle 300ms
			time.Sleep(100 * time.Millisecond)
			b.Write([]byte("x"))
		}
	}()
	buf := make([]byte, 1)
	for i := 0; i < 4; i++ {
		if _, err := ic.Read(buf); err != nil {
			t.Fatalf("active connection cut at read %d: %v", i, err)
		}
	}
	if _, err := ic.Read(buf); err == nil {
		t.Fatal("idle read should time out")
	}
}

// A client that sends a request but never reads the (large) response must be
// dropped by the write deadline once socket buffers fill.
func TestNonReadingClientTunnelClosedAndInFlightZero(t *testing.T) {
	chunk := make([]byte, 1<<20)
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < 256; i++ { // up to 256 MiB, far above loopback buffers
			if _, err := w.Write(chunk); err != nil {
				return
			}
		}
	}))
	defer upstream.Close()
	cm, err := cert.NewCertManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxyServer(cm, t.TempDir())
	p.allowLoopbackTargets = true
	p.upstream.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	p.tunnelIdleTimeout = 300 * time.Millisecond
	var active atomic.Int64
	front := httptest.NewServer(activeTracker(p, &active))
	defer front.Close()

	host := strings.TrimPrefix(upstream.URL, "https://")
	conn, err := net.Dial("tcp", strings.TrimPrefix(front.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "CONNECT "+host+" HTTP/1.1\r\nHost: "+host+"\r\n\r\n")
	br := bufio.NewReader(conn)
	for {
		l, err := br.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if l == "\r\n" {
			break
		}
	}
	tc := tls.Client(conn, &tls.Config{InsecureSkipVerify: true})
	io.WriteString(tc, "GET / HTTP/1.1\r\nHost: "+host+"\r\n\r\n")
	// ...and never read. The proxy must give up on its own.
	deadline := time.Now().Add(10 * time.Second)
	time.Sleep(100 * time.Millisecond) // let the tunnel become active
	for active.Load() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("tunnel with non-reading client not released")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
