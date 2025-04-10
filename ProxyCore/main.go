package main

import (
	"log"
	"proxy_core/api"
	"proxy_core/cert"
	"proxy_core/proxy"
)

func main() {
	// Create certificate manager
	certManager, err := cert.NewCertManager()
	if err != nil {
		log.Fatalf("Failed to create certificate manager: %v", err)
	}

	// Create proxy server
	proxyServer := proxy.NewProxyServer(certManager)

	// Create API server
	apiServer := api.NewAPIServer(proxyServer)

	// Start servers
	go func() {
		log.Printf("Starting proxy server on :8080")
		if err := proxyServer.Start(":8080"); err != nil {
			log.Fatalf("Proxy server error: %v", err)
		}
	}()

	log.Printf("Starting API server on :8081")
	if err := apiServer.Start(":8081"); err != nil {
		log.Fatalf("API server error: %v", err)
	}
}
