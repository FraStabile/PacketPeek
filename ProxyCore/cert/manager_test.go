package cert

import (
	"bytes"
	"crypto/rsa"
	"crypto/x509"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func init() {
	// Keep tests fast; they never touch the real runtime dir (t.TempDir only).
	caKeyBits = 2048
}

func newTestManager(t *testing.T) (*CertManager, string) {
	t.Helper()
	dir := t.TempDir()
	cm, err := NewCertManager(dir)
	if err != nil {
		t.Fatalf("NewCertManager: %v", err)
	}
	return cm, dir
}

func TestGenerateCAWhenMissing(t *testing.T) {
	cm, dir := newTestManager(t)
	if !cm.CACert.IsCA {
		t.Fatal("expected CA cert")
	}
	ki, err := os.Stat(filepath.Join(dir, caKeyName))
	if err != nil || ki.Mode().Perm() != 0600 {
		t.Fatalf("ca.key perm/err: %v %v", ki, err)
	}
	ci, err := os.Stat(filepath.Join(dir, caCertName))
	if err != nil || ci.Mode().Perm() != 0644 {
		t.Fatalf("ca.pem perm/err: %v %v", ci, err)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.Name() != caKeyName && e.Name() != caCertName {
			t.Fatalf("leftover file %s", e.Name())
		}
	}
}

func TestReloadKeepsSameCA(t *testing.T) {
	cm1, dir := newTestManager(t)
	cm2, err := NewCertManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !cm1.CACert.Equal(cm2.CACert) || !cm1.CAKey.Equal(cm2.CAKey) {
		t.Fatal("reload produced a different CA")
	}
}

func TestLoadErrorDoesNotOverwrite(t *testing.T) {
	cases := map[string]func(t *testing.T, dir string){
		"corrupt key": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, caKeyName), []byte("garbage"), 0600)
		},
		"corrupt cert": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, caCertName), []byte("garbage"), 0644)
		},
		"missing cert": func(t *testing.T, dir string) {
			os.Remove(filepath.Join(dir, caCertName))
		},
		"missing key": func(t *testing.T, dir string) {
			os.Remove(filepath.Join(dir, caKeyName))
		},
	}
	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			_, dir := newTestManager(t)
			corrupt(t, dir)
			before := snapshot(t, dir)
			if _, err := NewCertManager(dir); err == nil {
				t.Fatal("expected error")
			}
			after := snapshot(t, dir)
			if len(before) != len(after) {
				t.Fatalf("files changed: %v -> %v", keys(before), keys(after))
			}
			for k, v := range before {
				if !bytes.Equal(v, after[k]) {
					t.Fatalf("%s was modified", k)
				}
			}
		})
	}
}

func TestMismatchedKeyAndCertRejected(t *testing.T) {
	_, dirA := newTestManager(t)
	_, dirB := newTestManager(t)
	keyB, _ := os.ReadFile(filepath.Join(dirB, caKeyName))
	os.WriteFile(filepath.Join(dirA, caKeyName), keyB, 0600)
	if _, err := NewCertManager(dirA); err == nil {
		t.Fatal("expected mismatch error")
	}
}

func TestExpiredCARejected(t *testing.T) {
	dir2 := t.TempDir()
	cm2 := &CertManager{keyPath: filepath.Join(dir2, caKeyName), certPath: filepath.Join(dir2, caCertName)}
	if err := cm2.generateCAWithValidity(-48*time.Hour, -time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := NewCertManager(dir2); err == nil {
		t.Fatal("expected expired CA error")
	}
}

func TestKeyPermissionsTightened(t *testing.T) {
	_, dir := newTestManager(t)
	os.Chmod(filepath.Join(dir, caKeyName), 0644)
	if _, err := NewCertManager(dir); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(filepath.Join(dir, caKeyName))
	if info.Mode().Perm() != 0600 {
		t.Fatalf("perm = %v", info.Mode().Perm())
	}
}

func TestLeafSignedByCAWithCorrectSANs(t *testing.T) {
	cm, _ := newTestManager(t)
	pool := x509.NewCertPool()
	pool.AddCert(cm.CACert)

	c, err := cm.GenerateCertificate("example.com:443")
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(c.Certificate[0])
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "example.com"}); err != nil {
		t.Fatalf("verify dns leaf: %v", err)
	}
	if len(leaf.IPAddresses) != 0 || len(leaf.DNSNames) != 1 {
		t.Fatalf("dns leaf SANs: %v %v", leaf.DNSNames, leaf.IPAddresses)
	}

	c, err = cm.GenerateCertificate("192.168.1.10")
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ = x509.ParseCertificate(c.Certificate[0])
	if len(leaf.DNSNames) != 0 || len(leaf.IPAddresses) != 1 || leaf.IPAddresses[0].String() != "192.168.1.10" {
		t.Fatalf("ip leaf SANs: %v %v", leaf.DNSNames, leaf.IPAddresses)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool}); err != nil {
		t.Fatalf("verify ip leaf: %v", err)
	}

	if _, err := cm.GenerateCertificate(""); err == nil {
		t.Fatal("expected error for empty host")
	}
}

func countKeygen(t *testing.T) *int32 {
	t.Helper()
	var n int32
	orig := genKey
	genKey = func(bits int) (*rsa.PrivateKey, error) {
		atomic.AddInt32(&n, 1)
		return orig(bits)
	}
	t.Cleanup(func() { genKey = orig })
	return &n
}

func TestConcurrentLeafSingleKeygen(t *testing.T) {
	cm, _ := newTestManager(t)
	n := countKeygen(t)

	const workers = 32
	results := make([]*[]byte, workers)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			c, err := cm.GenerateCertificate("concurrent.example")
			if err != nil {
				t.Error(err)
				return
			}
			results[i] = &c.Certificate[0]
		}(i)
	}
	close(start)
	wg.Wait()

	if got := atomic.LoadInt32(n); got != 1 {
		t.Fatalf("keygen count = %d, want 1", got)
	}
	for i := 1; i < workers; i++ {
		if results[i] == nil || !bytes.Equal(*results[i], *results[0]) {
			t.Fatal("callers got different certs")
		}
	}
}

func TestDifferentHostsGenerateIndependently(t *testing.T) {
	cm, _ := newTestManager(t)
	n := countKeygen(t)
	for _, h := range []string{"a.example", "b.example", "a.example"} {
		if _, err := cm.GenerateCertificate(h); err != nil {
			t.Fatal(err)
		}
	}
	if got := atomic.LoadInt32(n); got != 2 {
		t.Fatalf("keygen count = %d, want 2", got)
	}
}

func TestExpiringLeafIsRegenerated(t *testing.T) {
	cm, _ := newTestManager(t)
	n := countKeygen(t)
	if _, err := cm.GenerateCertificate("renew.example"); err != nil {
		t.Fatal(err)
	}
	orig := leafRenewBefore
	t.Cleanup(func() { leafRenewBefore = orig })
	leafRenewBefore = 2 * 365 * 24 * time.Hour // everything counts as about to expire
	if _, err := cm.GenerateCertificate("renew.example"); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(n); got != 2 {
		t.Fatalf("keygen count = %d, want 2", got)
	}
}

func TestFailedLeafNotCachedAndNoDeadlock(t *testing.T) {
	cm, _ := newTestManager(t)
	orig := genKey
	t.Cleanup(func() { genKey = orig })
	genKey = func(int) (*rsa.PrivateKey, error) { return nil, os.ErrInvalid }
	if _, err := cm.GenerateCertificate("fail.example"); err == nil {
		t.Fatal("expected error")
	}
	genKey = orig
	if _, err := cm.GenerateCertificate("fail.example"); err != nil {
		t.Fatalf("retry after failure: %v", err)
	}
}

func TestPanicInSignLeafReleasesInflight(t *testing.T) {
	cm, _ := newTestManager(t)
	orig := genKey
	t.Cleanup(func() { genKey = orig })
	genKey = func(int) (*rsa.PrivateKey, error) { panic("boom") }

	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("expected panic to propagate")
			}
		}()
		cm.GenerateCertificate("panic.example")
	}()

	cm.mu.Lock()
	n := len(cm.inflight)
	_, cached := cm.leafCache["panic.example"]
	cm.mu.Unlock()
	if n != 0 || cached {
		t.Fatalf("inflight=%d cached=%v after panic", n, cached)
	}

	genKey = orig
	done := make(chan error, 1)
	go func() { _, err := cm.GenerateCertificate("panic.example"); done <- err }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("retry after panic: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("retry blocked: inflight not released")
	}
}

func TestLeafParseFailureReturnsErrorWithoutCaching(t *testing.T) {
	cm, _ := newTestManager(t)
	n := countKeygen(t)
	orig := parseCert
	t.Cleanup(func() { parseCert = orig })
	parseCert = func([]byte) (*x509.Certificate, error) { return nil, os.ErrInvalid }

	if _, err := cm.GenerateCertificate("parse.example"); err == nil {
		t.Fatal("expected error")
	}
	cm.mu.Lock()
	_, cached := cm.leafCache["parse.example"]
	cm.mu.Unlock()
	if cached {
		t.Fatal("failed leaf must not be cached")
	}
	if got := atomic.LoadInt32(n); got != 1 {
		t.Fatalf("keygen count = %d, want 1 (no regeneration loop)", got)
	}
}

func snapshot(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	m := map[string][]byte{}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		b, _ := os.ReadFile(filepath.Join(dir, e.Name()))
		m[e.Name()] = b
	}
	return m
}

func keys(m map[string][]byte) []string {
	var k []string
	for n := range m {
		k = append(k, n)
	}
	return k
}
