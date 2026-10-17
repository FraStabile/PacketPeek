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
	proxyAddr   = ":8080"          // proxy listens on all interfaces (devices on LAN need it)
	apiAddr     = "127.0.0.1:8081" // control plane: loopback only
	idleTimeout = 5 * time.Minute
	idlePoll    = 30 * time.Second

	// exitCodeIdle is the process exit status after an idle shutdown. ProxyApp
	// (ProxyCore.swift) matches on it to show "Stopped (idle)" instead of an error.
	exitCodeIdle = 3
)

var (
	// Variables (not consts) so tests can shorten them.
	proxyReadHeaderTimeout = 10 * time.Second
	proxyIdleConnTimeout   = 2 * time.Minute

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

// isIdle reports whether the daemon has had no activity for longer than timeout.
// Open proxy requests/tunnels and connected UI WebSocket clients both count as
// activity: as long as ProxyApp is attached the daemon must stay up.
func isIdle(sinceLastActivity, timeout time.Duration, inFlight int64, wsClients int) bool {
	return sinceLastActivity > timeout && inFlight == 0 && wsClients == 0
}

// idleWatcher polls every interval and calls onIdle once (then returns) when
// the daemon is idle. It also returns when done is closed.
func idleWatcher(interval, timeout time.Duration, wsClients func() int, onIdle func(), done <-chan struct{}) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
		}
		mu.Lock()
		idle := time.Since(lastRequestTime)
		mu.Unlock()
		if isIdle(idle, timeout, atomic.LoadInt64(&inFlight), wsClients()) {
			log.Printf("No activity for %v, no in-flight work and no UI clients, shutting down...", timeout)
			onIdle()
			return
		}
	}
}

// waitForShutdown blocks until a stop signal, an idle notification or a fatal
// server error arrives, and returns the exit code the process should use.
func waitForShutdown(sig <-chan os.Signal, idle <-chan struct{}, serveErr <-chan error) int {
	select {
	case s := <-sig:
		log.Printf("Received %v, stopping daemon...", s)
		return 0
	case <-idle:
		log.Println("Idle timeout reached, stopping daemon...")
		return exitCodeIdle
	case err := <-serveErr:
		log.Printf("Server error: %v", err)
		return 1
	}
}

// newIdleTracker wraps the proxy handler with the activity / in-flight
// accounting the idle shutdown relies on. Direct handler (no ServeMux) so
// CONNECT isn't redirected/canonicalized.
func newIdleTracker(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		updateLastRequestTime()
		atomic.AddInt64(&inFlight, 1)
		defer atomic.AddInt64(&inFlight, -1)
		// Long-lived CONNECT tunnels: restart the idle clock when they end too.
		defer updateLastRequestTime()
		h.ServeHTTP(w, r)
	})
}

// newProxyHTTPServer builds the LAN-facing proxy server. ReadHeaderTimeout
// stops slowloris-style clients that dribble request headers; IdleTimeout
// reaps idle keep-alive connections. No Read/WriteTimeout: they would break
// long downloads, uploads and SSE (and CONNECT tunnels are hijacked anyway).
func newProxyHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: proxyReadHeaderTimeout,
		IdleTimeout:       proxyIdleConnTimeout,
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

	apiToken, err := generateAPIToken()
	if err != nil {
		removePID()
		log.Fatalf("Unable to generate API token: %v", err)
	}
	log.Printf("API token written to %s", apiTokenFile)

	certManager, err := cert.NewCertManager(runtimeDir())
	if err != nil {
		removePID()
		log.Fatalf("Failed to create certificate manager: %v", err)
	}
	proxyServer := proxy.NewProxyServer(certManager, runtimeDir())

	// Direct handler (no ServeMux) so CONNECT isn't redirected/canonicalized.
	idleTracker := newIdleTracker(proxyServer)

	proxySrv := newProxyHTTPServer(proxyAddr, idleTracker)
	apiServer := api.NewAPIServer(proxyServer, apiToken, runtimeDir())
	apiSrv := apiServer.HTTPServer(apiAddr)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	serveErr := make(chan error, 2)

	go func() {
		log.Printf("Starting proxy on %s", proxyAddr)
		if err := proxySrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serveErr <- fmt.Errorf("proxy server: %w", err)
		}
	}()

	go func() {
		log.Printf("Starting API on %s", apiAddr)
		if err := apiSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serveErr <- fmt.Errorf("API server: %w", err)
		}
	}()

	updateLastRequestTime()
	idle := make(chan struct{})
	watcherDone := make(chan struct{})
	go idleWatcher(idlePoll, idleTimeout, apiServer.ActiveClients, func() { close(idle) }, watcherDone)

	code := waitForShutdown(stop, idle, serveErr)
	close(watcherDone)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = proxySrv.Shutdown(ctx)
	_ = apiSrv.Shutdown(ctx)
	cancel()
	// os.Exit skips deferred calls, so clean up the PID file explicitly.
	removePID()
	log.Printf("Daemon stopped (exit code %d)", code)
	os.Exit(code)
}
