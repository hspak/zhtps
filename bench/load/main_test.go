package main

import (
	"crypto/tls"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHistogramQuantilesAndMerge(t *testing.T) {
	// Expected upper bounds straddle exact and logarithmic bucket boundaries.
	for _, sample := range []struct{ ns, upper uint64 }{
		{127, 127},
		{128, 128},
		{255, 255},
		{256, 257},
		{511, 511},
		{512, 515},
		{1_000_000, 1_003_519},
	} {
		var first, second histogram
		first.record(time.Duration(sample.ns))
		second.record(time.Duration(sample.ns))
		second.record(2 * time.Second)
		first.merge(&second)
		if got := first.quantile(0.5); got != float64(sample.upper)/1000 {
			t.Fatalf("%d ns: median upper bound = %v us; want %v us",
				sample.ns, got, float64(sample.upper)/1000)
		}
		if first.count != 3 || first.quantile(0.99) != 2_000_000 {
			t.Fatalf("merge lost count or maximum: count=%d p99=%v", first.count, first.quantile(0.99))
		}
	}
}

func TestWorkersPrepareEveryConnectionBeforeWarmup(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		io.WriteString(w, "ZHTPS\n")
	}))
	defer server.Close()
	var results [3]outcome
	var timing phase
	var workers, ready sync.WaitGroup
	start := make(chan struct{})
	opening := make(chan struct{}, 2)
	for index := range results {
		ready.Add(1)
		workers.Add(1)
		go func() {
			defer workers.Done()
			worker(strings.TrimPrefix(server.URL, "http://"), &timing, start,
				&ready, opening, &results[index], false, nil)
		}()
	}
	ready.Wait()
	// Keep cleanup valid even if a setup assertion fails before releasing workers.
	released := false
	defer func() {
		if !released {
			close(start)
		}
		workers.Wait()
	}()
	if got := requests.Load(); got != 3 {
		t.Fatalf("before warmup: got %d requests; want one per connection", got)
	}
	for index := range results {
		if results[index].setupError || results[index].connections != 1 || results[index].attempts != 0 {
			t.Fatalf("connection %d did not wait after preparation", index)
		}
	}
	timing = phase{measureStart: time.Now(), end: time.Now().Add(100 * time.Millisecond)}
	close(start)
	released = true
	workers.Wait()
	for index := range results {
		if results[index].latency.count == 0 || results[index].errors != 0 || results[index].connections != 1 {
			t.Fatalf("connection %d did not participate successfully without reconnecting", index)
		}
	}
}

func TestAllowErrorsCountsOnlyValidSuccessesAndRecovers(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch requests.Add(1) {
		case 2:
			w.Header().Set("Connection", "close")
			w.WriteHeader(503)
			io.WriteString(w, "busy\n")
		case 3:
			io.WriteString(w, "BADBAD")
		default:
			io.WriteString(w, "ZHTPS\n")
		}
	}))
	defer server.Close()
	var result outcome
	var timing phase
	var ready sync.WaitGroup
	start := make(chan struct{})
	done := make(chan struct{})
	ready.Add(1)
	go func() {
		defer close(done)
		worker(strings.TrimPrefix(server.URL, "http://"), &timing, start,
			&ready, make(chan struct{}, 1), &result, true, nil)
	}()
	ready.Wait()
	timing = phase{measureStart: time.Now(), end: time.Now().Add(100 * time.Millisecond)}
	close(start)
	<-done
	if result.failures["http_503"] != 1 || result.failures["invalid_response"] != 1 {
		t.Fatalf("incorrect rejection/validation accounting: %v", result.failures)
	}
	if result.errors != 2 || result.latency.count == 0 || result.windowSuccesses == 0 {
		t.Fatal("worker did not resume valid requests after rejection and a corrupt response")
	}
	if result.attempts != result.latency.count+result.errors || result.connections != 3 {
		t.Fatal("request or reconnect accounting lost an outcome")
	}
}

func TestAllowErrorsRetriesAfterPreparationFailure(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.WriteHeader(503)
			return
		}
		io.WriteString(w, "ZHTPS\n")
	}))
	defer server.Close()
	var result outcome
	var timing phase
	var ready sync.WaitGroup
	start := make(chan struct{})
	done := make(chan struct{})
	ready.Add(1)
	go func() {
		defer close(done)
		worker(strings.TrimPrefix(server.URL, "http://"), &timing, start,
			&ready, make(chan struct{}, 1), &result, true, nil)
	}()
	ready.Wait()
	timing = phase{measureStart: time.Now(), end: time.Now().Add(100 * time.Millisecond)}
	close(start)
	<-done
	if !result.setupError || result.errors != 0 || result.connections != 2 {
		t.Fatal("preparation failure was lost, misclassified, or not retried")
	}
	if result.windowSuccesses == 0 || result.latency.count != result.attempts {
		t.Fatal("worker did not resume successful measured requests")
	}
}

func TestTLSWorkerValidatesResponsesAndReusesConnection(t *testing.T) {
	var encrypted atomic.Int64
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS != nil && r.TLS.Version == tls.VersionTLS13 && r.TLS.NegotiatedProtocol == "http/1.1" {
			encrypted.Add(1)
		}
		io.WriteString(w, "ZHTPS\n")
	}))
	server.StartTLS()
	defer server.Close()
	var result outcome
	var timing phase
	var ready sync.WaitGroup
	start, done := make(chan struct{}), make(chan struct{})
	ready.Add(1)
	go func() {
		defer close(done)
		worker(strings.TrimPrefix(server.URL, "https://"), &timing, start,
			&ready, make(chan struct{}, 1), &result, false, &tls.Config{
				MinVersion:         tls.VersionTLS13,
				MaxVersion:         tls.VersionTLS13,
				NextProtos:         []string{"http/1.1"},
				InsecureSkipVerify: true,
			})
	}()
	ready.Wait()
	timing = phase{measureStart: time.Now(), end: time.Now().Add(100 * time.Millisecond)}
	close(start)
	<-done
	if result.setupError || result.errors != 0 || result.connections != 1 || result.latency.count == 0 {
		t.Fatalf("TLS connection was not reused successfully: %s", result.firstError)
	}
	if uint64(encrypted.Load()) != result.latency.count+1 {
		t.Fatal("requests did not all use TLS 1.3 with HTTP/1.1 ALPN")
	}
}

func TestTLSWorkerReportsHandshakeFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	var result outcome
	var timing phase
	var ready sync.WaitGroup
	start := make(chan struct{})
	close(start)
	ready.Add(1)
	worker(strings.TrimPrefix(server.URL, "http://"), &timing, start,
		&ready, make(chan struct{}, 1), &result, false, &tls.Config{InsecureSkipVerify: true})
	if !result.setupError || result.firstError == "" || result.connections != 0 || result.attempts != 0 {
		t.Fatal("failed TLS handshake was not reported as a setup error")
	}
}

func TestHistogramMergeKeepsSourceBucketsIndependent(t *testing.T) {
	var first, second histogram
	first.record(time.Nanosecond)
	second.record(2 * time.Second)
	first.merge(&second)
	first.record(2 * time.Second)
	second.record(3 * time.Second)
	if got := second.quantile(.75); got != 3_000_000 {
		t.Fatalf("mutating a merged destination changed the source distribution: p75=%v", got)
	}
}
