package proxy

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func stubLocalIPs(t *testing.T, ips ...string) {
	t.Helper()
	orig := localIPs
	localIPs = func() []net.IP {
		out := make([]net.IP, 0, len(ips))
		for _, s := range ips {
			out = append(out, net.ParseIP(s))
		}
		return out
	}
	t.Cleanup(func() { localIPs = orig })
}

func TestCheckTarget(t *testing.T) {
	stubLocalIPs(t, "192.168.1.10", "fe80::1")
	cases := []struct {
		target, defPort string
		blocked         bool
	}{
		{"127.0.0.1:8081", "80", true},
		{"127.0.0.1", "80", true},
		{"127.4.5.6:22", "443", true},
		{"[::1]:8081", "443", true},
		{"localhost:8081", "80", true},
		{"LOCALHOST.:3000", "80", true},
		{"api.localhost", "443", true},
		{"0.0.0.0:8081", "80", true},
		{"192.168.1.10:8081", "80", true}, // this Mac's LAN IP, API port
		{"192.168.1.10:8080", "80", true}, // proxy loop
		{"192.168.1.10:3000", "80", false},
		{"192.168.1.10", "443", false},
		{"192.168.1.20:8081", "80", false}, // another machine
		{"example.com:443", "443", false},
		{"example.com", "80", false},
	}
	for _, c := range cases {
		err := checkTarget(c.target, c.defPort)
		if (err != nil) != c.blocked {
			t.Errorf("checkTarget(%q) err=%v, want blocked=%v", c.target, err, c.blocked)
		}
	}
}

func TestGuardedDialControlBlocksResolvedLoopback(t *testing.T) {
	stubLocalIPs(t)
	if err := guardedDialControl("tcp", "127.0.0.1:8081", nil); err == nil {
		t.Fatal("dial to resolved loopback should be refused")
	}
	if err := guardedDialControl("tcp", "[::1]:443", nil); err == nil {
		t.Fatal("dial to resolved ::1 should be refused")
	}
	if err := guardedDialControl("tcp", "93.184.216.34:443", nil); err != nil {
		t.Fatalf("public IP refused: %v", err)
	}
}

func TestProxyRefusesLoopbackTargets(t *testing.T) {
	p := NewProxyServer(nil, t.TempDir())
	for _, req := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8081/api/mocks", nil),
		httptest.NewRequest(http.MethodGet, "http://localhost:8081/logs", nil),
		{Method: http.MethodConnect, Host: "127.0.0.1:8081", URL: mustURL(t, "//127.0.0.1:8081"), Header: http.Header{}, RemoteAddr: "192.168.1.50:5555"},
	} {
		rec := httptest.NewRecorder()
		p.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s %s: status %d, want 403", req.Method, req.Host, rec.Code)
		}
	}
	if logs := p.GetLogs(); len(logs) != 3 || logs[0].StatusCode != http.StatusForbidden {
		t.Errorf("refused requests should be logged with 403, got %+v", logs)
	}
}

// Even if the early check is bypassed (hostname resolving to 127.0.0.1), the
// transport's dial guard must refuse to connect.
func TestUpstreamTransportRefusesLoopbackDial(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("loopback backend must not be reached")
	}))
	defer backend.Close()

	req, _ := http.NewRequest(http.MethodGet, backend.URL, nil)
	if _, err := newUpstreamTransport().RoundTrip(req); err == nil {
		t.Fatal("expected dial to loopback to fail")
	}
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}
