package proxy

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"sync"
)

// headBuffer is an io.Writer that keeps only the first `limit` bytes written
// to it and counts the rest. Used as the log side of an io.TeeReader so
// bodies stream through the proxy while memory per request stays bounded.
// Safe for concurrent use: the transport may still be writing the request
// body from its own goroutine while we build the log entry.
type headBuffer struct {
	mu    sync.Mutex
	buf   bytes.Buffer
	limit int
	total int64
}

func newHeadBuffer() *headBuffer { return &headBuffer{limit: maxLoggedBodyBytes} }

func (h *headBuffer) Write(p []byte) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.total += int64(len(p))
	if room := h.limit - h.buf.Len(); room > 0 {
		if len(p) > room {
			p = p[:room]
		}
		h.buf.Write(p)
	}
	return len(p), nil
}

// String renders the captured head for the log, gunzipping it when
// contentEncoding says so and noting how much was cut off.
func (h *headBuffer) String(contentEncoding string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.total == 0 {
		return ""
	}
	out := decodeIfGzip(contentEncoding, h.buf.Bytes())
	if dropped := h.total - int64(h.buf.Len()); dropped > 0 {
		out += fmt.Sprintf("\n…[truncated %d bytes]", dropped)
	}
	return out
}

// teeBody wraps body so everything read from it is also captured in h.
func teeBody(body io.ReadCloser, h *headBuffer) io.ReadCloser {
	return struct {
		io.Reader
		io.Closer
	}{io.TeeReader(body, h), body}
}

// captureAndDrain records up to the log limit of body and discards the rest,
// without ever holding more than maxLoggedBodyBytes in memory. Used when the
// request is answered locally (mocks) and the body is not forwarded.
func captureAndDrain(body io.ReadCloser, h *headBuffer) {
	if body == nil {
		return
	}
	_, _ = io.Copy(h, body)
	_ = body.Close()
}

// flushWriter flushes after every write so streamed responses (chunked, SSE)
// reach the client as they arrive instead of sitting in the server's buffer.
type flushWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func newFlushWriter(w http.ResponseWriter) io.Writer {
	if f, ok := w.(http.Flusher); ok {
		return flushWriter{w: w, f: f}
	}
	return w
}

func (fw flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	fw.f.Flush()
	return n, err
}
