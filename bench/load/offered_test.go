package main

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestSourceBindingDefersEphemeralPortAllocation(t *testing.T) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	file := os.NewFile(uintptr(fd), "source-bind-test")
	defer file.Close()
	raw, err := file.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	if err := deferSourcePort("tcp4", "127.0.0.1", raw); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Addr: [4]byte{127, 0, 0, 2}}); err != nil {
		t.Fatal(err)
	}
	address, err := syscall.Getsockname(fd)
	if err != nil {
		t.Fatal(err)
	}
	if address.(*syscall.SockaddrInet4).Port != 0 {
		t.Fatal("source bind reserved a port before connect")
	}
}

func TestScheduleCountsAndOffsets(t *testing.T) {
	phases, err := parseSchedule("3:1500ms,10000000:180s")
	if err != nil {
		t.Fatal(err)
	}
	if phases[0].offers() != 4 || phases[0].offset(3) != time.Second {
		t.Fatal("fractional duration or offer spacing was rounded incorrectly")
	}
	if phases[1].offers() != 1_800_000_000 || phases[1].offset(1_799_999_999) != 180*time.Second-100*time.Nanosecond {
		t.Fatal("long high-rate schedule overflowed or lost its last offer")
	}
	for _, invalid := range []string{"", "1", "0:1s", "-1:1s", "1:0s", "1:2h", "50000001:1s"} {
		if _, err := parseSchedule(invalid); err == nil {
			t.Fatalf("accepted %q", invalid)
		}
	}
}

func TestLatencyReportExposesRareSlowFailures(t *testing.T) {
	var failures histogram
	for range 9988 {
		failures.record(time.Millisecond)
	}
	for range 10 {
		failures.record(100 * time.Millisecond)
	}
	for range 2 {
		failures.record(time.Second)
	}
	report := latencyReport(&failures)
	for field, want := range map[string]float64{
		"p99_us": 1000, "p999_us": 100000, "p9999_us": 1000000, "max_us": 1000000,
	} {
		got, ok := report[field].(float64)
		if !ok || got < want || got > want*1.008 {
			t.Fatalf("%s = %v, want %g within histogram rounding", field, report[field], want)
		}
	}
}

func TestOfferedLoadAccountsForUnsentWorkUnderSlowResponses(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(3 * time.Millisecond)
		io.WriteString(w, "ZHTPS\n")
	}))
	defer server.Close()
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 1, shards: 1, queue: 4,
		timeout: time.Second, maxLag: 10 * time.Millisecond,
		phases: []offeredPhase{{4000, 100 * time.Millisecond}},
	})
	phase := report["phases"].([]map[string]any)[0]
	if phase["offered"].(int64) != 400 || phase["successes"].(uint64) == 0 {
		t.Fatal("scheduled offers followed response rate or no useful work completed")
	}
	dropped := phase["generator_queue_drops"].(uint64) + phase["generator_expired"].(uint64)
	if dropped == 0 || dropped+phase["successes"].(uint64) != 400 {
		t.Fatal("bounded generator dropped or completed work without accounting for it")
	}
	if phase["connections_opened"].(uint64) != 1 {
		t.Fatal("persistent worker did not reuse its connection")
	}
	latency := phase["success_latency"].(map[string]any)["p99_us"].(float64)
	service := phase["success_service_latency"].(map[string]any)["p99_us"].(float64)
	if latency < service {
		t.Fatal("scheduled latency omitted generator waiting")
	}
}

func TestOfferedReusesHealthyConnectionAfterHttpRejection(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) <= 3 {
			w.WriteHeader(503)
			return
		}
		io.WriteString(w, "ZHTPS\n")
	}))
	defer server.Close()
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 1, shards: 1, queue: 16,
		timeout: time.Second, maxLag: 100 * time.Millisecond,
		phases: []offeredPhase{{100, 100 * time.Millisecond}},
	})
	phase := report["phases"].([]map[string]any)[0]
	if phase["successes"].(uint64) != 7 || phase["failures"].(map[string]uint64)["http_503"] != 3 {
		t.Fatal("rejection recovery lost valid responses")
	}
	if phase["connections_opened"].(uint64) != 1 {
		t.Fatalf("healthy 503 connection was discarded: %v opens", phase["connections_opened"])
	}
}

func TestOfferedPayloadValidationAndConnectionLifetime(t *testing.T) {
	body := bytes.Repeat([]byte("payload\n"), 4096)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, err := io.ReadAll(r.Body)
		if err != nil || r.Method != "POST" || r.URL.RequestURI() != "/echo?variant=large" ||
			r.UserAgent() != "load-test/1" || !bytes.Equal(got, body) {
			t.Error("request workload was not delivered intact")
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(got)
	}))
	defer server.Close()
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 1, shards: 1, queue: 16,
		timeout: time.Second, maxLag: 100 * time.Millisecond, method: "POST", path: "/echo?variant=large",
		requestBody: body, expectedBody: body, maxRequests: 3, userAgent: "load-test/1",
		phases: []offeredPhase{{100, 100 * time.Millisecond}},
	})
	phase := report["phases"].([]map[string]any)[0]
	if phase["successes"].(uint64) != 10 || phase["connections_opened"].(uint64) != 4 || phase["dial_attempts"].(uint64) != 4 {
		t.Fatalf("payload/lifetime accounting is incorrect: successes=%v opens=%v attempts=%v",
			phase["successes"], phase["connections_opened"], phase["dial_attempts"])
	}
	if phase["response_bytes_validated"].(uint64) != 10*uint64(len(body)) {
		t.Fatal("validated byte count includes missing or extra bytes")
	}
	if phase["request_bytes_written"].(uint64) <= 10*uint64(len(body)) {
		t.Fatal("written byte count omits request bodies or framing")
	}
}

func TestOfferedChunkedValidationRejectsExtraBytes(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.(http.Flusher).Flush()
		io.WriteString(w, "stream\n")
		if requests.Add(1) == 2 {
			io.WriteString(w, "unexpected")
		}
	}))
	defer server.Close()
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 1, shards: 1, queue: 16,
		timeout: time.Second, maxLag: 100 * time.Millisecond, allowChunked: true,
		expectedBody: []byte("stream\n"), phases: []offeredPhase{{100, 100 * time.Millisecond}},
	})
	phase := report["phases"].([]map[string]any)[0]
	if phase["successes"].(uint64) != 9 || phase["failures"].(map[string]uint64)["invalid_response"] != 1 {
		t.Fatal("chunked validation accepted excess body bytes or lost valid responses")
	}
}

func TestOfferedRejectsMalformedWorkloadBeforeIo(t *testing.T) {
	for _, options := range []offeredOptions{
		{address: "127.0.0.1:80", method: "GET\r\nInjected"},
		{address: "127.0.0.1:80", path: "/a HTTP/1.1\r\n"},
		{address: "127.0.0.1:80", path: "http://elsewhere/"},
		{address: "127.0.0.1:80", contentType: "text/plain\r\nInjected: yes"},
		{address: "127.0.0.1:80", userAgent: "client\r\nInjected: yes"},
	} {
		if err := options.prepare(); err == nil {
			t.Fatal("accepted malformed workload")
		}
	}
}

func TestOfferedChurnClassifiesFailuresAndRecoversAcrossPhases(t *testing.T) {
	var requests atomic.Int64
	var addresses sync.Map
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		address, _, _ := net.SplitHostPort(r.RemoteAddr)
		addresses.Store(address, true)
		switch requests.Add(1) {
		case 2:
			w.WriteHeader(503)
		case 3:
			io.WriteString(w, "BADBAD")
		default:
			io.WriteString(w, "ZHTPS\n")
		}
	}))
	defer server.Close()
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 2, shards: 2, queue: 16,
		churn: true, timeout: time.Second, maxLag: 100 * time.Millisecond, sourceIPs: 2,
		phases: []offeredPhase{{100, 100 * time.Millisecond}, {100, 100 * time.Millisecond}},
	})
	phases := report["phases"].([]map[string]any)
	failures := phases[0]["failures"].(map[string]uint64)
	if failures["http_503"] != 1 || failures["invalid_response"] != 1 {
		t.Fatalf("incorrect failure classes: %v", failures)
	}
	if phases[0]["successes"].(uint64) != 8 || phases[1]["successes"].(uint64) != 10 {
		t.Fatal("failure recovery or phase assignment lost valid responses")
	}
	for _, phase := range phases {
		if phase["connections_opened"].(uint64) != 10 || phase["sent"].(uint64) != 10 {
			t.Fatal("churn did not use exactly one connection per request")
		}
	}
	for _, address := range []string{"127.0.0.2", "127.0.0.3"} {
		if _, ok := addresses.Load(address); !ok {
			t.Fatalf("source address %s was not used", address)
		}
	}
}

func TestOfferedHistogramStorageStaysBoundedWithManyConnections(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ZHTPS\n")
	}))
	defer server.Close()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	report := runOffered(offeredOptions{
		address: strings.TrimPrefix(server.URL, "http://"), connections: 256, shards: 8, queue: 128,
		timeout: time.Second, maxLag: 100 * time.Millisecond,
		phases: []offeredPhase{
			{1024, 500 * time.Millisecond},
			{1024, 500 * time.Millisecond},
			{1024, 500 * time.Millisecond},
			{1024, 500 * time.Millisecond},
		},
	})
	runtime.ReadMemStats(&after)
	phases := report["phases"].([]map[string]any)
	if phases[0]["connections_opened"].(uint64) != 256 {
		t.Fatal("the memory check must exercise every connection")
	}
	for _, phase := range phases {
		if phase["successes"].(uint64) < 256 || len(phase["failures"].(map[string]uint64)) != 0 {
			t.Fatal("the memory check must complete requests in every phase")
		}
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	// Include the real HTTP client and server, with ample room for their
	// request allocations. Histograms must not reserve hundreds of MiB here.
	if allocated > 96*1024*1024 {
		t.Fatalf("four phases with 256 connections allocated %d bytes; limit is 96 MiB", allocated)
	}
}
