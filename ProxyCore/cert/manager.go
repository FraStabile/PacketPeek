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
	"time"
)

const (
	caKeyFile  = "ca.key"
	caCertFile = "ca.pem"
)

type CertManager struct {
	CACert *x509.Certificate
	CAKey  *rsa.PrivateKey
}

func NewCertManager() (*CertManager, error) {
	cm := &CertManager{}

	// Try to load existing CA
	if err := cm.loadCA(); err == nil {
		return cm, nil
	}

	// Generate new CA if not exists
	if err := cm.generateCA(); err != nil {
		return nil, fmt.Errorf("failed to generate CA: %v", err)
	}

	return cm, nil
}

func (cm *CertManager) loadCA() error {
	// Load CA Key
	keyData, err := os.ReadFile(caKeyFile)
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

	// Load CA Certificate
	certData, err := os.ReadFile(caCertFile)
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

	return nil
}

func (cm *CertManager) generateCA() error {
	key, err := rsa.GenerateKey(rand.Reader, 4096) // Aumentato a 4096 bit per maggiore sicurezza
	if err != nil {
		return err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"ProxyCore CA"},
			CommonName:   "ProxyCore Root CA",
			Country:      []string{"IT"},
		},
		NotBefore:             time.Now().Add(-time.Hour * 24), // Valido da ieri
		NotAfter:              time.Now().AddDate(10, 0, 0),    // Valido per 10 anni
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0, // Non permettere sub-CA
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}

	// Save CA certificate
	certOut, err := os.Create(caCertFile)
	if err != nil {
		return err
	}
	defer certOut.Close()
	pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes})

	// Save CA private key
	keyOut, err := os.Create(caKeyFile)
	if err != nil {
		return err
	}
	defer keyOut.Close()
	pem.Encode(keyOut, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	cm.CACert = template
	cm.CAKey = key
	return nil
}

func (cm *CertManager) GenerateCertificate(host string) (*tls.Certificate, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}

	// Estrai il dominio base per il Subject CN e gestisci IP
	hostname := host
	var ips []net.IP

	if h, _, err := net.SplitHostPort(host); err == nil {
		hostname = h
	}

	// Controlla se l'hostname è un IP
	ip := net.ParseIP(hostname)
	if ip != nil {
		ips = append(ips, ip)
	} else {
		// Prova a risolvere il DNS
		if resolved, err := net.LookupIP(hostname); err == nil {
			ips = append(ips, resolved...)
		}
	}

	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"ProxyCore Dynamic Cert"},
			CommonName:   hostname,
			Country:      []string{"IT"},
		},
		NotBefore:             time.Now().Add(-time.Hour * 24), // Valido da ieri
		NotAfter:              time.Now().AddDate(1, 0, 0),     // Valido per 1 anno
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{hostname},
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
	return &cert, nil
}
