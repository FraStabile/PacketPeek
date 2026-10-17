package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"proxy_core/proxy"
)

const testToken = "s3cret"

func newTestHandler(t *testing.T) http.Handler {
	t.Helper()
	s := NewAPIServer(proxy.NewProxyServer(nil, t.TempDir()), testToken, t.TempDir())
	return s.HTTPServer("127.0.0.1:8081").Handler
}

func do(h http.Handler, method, target, host string, headers map[string]string, body string) int {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.Host = host
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

var authed = map[string]string{"Authorization": "Bearer " + testToken}

func TestHostHeaderAllowlist(t *testing.T) {
	h := newTestHandler(t)
	for host, want := range map[string]int{
		"127.0.0.1:8081":     http.StatusOK,
		"localhost:8081":     http.StatusOK,
		"evil.com:8081":      http.StatusForbidden, // DNS rebinding
		"127.0.0.1":          http.StatusForbidden,
		"127.0.0.1:9999":     http.StatusForbidden,
		"192.168.1.10:8081":  http.StatusForbidden,
		"localhost.evil.com": http.StatusForbidden,
	} {
		if got := do(h, http.MethodGet, "/health", host, nil, ""); got != want {
			t.Errorf("Host %q: status %d, want %d", host, got, want)
		}
	}
}

func TestOriginCheck(t *testing.T) {
	h := newTestHandler(t)
	for origin, want := range map[string]int{
		"":                          http.StatusOK,
		"http://localhost:3000":     http.StatusOK,
		"https://127.0.0.1":         http.StatusOK,
		"http://localhost.evil.com": http.StatusForbidden,
		"http://127.0.0.1.nip.io":   http.StatusForbidden,
		"https://evil.com":          http.StatusForbidden,
		"null":                      http.StatusForbidden,
		"file://":                   http.StatusForbidden,
	} {
		hdr := map[string]string{"Authorization": "Bearer " + testToken}
		if origin != "" {
			hdr["Origin"] = origin
		}
		if got := do(h, http.MethodGet, "/api/mocks", "127.0.0.1:8081", hdr, ""); got != want {
			t.Errorf("Origin %q: status %d, want %d", origin, got, want)
		}
	}
}

func TestAuthAlwaysRequired(t *testing.T) {
	h := newTestHandler(t)
	host := "127.0.0.1:8081"
	if got := do(h, http.MethodGet, "/api/mocks", host, nil, ""); got != http.StatusUnauthorized {
		t.Errorf("no token: %d, want 401", got)
	}
	if got := do(h, http.MethodGet, "/api/mocks", host, map[string]string{"Authorization": "Bearer nope"}, ""); got != http.StatusUnauthorized {
		t.Errorf("wrong token: %d, want 401", got)
	}
	if got := do(h, http.MethodGet, "/api/mocks", host, authed, ""); got != http.StatusOK {
		t.Errorf("header token: %d, want 200", got)
	}
	if got := do(h, http.MethodGet, "/logs?token="+testToken, host, nil, ""); got != http.StatusOK {
		t.Errorf("query token: %d, want 200", got)
	}
	if got := do(h, http.MethodGet, "/health", host, nil, ""); got != http.StatusOK {
		t.Errorf("/health must stay public: %d", got)
	}
}

func TestPostRequiresJSON(t *testing.T) {
	h := newTestHandler(t)
	host := "127.0.0.1:8081"
	body := `{"method":"GET","host":"example.com","path":"/x","is_active":true}`
	for ct, want := range map[string]int{
		"":                                  http.StatusUnsupportedMediaType,
		"text/plain":                        http.StatusUnsupportedMediaType,
		"application/x-www-form-urlencoded": http.StatusUnsupportedMediaType,
		"application/jsonp":                 http.StatusUnsupportedMediaType,
		"application/json":                  http.StatusOK,
		"application/json; charset=utf-8":   http.StatusOK,
	} {
		hdr := map[string]string{"Authorization": "Bearer " + testToken}
		if ct != "" {
			hdr["Content-Type"] = ct
		}
		if got := do(h, http.MethodPost, "/api/mocks", host, hdr, body); got != want {
			t.Errorf("Content-Type %q: status %d, want %d", ct, got, want)
		}
	}
}
