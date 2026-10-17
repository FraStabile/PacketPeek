package proxy

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// echoUpgradeHandler accepts a WebSocket-style Upgrade, then echoes raw bytes
// line by line. Header checks are reported through seen.
func echoUpgradeHandler(seen chan<- http.Header) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if seen != nil {
			seen <- r.Header.Clone()
		}
		if !isWebSocketUpgrade(r.Header) {
			io.WriteString(w, "plain")
			return
		}
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		rw.Flush()
		for {
			line, err := rw.ReadString('\n')
			if err != nil {
				return
			}
			rw.WriteString("echo:" + line)
			rw.Flush()
		}
	})
}

const upgradeReq = "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" +
	"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

func expectEcho(t *testing.T, conn net.Conn, br *bufio.Reader) {
	t.Helper()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 101 || !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") {
		t.Fatalf("status %d headers %v", resp.StatusCode, resp.Header)
	}
	for _, msg := range []string{"one", "two"} {
		fmt.Fprintf(conn, "%s\n", msg)
		line, err := br.ReadString('\n')
		if err != nil || line != "echo:"+msg+"\n" {
			t.Fatalf("got %q err %v", line, err)
		}
	}
}

func TestHTTPWebSocketUpgradeRelaysFrames(t *testing.T) {
	_, front := newTestProxy(t)
	up := httptest.NewServer(echoUpgradeHandler(nil))
	defer up.Close()

	conn, err := net.Dial("tcp", front.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	host := strings.TrimPrefix(up.URL, "http://")
	fmt.Fprintf(conn, upgradeReq, up.URL+"/ws", host)
	expectEcho(t, conn, bufio.NewReader(conn))
}

func TestHTTPSWebSocketUpgradeRelaysFrames(t *testing.T) {
	_, front := newTestProxy(t)
	up := httptest.NewTLSServer(echoUpgradeHandler(nil))
	defer up.Close()
	host := strings.TrimPrefix(up.URL, "https://")

	conn, br := connectRawTo(t, front, host)
	defer conn.Close()
	tc := tls.Client(conn, &tls.Config{InsecureSkipVerify: true, ServerName: "127.0.0.1"})
	if err := tc.Handshake(); err != nil {
		t.Fatal(err)
	}
	_ = br
	fmt.Fprintf(tc, upgradeReq, "/ws", host)
	expectEcho(t, tc, bufio.NewReader(tc))
}

func connectRawTo(t *testing.T, front *httptest.Server, host string) (net.Conn, *bufio.Reader) {
	t.Helper()
	conn, err := net.Dial("tcp", front.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", host, host)
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("CONNECT failed: %v %v", resp, err)
	}
	return conn, br
}

func TestHTTPStripsHopByHopHeaders(t *testing.T) {
	_, front := newTestProxy(t)
	seen := make(chan http.Header, 1)
	up := httptest.NewServer(echoUpgradeHandler(seen))
	defer up.Close()

	req, _ := http.NewRequest("GET", up.URL+"/x", nil)
	req.Header.Set("Proxy-Authorization", "Basic secret")
	req.Header.Set("Proxy-Connection", "keep-alive")
	req.Header.Set("Te", "trailers")
	req.Header.Set("Connection", "X-Drop-Me")
	req.Header.Set("X-Drop-Me", "1")
	req.Header.Set("X-Keep", "1")
	resp, err := proxiedClient(t, front).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	h := <-seen
	for _, k := range []string{"Proxy-Authorization", "Proxy-Connection", "Te", "X-Drop-Me"} {
		if h.Get(k) != "" {
			t.Errorf("%s reached upstream", k)
		}
	}
	if h.Get("X-Keep") == "" {
		t.Error("end-to-end header dropped")
	}
}
