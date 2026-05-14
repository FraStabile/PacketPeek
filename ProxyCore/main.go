package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"proxy_core/api"
	"proxy_core/cert"
	"proxy_core/proxy"
)

const (
	proxyAddr   = ":8080"            // proxy listens on all interfaces (devices on LAN need it)
	apiAddr     = "127.0.0.1:8081"   // control plane: loopback only
	idleTimeout = 5 * time.Minute
)

var (
	pidFile         string
	apiTokenFile    string
	lastRequestTime time.Time
	mu              sync.Mutex
	inFlight        int64
)

// runtimeDir returns ~/Library/Application Support/PacketPeekRuntime.
// Falls back to the working directory on failure.
func runtimeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	dir := filepath.Join(home, "Library", "Application Support", "PacketPeekRuntime")
	_ = os.MkdirAll(dir, 0700)
	return dir
}

func initRuntimePaths() {
	dir := runtimeDir()
	pidFile = filepath.Join(dir, "packetpeek.pid")
	apiTokenFile = filepath.Join(dir, "api.token")
}

func isRunning() (bool, int) {
	// Refuse to follow symlinks for the PID file (symlink-attack guard).
	info, err := os.Lstat(pidFile)
	if err != nil {
		return false, 0
	}
	if info.Mode()&os.ModeSymlink != 0 {
		log.Printf("PID file %s is a symlink; refusing to use", pidFile)
		return false, 0
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return false, 0
	}
	pid, err := strconv.Atoi(string(data))
	if err != nil {
		return false, 0
	}
	process, err := os.FindProcess(pid)
	if err != nil || process == nil {
		return false, pid
	}
	err = process.Signal(syscall.Signal(0))
	return err == nil, pid
}

func writePID() error {
	pid := os.Getpid()
	if info, err := os.Lstat(pidFile); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing to write PID through symlink at %s", pidFile)
		}
	}
	return os.WriteFile(pidFile, []byte(fmt.Sprint(pid)), 0600)
}

func removePID() {
	_ = os.Remove(pidFile)
}

func killOldDaemon(pid int) {
	process, err := os.FindProcess(pid)
	if err != nil || process == nil {
		return
	}
	log.Printf("Stopping old daemon (PID %d)...", pid)
	_ = process.Signal(syscall.SIGTERM)
	time.Sleep(2 * time.Second)
}

func updateLastRequestTime() {
	mu.Lock()
	defer mu.Unlock()
	lastRequestTime = time.Now()
}

// generateAPIToken produces a 32-byte hex token (256 bits of entropy)
// and persists it with 0600 permissions so the Swift app can read it.
func generateAPIToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buf)
	if err := os.WriteFile(apiTokenFile, []byte(token), 0600); err != nil {
		return "", err
	}
	return token, nil
}

func idleWatcher(shutdown func()) {
	for {
		time.Sleep(30 * time.Second)
		mu.Lock()
		idle := time.Since(lastRequestTime)
		mu.Unlock()
		if idle > idleTimeout && atomic.LoadInt64(&inFlight) == 0 {
			log.Printf("No requests for %v and no in-flight work, shutting down...", idleTimeout)
			shutdown()
			return
		}
	}
}

func main() {
	initRuntimePaths()

	running, pid := isRunning()
	if running {
		log.Println("Daemon already running, stopping old instance...")
		killOldDaemon(pid)
	}

	if err := writePID(); err != nil {
		log.Fatalf("Unable to write PID file: %v", err)
	}
	defer removePID()

	apiToken, err := generateAPIToken()
	if err != nil {
		log.Fatalf("Unable to generate API token: %v", err)
	}
	log.Printf("API token written to %s", apiTokenFile)

	certManager, err := cert.NewCertManager(runtimeDir())
	if err != nil {
		log.Fatalf("Failed to create certificate manager: %v", err)
	}
	proxyServer := proxy.NewProxyServer(certManager, runtimeDir())

	// Direct handler (no ServeMux) so CONNECT isn't redirected/canonicalized.
	idleTracker := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		updateLastRequestTime()
		atomic.AddInt64(&inFlight, 1)
		defer atomic.AddInt64(&inFlight, -1)
		proxyServer.ServeHTTP(w, r)
	})

	proxySrv := &http.Server{
		Addr:    proxyAddr,
		Handler: idleTracker,
	}
	apiServer := api.NewAPIServer(proxyServer, apiToken, runtimeDir())
	apiSrv := apiServer.HTTPServer(apiAddr)

	updateLastRequestTime()
	go idleWatcher(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = proxySrv.Shutdown(ctx)
		_ = apiSrv.Shutdown(ctx)
	})

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("Starting proxy on %s", proxyAddr)
		if err := proxySrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Proxy server error: %v", err)
		}
	}()

	go func() {
		log.Printf("Starting API on %s", apiAddr)
		if err := apiSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("API server error: %v", err)
		}
	}()

	<-stop
	log.Println("Stopping daemon...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = proxySrv.Shutdown(ctx)
	_ = apiSrv.Shutdown(ctx)
	log.Println("Daemon stopped cleanly")
}
