package proxy

import (
	"context"
	"errors"
	"net"
	"strings"
	"syscall"
)

// The proxy listens on all interfaces so LAN devices can use it. Without a
// guard, any device on the network could ask it to fetch http://127.0.0.1:8081
// and drive the loopback-only control plane (SSRF), or reach other services
// that only listen on this Mac's loopback. Two layers:
//
//  1. checkTarget rejects obvious targets up front (localhost, loopback IPs,
//     this machine's IPs on the API/proxy ports) with a 403.
//  2. guardedDialControl re-checks the *resolved* IP at connect time, so
//     hostnames that resolve to loopback (localtest.me, DNS rebinding) are
//     refused as well.
//
// Consequence: an upstream HTTP(S)_PROXY on loopback is not supported.

// protectedLocalPorts are refused even on this machine's non-loopback IPs:
// the API (SSRF target) and the proxy itself (request loops).
var protectedLocalPorts = map[string]bool{"8081": true, "8080": true}

// localIPs returns this machine's interface addresses. A variable so tests can stub it.
var localIPs = func() []net.IP {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	out := make([]net.IP, 0, len(addrs))
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok {
			out = append(out, ipn.IP)
		}
	}
	return out
}

var errForbiddenTarget = errors.New("proxying to this machine's loopback or control ports is not allowed")

// checkTarget validates a host[:port] the client asked the proxy to reach.
// defaultPort is used when hostport carries no port ("80" or "443").
func checkTarget(hostport, defaultPort string) error {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		host, port = hostport, defaultPort
	}
	host = strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return errForbiddenTarget
	}
	if ip := net.ParseIP(host); ip != nil {
		return checkIP(ip, port)
	}
	return nil
}

func checkIP(ip net.IP, port string) error {
	if ip.IsLoopback() || ip.IsUnspecified() {
		return errForbiddenTarget
	}
	if protectedLocalPorts[port] {
		for _, local := range localIPs() {
			if local.Equal(ip) {
				return errForbiddenTarget
			}
		}
	}
	return nil
}

// guardedDialControl is a net.Dialer.Control hook: address is the resolved
// "ip:port" about to be connected to.
func guardedDialControl(_, address string, _ syscall.RawConn) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return errForbiddenTarget
	}
	return checkIP(ip, port)
}

// guardedDialContext wraps a dialer so every upstream connection goes through
// guardedDialControl.
func guardedDialContext(d *net.Dialer) func(ctx context.Context, network, addr string) (net.Conn, error) {
	d.Control = guardedDialControl
	return d.DialContext
}
