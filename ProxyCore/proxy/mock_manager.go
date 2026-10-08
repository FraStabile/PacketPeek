package proxy

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type MockResponse struct {
	ID          string `json:"id"`
	Method      string `json:"method"`
	Host        string `json:"host"`
	Path        string `json:"path"`
	IsRegex     bool   `json:"is_regex"`
	StatusCode  int    `json:"status_code"`
	LatencyMs   int    `json:"latency_ms"`
	Response    string `json:"response"`
	ContentType string `json:"content_type"`
	IsActive    bool   `json:"is_active"`
}

type compiledMock struct {
	MockResponse
	rx *regexp.Regexp // nil if !IsRegex
}

type MockManager struct {
	mocks []compiledMock
	mu    sync.RWMutex
	file  string
}

func NewMockManager(configFile string) *MockManager {
	manager := &MockManager{file: configFile}
	if err := manager.loadFromFile(); err != nil && !os.IsNotExist(err) {
		log.Printf("mock manager load error: %v", err)
	}
	return manager
}

// writeAtomic writes the file via a temp file + rename so a crash mid-write
// never leaves a half-written mocks.json on disk. Permissions: 0600.
func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".mocks-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func (m *MockManager) saveToFileLocked() error {
	plain := make([]MockResponse, 0, len(m.mocks))
	for _, c := range m.mocks {
		plain = append(plain, c.MockResponse)
	}
	data, err := json.MarshalIndent(plain, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(m.file, data)
}

func (m *MockManager) loadFromFile() error {
	data, err := os.ReadFile(m.file)
	if err != nil {
		return err
	}
	var raw []MockResponse
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	compiled := make([]compiledMock, 0, len(raw))
	for _, r := range raw {
		c := compiledMock{MockResponse: r}
		if r.IsRegex && r.Path != "" {
			if rx, err := regexp.Compile(r.Path); err == nil {
				c.rx = rx
			} else {
				log.Printf("mock %s has invalid regex %q: %v (will not match)", r.ID, r.Path, err)
			}
		}
		compiled = append(compiled, c)
	}
	m.mu.Lock()
	m.mocks = compiled
	m.mu.Unlock()
	return nil
}

func (m *MockManager) AddMock(mock MockResponse) error {
	if mock.ID == "" {
		mock.ID = generateMockID(mock.Method, mock.Path, mock.Host)
	}
	c := compiledMock{MockResponse: mock}
	if mock.IsRegex && mock.Path != "" {
		rx, err := regexp.Compile(mock.Path)
		if err != nil {
			return fmt.Errorf("invalid regex %q: %w", mock.Path, err)
		}
		c.rx = rx
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	for i, existing := range m.mocks {
		if strings.EqualFold(existing.Method, mock.Method) &&
			existing.Path == mock.Path &&
			existing.Host == mock.Host {
			m.mocks[i] = c
			return m.saveToFileLocked()
		}
	}
	m.mocks = append(m.mocks, c)
	return m.saveToFileLocked()
}

func (m *MockManager) ListMocks() []MockResponse {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]MockResponse, 0, len(m.mocks))
	for _, c := range m.mocks {
		out = append(out, c.MockResponse)
	}
	return out
}

// Match returns the first active mock for method + host + URL.
//
//   - Host: compared by hostname only, case-insensitively, on both sides. The
//     port is ignored, so a mock for "api.example.com" matches the CONNECT
//     target "api.example.com:443", and mocks saved as "host:port" still work.
//     An empty mock host matches any host.
//   - Exact mocks compare mock.Path with u.Path, i.e. without the query
//     string: "/users" matches "/users?page=2".
//   - Regex mocks are evaluated against u.RequestURI() (path + "?" + query),
//     so a pattern can target query parameters when needed. Patterns aren't
//     implicitly anchored: "^/users" matches "/users?page=2" too.
//
// Go's regexp is RE2 (linear time, no backtracking), so patterns can't ReDoS
// and need no timeout.
func (m *MockManager) Match(method, host string, u *url.URL) (*MockResponse, bool) {
	if u == nil {
		return nil, false
	}
	method = strings.ToUpper(method)
	host = hostnameOnly(host)
	m.mu.RLock()
	defer m.mu.RUnlock()
	for i := range m.mocks {
		mock := &m.mocks[i]
		if !mock.IsActive {
			continue
		}
		if strings.ToUpper(mock.Method) != method {
			continue
		}
		if mock.Host != "" && hostnameOnly(mock.Host) != host {
			continue
		}
		var hit bool
		if mock.IsRegex {
			hit = mock.rx != nil && mock.rx.MatchString(u.RequestURI())
		} else {
			hit = mock.Path == u.Path
		}
		if hit {
			resp := mock.MockResponse
			return &resp, true
		}
	}
	return nil, false
}

// hostnameOnly lowercases h and strips any port and IPv6 brackets.
func hostnameOnly(h string) string {
	if host, _, err := net.SplitHostPort(h); err == nil {
		h = host
	}
	return strings.ToLower(strings.TrimSuffix(strings.Trim(h, "[]"), "."))
}

// EffectiveStatus is the status code actually sent for a mock (0 means 200).
func (m *MockResponse) EffectiveStatus() int {
	if m.StatusCode == 0 {
		return http.StatusOK
	}
	return m.StatusCode
}

// EffectiveContentType is the Content-Type actually sent for a mock.
func (m *MockResponse) EffectiveContentType() string {
	if m.ContentType == "" {
		return "application/json"
	}
	return m.ContentType
}

// Delay sleeps for the mock's configured latency.
func (m *MockResponse) Delay() {
	if m.LatencyMs > 0 {
		time.Sleep(time.Duration(m.LatencyMs) * time.Millisecond)
	}
}

func (m *MockManager) DeleteMockByID(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	index := -1
	for i, mock := range m.mocks {
		if mock.ID == id {
			index = i
			break
		}
	}
	if index == -1 {
		return fmt.Errorf("mock %s not found", id)
	}
	m.mocks = append(m.mocks[:index], m.mocks[index+1:]...)
	return m.saveToFileLocked()
}

func generateMockID(method, path, host string) string {
	data := strings.ToUpper(method) + path + host
	hash := sha1.Sum([]byte(data))
	return hex.EncodeToString(hash[:])
}
