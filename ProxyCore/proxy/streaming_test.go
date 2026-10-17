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
