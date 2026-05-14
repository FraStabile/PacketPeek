package proxy

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
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

// Match returns the first matching mock for the given method+host+pathOrURI.
// Pathish is whatever the caller has — it's matched as-is against mock.Path
// (exact) or against the precompiled regex. Regex evaluation is bounded by
// regexMatchTimeout to mitigate ReDoS.
func (m *MockManager) Match(method, host, pathish string) (*MockResponse, bool) {
	method = strings.ToUpper(method)
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
		if mock.Host != "" && mock.Host != host {
			continue
		}
		if mock.IsRegex {
			if mock.rx != nil && matchWithTimeout(mock.rx, pathish, regexMatchTimeout) {
				resp := mock.MockResponse
				return &resp, true
			}
			continue
		}
		if mock.Path == pathish {
			resp := mock.MockResponse
			return &resp, true
		}
	}
	return nil, false
}

const regexMatchTimeout = 50 * time.Millisecond

// matchWithTimeout runs rx.MatchString in a goroutine; if it doesn't return within
// timeout we treat it as no-match (best-effort ReDoS mitigation — Go's regexp is
// linear by design but we keep the guard for safety against future pattern engines).
func matchWithTimeout(rx *regexp.Regexp, s string, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	done := make(chan bool, 1)
	go func() {
		done <- rx.MatchString(s)
	}()
	select {
	case ok := <-done:
		return ok
	case <-ctx.Done():
		log.Printf("regex match timed out after %v for pattern %q", timeout, rx.String())
		return false
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
