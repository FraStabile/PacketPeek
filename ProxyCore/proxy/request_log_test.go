package proxy

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestResponseTimeSerializedInMilliseconds(t *testing.T) {
	entry := RequestLog{ResponseTime: Milliseconds(1500*time.Millisecond + 250*time.Microsecond)}
	raw, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"response_time_ms":1500.25`) {
		t.Fatalf("got %s, want response_time_ms 1500.25", raw)
	}

	var back RequestLog
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if time.Duration(back.ResponseTime) != 1500*time.Millisecond+250*time.Microsecond {
		t.Fatalf("round trip: %v", time.Duration(back.ResponseTime))
	}
}
