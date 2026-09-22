// Closed-loop HTTP/1.1 load with one outstanding request per persistent connection.
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"math/bits"
	"net"
	"net/http"
	"os"
	"sync"
	"syscall"
	"time"
)

// Each power of two has 128 buckets. Quantiles are upper bounds with <0.8%
// relative rounding error. Only observed magnitude ranges allocate buckets;
// empty and narrow distributions do not reserve all 64 KiB per histogram.
type histogram struct {
	buckets [64]*[128]uint64
	count   uint64
	sum     uint64
	max     uint64
}

func (h *histogram) record(elapsed time.Duration) {
	ns := uint64(elapsed)
	shift := max(0, bits.Len64(ns)-8)
	index := shift*128 + int(ns>>shift)
	group := index / 128
	if h.buckets[group] == nil {
		h.buckets[group] = new([128]uint64)
	}
	h.buckets[group][index%128]++
	h.count++
	h.sum += ns
	h.max = max(h.max, ns)
}

func (h *histogram) quantile(fraction float64) float64 {
	target := uint64(math.Ceil(float64(h.count) * fraction))
	if target == 0 {
		return 0
	}
	var cumulative uint64
	for group, bucket := range h.buckets {
		if bucket == nil {
			continue
		}
		for offset, count := range bucket {
			cumulative += count
			if cumulative >= target {
				index := group*128 + offset
				upper := uint64(index)
				if index >= 128 {
					shift := index/128 - 1
					upper = (uint64(129+index%128) << shift) - 1
				}
				return float64(min(upper, h.max)) / 1000
			}
		}
	}
	panic("histogram count mismatch")
}

func (h *histogram) merge(other *histogram) {
	for group, bucket := range other.buckets {
		if bucket == nil {
			continue
		}
		if h.buckets[group] == nil {
			h.buckets[group] = new([128]uint64)
		}
		for offset, count := range bucket {
			h.buckets[group][offset] += count
		}
	}
	h.count += other.count
	h.sum += other.sum
	h.max = max(h.max, other.max)
}

type outcome struct {
	latency         histogram
	attempts        uint64
	errors          uint64
	warmErrors      uint64
	connections     uint64
	setupError      bool
	firstError      string
	finished        time.Time
	windowSuccesses uint64
	failures        map[string]uint64
	windowFailures  map[string]uint64
}

type httpFailure struct{ status int }

func (failure httpFailure) Error() string {
	return fmt.Sprintf("HTTP %d", failure.status)
}

func failureKind(err error) string {
	var response httpFailure
	if errors.As(err, &response) {
		return fmt.Sprintf("http_%d", response.status)
	}
	var operation *net.OpError
	if errors.As(err, &operation) && operation.Timeout() {
		return operation.Op + "_timeout"
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection_reset"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection_refused"
	}
	if errors.Is(err, syscall.EADDRNOTAVAIL) {
		return "source_address_unavailable"
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "eof"
	}
	if operation != nil {
		return "transport_error"
	}
	return "invalid_response"
}

func countFailure(counts *map[string]uint64, kind string) {
	if *counts == nil {
		*counts = make(map[string]uint64)
	}
	(*counts)[kind]++
}

func cpuSeconds() float64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return float64(usage.Utime.Sec+usage.Stime.Sec) +
		float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
}

type phase struct {
	measureStart time.Time
	end          time.Time
}

func worker(address string, timing *phase, start <-chan struct{}, ready *sync.WaitGroup,
	opening chan struct{}, result *outcome, allowErrors bool, tlsConfig *tls.Config) {
	var conn net.Conn
	var reader *bufio.Reader
	defer func() {
		if conn != nil {
			conn.Close()
		}
	}()
	request := "GET / HTTP/1.1\r\nHost: " + address + "\r\n\r\n"
	requestInfo := &http.Request{Method: "GET"}
	var body [6]byte
	exchange := func(started time.Time) error {
		if conn == nil {
			var err error
			if tlsConfig != nil {
				secure, handshakeErr := tls.DialWithDialer(&net.Dialer{Timeout: 2 * time.Second}, "tcp", address, tlsConfig)
				if handshakeErr != nil {
					return handshakeErr
				}
				conn = secure
			} else {
				conn, err = net.DialTimeout("tcp", address, 2*time.Second)
			}
			if err != nil {
				return err
			}
			result.connections++
			reader = bufio.NewReader(conn)
		}
		if err := conn.SetDeadline(started.Add(2 * time.Second)); err != nil {
			return err
		}
		if _, err := io.WriteString(conn, request); err != nil {
			return err
		}
		response, err := http.ReadResponse(reader, requestInfo)
		if err != nil {
			return err
		}
		if response.StatusCode != 200 {
			// Consume a bounded error response before recording its HTTP status.
			// A partial response remains a transport failure.
			n, err := io.Copy(io.Discard, io.LimitReader(response.Body, 65537))
			if err != nil {
				return err
			}
			if n > 65536 {
				return fmt.Errorf("error response body exceeds 64 KiB")
			}
			if err := response.Body.Close(); err != nil {
				return err
			}
			return httpFailure{status: response.StatusCode}
		}
		if response.ContentLength != 6 || (response.Close && !allowErrors) {
			return fmt.Errorf("unexpected response: status=%d length=%d close=%v",
				response.StatusCode, response.ContentLength, response.Close)
		}
		if _, err := io.ReadFull(response.Body, body[:]); err != nil {
			return err
		}
		if err := response.Body.Close(); err != nil {
			return err
		}
		if string(body[:]) != "ZHTPS\n" {
			return fmt.Errorf("unexpected body: %q", body)
		}
		if response.Close {
			conn.Close()
			conn = nil
		}
		return nil
	}
	// Bound simultaneous opens to avoid a SYN-backlog burst during preparation.
	// Overload mode keeps workers whose initial request failed retrying after the barrier.
	opening <- struct{}{}
	err := exchange(time.Now())
	<-opening
	if err != nil {
		result.setupError = true
		result.firstError = err.Error()
		if conn != nil {
			conn.Close()
			conn = nil
		}
	}
	ready.Done()
	<-start
	if result.setupError && !allowErrors {
		return
	}
	for {
		started := time.Now()
		if !started.Before(timing.end) {
			return
		}
		measured := !started.Before(timing.measureStart)
		if measured {
			result.attempts++
		}
		err := exchange(started)
		finished := time.Now()
		inWindow := !finished.Before(timing.measureStart) && finished.Before(timing.end)
		if err == nil && inWindow {
			result.windowSuccesses++
		}
		if measured {
			result.finished = finished
			if err == nil {
				result.latency.record(finished.Sub(started))
			} else {
				result.errors++
			}
		} else if err != nil {
			result.warmErrors++
		}
		if err != nil {
			kind := failureKind(err)
			if measured {
				countFailure(&result.failures, kind)
			}
			if inWindow {
				countFailure(&result.windowFailures, kind)
			}
			if result.firstError == "" {
				result.firstError = err.Error()
			}
			if conn != nil {
				conn.Close()
				conn = nil
			}
		}
	}
}

func main() {
	address := flag.String("address", "127.0.0.1:8080", "server address")
	useTLS := flag.Bool("tls", false, "closed-loop TLS 1.3; skips certificate verification for benchmark certificates")
	connections := flag.Int("connections", 16, "persistent connections")
	duration := flag.Duration("duration", 5*time.Second, "measurement time")
	warmup := flag.Duration("warmup", time.Second, "unmeasured warmup time")
	allowErrors := flag.Bool("allow-errors", false, "continue across setup failures, rejections and timeouts")
	schedule := flag.String("schedule", "", "open-loop phases: requests-per-second:duration,...")
	shards := flag.Int("shards", 8, "independent open-loop schedulers")
	queueSize := flag.Int("queue", 128, "queued offers per open-loop shard")
	churn := flag.Bool("churn", false, "open-loop: open a connection for every request")
	timeout := flag.Duration("timeout", time.Second, "open-loop request timeout")
	maxLag := flag.Duration("max-lag", 10*time.Millisecond, "drop open-loop offers older than this before starting I/O")
	sourceIPs := flag.Int("source-ips", 0, "open-loop: distribute source ports across N loopback IPs (0 uses kernel default)")
	method := flag.String("method", "GET", "open-loop request method")
	path := flag.String("path", "/", "open-loop request path and query")
	requestBody := flag.String("request-body", "", "open-loop request body file, at most 64 MiB")
	expectedBody := flag.String("expect-body", "", "open-loop exact expected response body file (default ZHTPS\\n)")
	contentType := flag.String("content-type", "application/octet-stream", "open-loop request body content type")
	userAgent := flag.String("user-agent", "", "open-loop User-Agent header; empty omits it")
	maxRequests := flag.Uint64("max-requests", 0, "open-loop requests per connection; 0 keeps reusing it")
	allowChunked := flag.Bool("allow-chunked", false, "open-loop: accept chunked framing with exact expected body")
	flag.Parse()
	var tlsConfig *tls.Config
	if *useTLS {
		if *schedule != "" {
			fmt.Fprintln(os.Stderr, "TLS is supported only for closed-loop load")
			os.Exit(2)
		}
		tlsConfig = &tls.Config{
			MinVersion:         tls.VersionTLS13,
			MaxVersion:         tls.VersionTLS13,
			NextProtos:         []string{"http/1.1"},
			InsecureSkipVerify: true, // Disposable benchmark certificates only.
		}
	}
	if *connections < 1 || *connections > 16384 || *duration <= 0 || *warmup < 0 {
		fmt.Fprintln(os.Stderr, "require 1..16384 connections, positive duration, nonnegative warmup")
		os.Exit(2)
	}
	if *schedule != "" {
		phases, err := parseSchedule(*schedule)
		if err != nil || *shards < 1 || *shards > *connections || *queueSize < 0 || *queueSize > 65536 ||
			*timeout <= 0 || *timeout > time.Minute || *maxLag <= 0 || *maxLag > time.Second || *sourceIPs < 0 || *sourceIPs > 253 {
			fmt.Fprintln(os.Stderr, "invalid open-loop options:", err)
			os.Exit(2)
		}
		options := offeredOptions{
			address: *address, connections: *connections, shards: *shards, queue: *queueSize,
			churn: *churn, timeout: *timeout, maxLag: *maxLag, phases: phases, sourceIPs: *sourceIPs,
			method: *method, path: *path, contentType: *contentType, maxRequests: *maxRequests,
			allowChunked: *allowChunked, userAgent: *userAgent,
		}
		for _, file := range []struct {
			path string
			body *[]byte
		}{{*requestBody, &options.requestBody}, {*expectedBody, &options.expectedBody}} {
			if file.path == "" {
				continue
			}
			*file.body, err = readWorkloadFile(file.path)
			if err != nil {
				fmt.Fprintln(os.Stderr, "workload:", err)
				os.Exit(2)
			}
		}
		if err := options.prepare(); err != nil {
			fmt.Fprintln(os.Stderr, "workload:", err)
			os.Exit(2)
		}
		report := runOffered(options)
		json.NewEncoder(os.Stdout).Encode(report)
		return
	}
	setupStart := time.Now()
	results := make([]outcome, *connections)
	var workers, ready sync.WaitGroup
	var timing phase
	start := make(chan struct{})
	opening := make(chan struct{}, 64)
	for index := range results {
		workers.Add(1)
		ready.Add(1)
		go func() {
			defer workers.Done()
			worker(*address, &timing, start, &ready, opening, &results[index], *allowErrors, tlsConfig)
		}()
	}
	ready.Wait()
	setupSeconds := time.Since(setupStart).Seconds()
	var setupErrors int
	var firstSetupError string
	for index := range results {
		if results[index].setupError {
			setupErrors++
			firstSetupError = results[index].firstError
		}
	}
	if setupErrors != 0 && !*allowErrors {
		close(start)
		workers.Wait()
		json.NewEncoder(os.Stdout).Encode(map[string]any{
			"setup_errors":      setupErrors,
			"connections_ready": *connections - setupErrors,
			"first_error":       firstSetupError,
		})
		os.Exit(1)
	}
	started := time.Now()
	cpuStart := cpuSeconds()
	measureStart := started.Add(*warmup)
	end := measureStart.Add(*duration)
	timing = phase{measureStart: measureStart, end: end}
	close(start)
	workers.Wait()
	totalElapsed := time.Since(started).Seconds()
	cpu := cpuSeconds() - cpuStart
	var combined outcome
	var measuredConnections int
	var attemptedConnections int
	combined.finished = end
	for index := range results {
		result := &results[index]
		if result.latency.count != 0 {
			measuredConnections++
		}
		if result.attempts != 0 {
			attemptedConnections++
		}
		combined.latency.merge(&result.latency)
		combined.attempts += result.attempts
		combined.errors += result.errors
		combined.warmErrors += result.warmErrors
		combined.connections += result.connections
		combined.windowSuccesses += result.windowSuccesses
		for kind, count := range result.failures {
			if combined.failures == nil {
				combined.failures = make(map[string]uint64)
			}
			combined.failures[kind] += count
		}
		for kind, count := range result.windowFailures {
			if combined.windowFailures == nil {
				combined.windowFailures = make(map[string]uint64)
			}
			combined.windowFailures[kind] += count
		}
		if result.finished.After(combined.finished) {
			combined.finished = result.finished
		}
		if combined.firstError == "" {
			combined.firstError = result.firstError
		}
	}
	elapsed := combined.finished.Sub(measureStart).Seconds()
	var mean float64
	if combined.latency.count != 0 {
		mean = float64(combined.latency.sum) / float64(combined.latency.count) / 1000
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"tls":                         *useTLS,
		"connections":                 *connections,
		"connections_opened":          combined.connections,
		"connections_ready":           *connections - setupErrors,
		"connections_measured":        measuredConnections,
		"connections_attempted":       attemptedConnections,
		"allow_errors":                *allowErrors,
		"setup_errors":                setupErrors,
		"setup_seconds":               setupSeconds,
		"warmup_seconds":              warmup.Seconds(),
		"measurement_seconds":         duration.Seconds(),
		"measurement_start_unix_ns":   measureStart.UnixNano(),
		"measurement_end_unix_ns":     end.UnixNano(),
		"elapsed_with_drain_seconds":  elapsed,
		"attempts":                    combined.attempts,
		"successes":                   combined.latency.count,
		"errors":                      combined.errors,
		"warmup_errors":               combined.warmErrors,
		"first_error":                 combined.firstError,
		"requests_per_second":         float64(combined.latency.count) / elapsed,
		"window_successes":            combined.windowSuccesses,
		"window_successes_per_second": float64(combined.windowSuccesses) / duration.Seconds(),
		"failures":                    combined.failures,
		"window_failures":             combined.windowFailures,
		"latency_us": map[string]float64{
			"mean": mean,
			"p50":  combined.latency.quantile(0.50),
			"p95":  combined.latency.quantile(0.95),
			"p99":  combined.latency.quantile(0.99),
			"max":  float64(combined.latency.max) / 1000,
		},
		"generator_cpu_seconds_including_warmup": cpu,
		"generator_cpu_percent_including_warmup": 100 * cpu / totalElapsed,
	})
	if !*allowErrors && (combined.errors != 0 || combined.warmErrors != 0 || measuredConnections != *connections) {
		os.Exit(1)
	}
}
