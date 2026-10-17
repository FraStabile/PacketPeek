package proxy

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newTestMockManager(t *testing.T, mocks ...MockResponse) *MockManager {
	t.Helper()
	mm := NewMockManager(filepath.Join(t.TempDir(), "mocks.json"))
	for _, m := range mocks {
		if err := mm.AddMock(m); err != nil {
			t.Fatal(err)
		}
	}
	return mm
}

func mustParse(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func TestMockMatch(t *testing.T) {
	mm := newTestMockManager(t,
		MockResponse{ID: "exact", Method: "GET", Host: "api.example.com", Path: "/users", IsActive: true},
		MockResponse{ID: "withport", Method: "GET", Host: "legacy.example.com:443", Path: "/v1", IsActive: true},
		MockResponse{ID: "regex", Method: "POST", Host: "api.example.com", Path: `^/orders/\d+$`, IsRegex: true, IsActive: true},
		MockResponse{ID: "regexquery", Method: "GET", Host: "api.example.com", Path: `^/search\?q=go`, IsRegex: true, IsActive: true},
		MockResponse{ID: "anyhost", Method: "DELETE", Path: "/session", IsActive: true},
		MockResponse{ID: "inactive", Method: "GET", Host: "api.example.com", Path: "/disabled", IsActive: false},
	)

	cases := []struct {
		name, method, host, uri, want string
	}{
		{"exact, host without port", "GET", "api.example.com", "/users", "exact"},
		{"exact, host with port", "GET", "api.example.com:443", "/users", "exact"},
		{"host is case-insensitive", "get", "API.Example.com", "/users", "exact"},
		{"exact ignores query", "GET", "api.example.com", "/users?page=2&sort=asc", "exact"},
		{"exact is not a prefix match", "GET", "api.example.com", "/users/1", ""},
		{"wrong host", "GET", "other.example.com", "/users", ""},
		{"wrong method", "POST", "api.example.com", "/users", ""},
		{"mock saved with port matches any port", "GET", "legacy.example.com", "/v1", "withport"},
		{"regex", "POST", "api.example.com:443", "/orders/42", "regex"},
		{"regex anchored, query breaks $", "POST", "api.example.com", "/orders/42?x=1", ""},
		{"regex no match", "POST", "api.example.com", "/orders/abc", ""},
		{"regex sees the query", "GET", "api.example.com", "/search?q=golang", "regexquery"},
		{"empty mock host matches any host", "DELETE", "whatever.test:8443", "/session", "anyhost"},
		{"inactive mock never matches", "GET", "api.example.com", "/disabled", ""},
	}
	for _, c := range cases {
		got, ok := mm.Match(c.method, c.host, mustParse(t, c.uri))
		gotID := ""
		if ok {
			gotID = got.ID
		}
		if gotID != c.want {
			t.Errorf("%s: Match(%s %s%s) = %q, want %q", c.name, c.method, c.host, c.uri, gotID, c.want)
		}
	}
}

func TestMockEffectiveDefaults(t *testing.T) {
	m := MockResponse{}
	if m.EffectiveStatus() != 200 || m.EffectiveContentType() != "application/json" {
		t.Fatalf("defaults: %d %q", m.EffectiveStatus(), m.EffectiveContentType())
	}
	m = MockResponse{StatusCode: 418, ContentType: "text/plain"}
	if m.EffectiveStatus() != 418 || m.EffectiveContentType() != "text/plain" {
		t.Fatalf("explicit: %d %q", m.EffectiveStatus(), m.EffectiveContentType())
	}
}

// End to end through the CONNECT path: host:443 + query string must match,
// latency must apply, and the log must say 200 + mocked.
func TestHTTPSMockServedWithLatencyAndLogged(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("mocked request must not reach the upstream")
	}))
	defer upstream.Close()
	upURL := mustParse(t, upstream.URL)

	p, front := newTestProxy(t)
	if err := p.MockManager().AddMock(MockResponse{
		Method:    "GET",
		Host:      upURL.Hostname(), // no port, as the app now saves it
		Path:      "/api/me",
		LatencyMs: 300,
		Response:  `{"mocked":true}`,
		IsActive:  true,
		// StatusCode 0 → 200
	}); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	resp, err := proxiedClient(t, front).Get(upstream.URL + "/api/me?cache=0")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	elapsed := time.Since(start)

	if resp.StatusCode != 200 || string(body) != `{"mocked":true}` || resp.Header.Get("X-Mock-Response") != "true" {
		t.Fatalf("got %d %q headers=%v", resp.StatusCode, body, resp.Header)
	}
	if elapsed < 300*time.Millisecond {
		t.Errorf("latency_ms not applied: request took %v", elapsed)
	}

	var entry *RequestLog
	for _, l := range p.GetLogs() {
		if strings.Contains(l.URL, "/api/me") {
			l := l
			entry = &l
		}
	}
	if entry == nil {
		t.Fatal("mocked request not logged")
	}
	if entry.StatusCode != 200 || !entry.Mocked {
		t.Errorf("log: status=%d mocked=%v, want 200/true", entry.StatusCode, entry.Mocked)
	}
	raw, _ := json.Marshal(entry)
	if !strings.Contains(string(raw), `"mocked":true`) {
		t.Errorf("JSON lacks mocked flag: %s", raw)
	}
}

func TestAddMockUpsertsByID(t *testing.T) {
	mm := newTestMockManager(t, MockResponse{ID: "m1", Method: "GET", Host: "a.test", Path: "/x", IsRegex: false, ContentType: "text/plain", IsActive: false, StatusCode: 200})

	// The edit sheet resends the same id with new status/latency.
	edited := MockResponse{ID: "m1", Method: "GET", Host: "a.test", Path: "/x", ContentType: "text/plain", IsActive: false, StatusCode: 503, LatencyMs: 50}
	if err := mm.AddMock(edited); err != nil {
		t.Fatal(err)
	}
	list := mm.ListMocks()
	if len(list) != 1 {
		t.Fatalf("got %d mocks, want 1 (edit must not duplicate)", len(list))
	}
	if got := list[0]; got.StatusCode != 503 || got.LatencyMs != 50 || got.IsActive || got.ContentType != "text/plain" {
		t.Fatalf("edit not applied / flags lost: %+v", got)
	}

	// Persisted to disk.
	reloaded := NewMockManager(mm.file)
	if l := reloaded.ListMocks(); len(l) != 1 || l[0].StatusCode != 503 {
		t.Fatalf("not persisted: %+v", l)
	}
}
