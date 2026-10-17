package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestIsIdle(t *testing.T) {
	cases := []struct {
		name      string
		since     time.Duration
		inFlight  int64
		wsClients int
		want      bool
	}{
		{"recent activity", time.Minute, 0, 0, false},
		{"idle, nothing open", 6 * time.Minute, 0, 0, true},
		{"idle but request in flight", 6 * time.Minute, 1, 0, false},
		{"idle but UI connected", 6 * time.Minute, 0, 1, false},
	}
	for _, c := range cases {
		if got := isIdle(c.since, 5*time.Minute, c.inFlight, c.wsClients); got != c.want {
			t.Errorf("%s: isIdle = %v, want %v", c.name, got, c.want)
		}
	}
}

func resetActivity(ago time.Duration) {
	mu.Lock()
	lastRequestTime = time.Now().Add(-ago)
	mu.Unlock()
}

func TestIdleWatcherFiresWhenNoClients(t *testing.T) {
	resetActivity(time.Hour)
	fired := make(chan struct{})
	done := make(chan struct{})
	defer close(done)
	go idleWatcher(5*time.Millisecond, time.Millisecond, func() int { return 0 }, func() { close(fired) }, done)

	select {
	case <-fired:
	case <-time.After(time.Second):
		t.Fatal("idle watcher did not fire")
	}
}

func TestIdleWatcherStaysUpWithWSClient(t *testing.T) {
	resetActivity(time.Hour)
	fired := make(chan struct{})
	done := make(chan struct{})
	go idleWatcher(5*time.Millisecond, time.Millisecond, func() int { return 1 }, func() { close(fired) }, done)

	select {
	case <-fired:
		t.Fatal("idle watcher fired while a UI client was connected")
	case <-time.After(100 * time.Millisecond):
	}
	close(done)
}

// The original bug: idle shutdown stopped the servers but main stayed blocked
// on the signal channel forever. waitForShutdown must return on idle too.
func TestWaitForShutdownReturnsOnIdle(t *testing.T) {
	idle := make(chan struct{})
	got := make(chan int, 1)
	go func() { got <- waitForShutdown(make(chan os.Signal), idle, make(chan error)) }()
	close(idle)

	select {
	case code := <-got:
		if code != exitCodeIdle {
			t.Fatalf("exit code = %d, want %d", code, exitCodeIdle)
		}
	case <-time.After(time.Second):
		t.Fatal("waitForShutdown did not return after idle")
	}
}

func TestWaitForShutdownSignalAndError(t *testing.T) {
	sig := make(chan os.Signal, 1)
	sig <- syscall.SIGTERM
	if code := waitForShutdown(sig, make(chan struct{}), make(chan error)); code != 0 {
		t.Fatalf("signal exit code = %d, want 0", code)
	}
	errc := make(chan error, 1)
	errc <- errors.New("bind: address already in use")
	if code := waitForShutdown(make(chan os.Signal), make(chan struct{}), errc); code != 1 {
		t.Fatalf("error exit code = %d, want 1", code)
	}
}

func TestProxyHTTPServerHasSlowlorisProtection(t *testing.T) {
	srv := newProxyHTTPServer(":0", http.NotFoundHandler())
	if srv.ReadHeaderTimeout <= 0 || srv.IdleTimeout <= 0 {
		t.Fatalf("missing timeouts: %v %v", srv.ReadHeaderTimeout, srv.IdleTimeout)
	}
	if srv.ReadTimeout != 0 || srv.WriteTimeout != 0 {
		t.Fatal("Read/WriteTimeout would break streaming and long transfers")
	}
}

func TestSlowlorisClientClosedAndInFlightZero(t *testing.T) {
	old := proxyReadHeaderTimeout
	proxyReadHeaderTimeout = 200 * time.Millisecond
	defer func() { proxyReadHeaderTimeout = old }()

	// Real tracker from main.go around a trivial handler.
	srv := newProxyHTTPServer("127.0.0.1:0", newIdleTracker(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve(ln)
	defer srv.Close()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\nX-Slow: "))
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, _ = io.Copy(io.Discard, conn) // server answers 408 and closes
	if err := conn.SetReadDeadline(time.Now().Add(time.Second)); err == nil {
		if _, err := conn.Read(make([]byte, 1)); err == nil {
			t.Fatal("expected closed connection")
		} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Fatal("slowloris client not closed (ReadHeaderTimeout missing?)")
		}
	}
	waitInFlightZero(t)
}

func waitInFlightZero(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt64(&inFlight) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("inFlight = %d, want 0", atomic.LoadInt64(&inFlight))
		}
		time.Sleep(10 * time.Millisecond)
	}
}
