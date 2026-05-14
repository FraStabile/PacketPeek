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
}

// NewCertManager loads (or generates) the root CA from baseDir.
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
	}

	if err := cm.loadCA(); err == nil {
		return cm, nil
	}

	if err := cm.generateCA(); err != nil {
		return nil, fmt.Errorf("failed to generate CA: %w", err)
	}
	return cm, nil
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
	cm.CAKey, err = x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
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
	cm.CACert, err = x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return err
	}

	// If the key file has weak permissions, tighten it now.
	if info, err := os.Stat(cm.keyPath); err == nil && info.Mode().Perm() != 0600 {
		_ = os.Chmod(cm.keyPath, 0600)
	}
	return nil
}

func (cm *CertManager) generateCA() error {
	key, err := rsa.GenerateKey(rand.Reader, 4096)
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
		NotBefore:             time.Now().Add(-time.Hour * 24),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}

	// Write public cert with 0644 (it's a certificate, meant to be distributed).
	if err := os.WriteFile(cm.certPath,
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes}),
		0644); err != nil {
		return err
	}

	// Write private key with 0600.
	if err := os.WriteFile(cm.keyPath,
		pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}),
		0600); err != nil {
		return err
	}

	cm.CACert = template
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

	cm.mu.Lock()
	if cached, ok := cm.leafCache[host]; ok {
		cm.mu.Unlock()
		return cached, nil
	}
	cm.mu.Unlock()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}

	var ips []net.IP
	if ip := net.ParseIP(host); ip != nil {
		ips = append(ips, ip)
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
		DNSNames:              []string{host},
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

	cm.mu.Lock()
	cm.leafCache[host] = &cert
	cm.mu.Unlock()
	return &cert, nil
}
