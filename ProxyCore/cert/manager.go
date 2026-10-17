package cert

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	caKeyName  = "ca.key"
	caCertName = "ca.pem"
)

type CertManager struct {
	CACert    *x509.Certificate
	CAKey     *rsa.PrivateKey
	keyPath   string
	certPath  string
	mu        sync.Mutex
	leafCache map[string]*tls.Certificate
	inflight  map[string]*leafCall
}

// leafCall is a leaf generation in progress; concurrent callers for the same
// host wait on done instead of generating their own key (singleflight).
type leafCall struct {
	done chan struct{}
	cert *tls.Certificate
	err  error
}

// Overridable in tests (RSA 4096 keygen is slow).
var (
	caKeyBits   = 4096
	leafKeyBits = 2048
	// leafRenewBefore: cached leaves expiring sooner than this are regenerated.
	leafRenewBefore = 24 * time.Hour
	// genKey creates RSA keys; tests wrap it to count invocations.
	genKey = func(bits int) (*rsa.PrivateKey, error) { return rsa.GenerateKey(rand.Reader, bits) }
)

// NewCertManager loads (or generates) the root CA from baseDir.
// A new CA is generated ONLY when both files are missing. If a file exists but
// cannot be loaded (corrupt, partial pair, expired) an explicit error is
// returned and nothing is overwritten: devices trusting the CA would break.
// Files: <baseDir>/ca.pem (0644) and <baseDir>/ca.key (0600).
func NewCertManager(baseDir string) (*CertManager, error) {
	if baseDir == "" {
		baseDir = "."
	}
	if err := os.MkdirAll(baseDir, 0700); err != nil {
		return nil, fmt.Errorf("cannot create cert dir: %w", err)
	}
	cm := &CertManager{
		keyPath:   filepath.Join(baseDir, caKeyName),
		certPath:  filepath.Join(baseDir, caCertName),
		leafCache: make(map[string]*tls.Certificate),
		inflight:  make(map[string]*leafCall),
	}

	keyExists, err := fileExists(cm.keyPath)
	if err != nil {
		return nil, fmt.Errorf("cannot stat %s: %w", cm.keyPath, err)
	}
	certExists, err := fileExists(cm.certPath)
	if err != nil {
		return nil, fmt.Errorf("cannot stat %s: %w", cm.certPath, err)
	}

	switch {
	case keyExists && certExists:
		if err := cm.loadCA(); err != nil {
			return nil, fmt.Errorf("cannot load existing CA (%s, %s): %w; refusing to regenerate, fix or remove the files manually",
				cm.certPath, cm.keyPath, err)
		}
		return cm, nil
	case keyExists != certExists:
		return nil, fmt.Errorf("incomplete CA in %s: only one of %s and %s exists; refusing to regenerate, restore the missing file or remove both",
			baseDir, caCertName, caKeyName)
	}

	if err := cm.generateCA(); err != nil {
		return nil, fmt.Errorf("failed to generate CA: %w", err)
	}
	return cm, nil
}

func fileExists(path string) (bool, error) {
	_, err := os.Stat(path)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}

// writeFileAtomic writes data to a temp file in the same dir and renames it
// over path, so readers never observe a partial file.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

// CertPath returns the absolute path of the CA PEM (for HTTP cert downloads).
func (cm *CertManager) CertPath() string {
	return cm.certPath
}

func (cm *CertManager) loadCA() error {
	keyData, err := os.ReadFile(cm.keyPath)
	if err != nil {
		return err
	}
	keyBlock, _ := pem.Decode(keyData)
	if keyBlock == nil {
		return fmt.Errorf("failed to decode CA key")
	}
	key, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
	if err != nil {
		return err
	}

	certData, err := os.ReadFile(cm.certPath)
	if err != nil {
		return err
	}
	certBlock, _ := pem.Decode(certData)
	if certBlock == nil {
		return fmt.Errorf("failed to decode CA certificate")
	}
	cert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return err
	}

	if pub, ok := cert.PublicKey.(*rsa.PublicKey); !ok || !pub.Equal(&key.PublicKey) {
		return fmt.Errorf("CA certificate does not match CA private key")
	}
	if !cert.IsCA {
		return fmt.Errorf("certificate is not a CA")
	}
	if now := time.Now(); now.After(cert.NotAfter) {
		return fmt.Errorf("CA certificate expired on %s", cert.NotAfter.Format(time.RFC3339))
	}

	cm.CAKey = key
	cm.CACert = cert

	// If the key file has weak permissions, tighten it now.
	if info, err := os.Stat(cm.keyPath); err == nil && info.Mode().Perm() != 0600 {
		_ = os.Chmod(cm.keyPath, 0600)
	}
	return nil
}

func (cm *CertManager) generateCA() error {
	return cm.generateCAWithValidity(-24*time.Hour, 10*365*24*time.Hour)
}

// generateCAWithValidity creates the CA with NotBefore/NotAfter offsets from now.
func (cm *CertManager) generateCAWithValidity(notBefore, notAfter time.Duration) error {
	key, err := genKey(caKeyBits)
	if err != nil {
		return err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}

	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Organization: []string{"PacketPeek CA"},
			CommonName:   "PacketPeek Root CA",
			Country:      []string{"IT"},
		},
		NotBefore:             time.Now().Add(notBefore),
		NotAfter:              time.Now().Add(notAfter),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}

	cert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return err
	}

	// Key first: a crash between the two writes leaves an incomplete pair,
	// which NewCertManager reports as an error instead of regenerating.
	if err := writeFileAtomic(cm.keyPath,
		pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}),
		0600); err != nil {
		return err
	}
	// Public cert is meant to be distributed: 0644.
	if err := writeFileAtomic(cm.certPath,
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes}),
		0644); err != nil {
		return err
	}

	cm.CACert = cert
	cm.CAKey = key
	return nil
}

// GenerateCertificate signs (and caches) a leaf cert for the given host.
// If the host arrives with a port, it is stripped for the SAN/CN.
func (cm *CertManager) GenerateCertificate(host string) (*tls.Certificate, error) {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if host == "" {
		return nil, fmt.Errorf("empty host for cert generation")
	}

	for {
		cm.mu.Lock()
		if cached, ok := cm.leafCache[host]; ok {
			if cached.Leaf != nil && time.Until(cached.Leaf.NotAfter) > leafRenewBefore {
				cm.mu.Unlock()
				return cached, nil
			}
			delete(cm.leafCache, host)
		}
		if call, ok := cm.inflight[host]; ok {
			cm.mu.Unlock()
			<-call.done
			if call.err != nil {
				return nil, call.err
			}
			return call.cert, nil
		}
		call := &leafCall{done: make(chan struct{})}
		cm.inflight[host] = call
		cm.mu.Unlock()

		call.cert, call.err = cm.signLeaf(host)

		cm.mu.Lock()
		if call.err == nil {
			cm.leafCache[host] = call.cert
		}
		delete(cm.inflight, host)
		cm.mu.Unlock()
		close(call.done)
		return call.cert, call.err
	}
}

func (cm *CertManager) signLeaf(host string) (*tls.Certificate, error) {
	key, err := genKey(leafKeyBits)
	if err != nil {
		return nil, err
	}

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}

	// IP hosts go in IPAddresses only; DNSNames is for real names.
	var ips []net.IP
	var dnsNames []string
	if ip := net.ParseIP(host); ip != nil {
		ips = append(ips, ip)
	} else {
		dnsNames = []string{host}
	}

	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"PacketPeek Dynamic Cert"},
			CommonName:   host,
			Country:      []string{"IT"},
		},
		NotBefore:             time.Now().Add(-time.Hour * 24),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              dnsNames,
		IPAddresses:           ips,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, template, cm.CACert, &key.PublicKey, cm.CAKey)
	if err != nil {
		return nil, err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	if cert.Leaf == nil {
		if leaf, err := x509.ParseCertificate(derBytes); err == nil {
			cert.Leaf = leaf
		}
	}
	return &cert, nil
}
