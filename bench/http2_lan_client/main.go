// Persistent HTTP/2 LAN load with explicit connections and complete failure accounting.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/http2"
)

type Failure struct {
	Kind   string
	Detail string
}

func (e Failure) Error() string { return e.Detail }

type Stats struct {
	Attempted      int64            `json:"attempted"`
	Succeeded      int64            `json:"succeeded"`
	Failed         int64            `json:"failed"`
	Kinds          map[string]int64 `json:"failure_kinds"`
	Samples        []time.Duration  `json:"-"`
	FailureSamples []time.Duration  `json:"-"`
}

func (s *Stats) merge(other Stats) {
	s.Attempted += other.Attempted
	s.Succeeded += other.Succeeded
	s.Failed += other.Failed
	if s.Kinds == nil {
		s.Kinds = make(map[string]int64)
	}
	for key, count := range other.Kinds {
		s.Kinds[key] += count
	}
	s.Samples = append(s.Samples, other.Samples...)
	s.FailureSamples = append(s.FailureSamples, other.FailureSamples...)
}
func kind(err error) string {
	var failure Failure
	if errors.As(err, &failure) {
		return failure.Kind
	}
	var stream http2.StreamError
	if errors.As(err, &stream) {
		return "stream_" + stream.Code.String()
	}
	var goaway http2.GoAwayError
	if errors.As(err, &goaway) {
		return "goaway_" + goaway.ErrCode.String()
	}
	var network net.Error
	if errors.As(err, &network) && network.Timeout() {
		return "timeout"
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "eof"
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection_reset"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection_refused"
	}
	if errors.Is(err, syscall.EPIPE) {
		return "broken_pipe"
	}
	if strings.Contains(err.Error(), "closed") || strings.Contains(err.Error(), "unusable") {
		return "connection_closed"
	}
	return "transport_other"
}
func histogram(samples []time.Duration) map[int64]int64 {
	result := make(map[int64]int64)
	for _, sample := range samples {
		micros := (sample.Nanoseconds() + 999) / 1000
		width := int64(1)
		for micros > 1000*width {
			width *= 10
		}
		result[(micros+width-1)/width*width]++
	}
	return result
}
func quantile(samples []time.Duration, p int) any {
	if len(samples) == 0 {
		return nil
	}
	return float64(samples[(len(samples)-1)*p/100]) / float64(time.Millisecond)
}
func cpuSeconds() float64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return float64(usage.Utime.Sec+usage.Stime.Sec) + float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
}

type Peer struct {
	Socket    *net.TCPConn
	Captured  atomic.Bool
	Conn      *http2.ClientConn
	Setup     Stats
	Holding   Stats
	Attempted atomic.Int64
	Succeeded atomic.Int64
}

func main() {
	target := flag.String("url", "", "HTTPS target")
	ca := flag.String("ca", "", "PEM CA certificate")
	connections := flag.Int("connections", 64, "requested persistent connections")
	streams := flag.Int("streams", 4, "concurrent requests per connection")
	duration := flag.Duration("duration", 8*time.Second, "measurement duration")
	warmup := flag.Duration("warmup", 2*time.Second, "concurrent warmup")
	timeout := flag.Duration("timeout", 2*time.Second, "connection and request deadline")
	setupLimit := flag.Duration("setup-deadline", 45*time.Second, "maximum connection preparation duration")
	setupConcurrency := flag.Int("setup-concurrency", 8, "parallel connection opens")
	failurePath := flag.String("failures", "", "JSONL for every failed operation")
	synchronize := flag.Bool("synchronize", false, "emit ready and read measurement start Unix nanoseconds")
	observer := flag.String("diagnostic-observer", "", "UDP endpoint for bounded paired TCP snapshots; diagnostic runs only")
	diagnosticLimit := flag.Int64("diagnostic-limit", 32, "maximum unique measured timeout connections per process")
	flag.Parse()
	if *connections < 1 || *streams < 1 || *streams > 100 || *duration <= 0 || *warmup < 0 || *setupConcurrency < 1 || *timeout <= 0 {
		panic("invalid load parameters")
	}
	parsed, err := url.Parse(*target)
	if err != nil {
		panic(err)
	}
	if parsed.Scheme != "https" {
		panic("HTTPS required")
	}
	pem, err := os.ReadFile(*ca)
	if err != nil {
		panic(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		panic("invalid CA")
	}
	failures, err := os.Create(*failurePath)
	if err != nil {
		panic(err)
	}
	defer failures.Close()
	buffer := bufio.NewWriterSize(failures, 1024*1024)
	defer buffer.Flush()
	errorEncoder := json.NewEncoder(buffer)
	var errorMutex sync.Mutex
	var logCount int64
	var diagnosticCount atomic.Int64
	peers := make([]Peer, *connections)
	record := func(stats *Stats, phase string, connection, slot int, begin time.Time, err error, measured bool) {
		stats.Attempted++
		elapsed := time.Since(begin)
		if err == nil {
			stats.Succeeded++
			if measured {
				stats.Samples = append(stats.Samples, elapsed)
			}
			return
		}
		stats.Failed++
		if stats.Kinds == nil {
			stats.Kinds = make(map[string]int64)
		}
		category := kind(err)
		stats.Kinds[category]++
		if measured {
			stats.FailureSamples = append(stats.FailureSamples, elapsed)
		}
		row := map[string]any{"phase": phase, "connection": connection, "stream_slot": slot,
			"started_unix_ns": begin.UnixNano(), "elapsed_ns": elapsed.Nanoseconds(), "kind": category, "error": err.Error()}
		if *observer != "" && phase == "measurement" && category == "timeout" &&
			peers[connection].Captured.CompareAndSwap(false, true) && diagnosticCount.Add(1) <= *diagnosticLimit {
			row["diagnostic"] = observeFailure(&peers[connection], err, begin.Add(elapsed), *observer)
		}
		errorMutex.Lock()
		defer errorMutex.Unlock()
		if writeErr := errorEncoder.Encode(row); writeErr != nil {
			panic(writeErr)
		}
		logCount++
	}
	request := func(peer *Peer) (err error) {
		var wrote atomic.Int64
		stage := "headers"
		if *observer != "" {
			defer func() {
				if err != nil {
					err = &RequestError{Err: err, Stage: stage, WroteNS: wrote.Load()}
				}
			}()
		}
		ctx, cancel := context.WithTimeout(context.Background(), *timeout)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, "GET", *target, nil)
		if err != nil {
			return err
		}
		if *observer != "" {
			req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
				WroteRequest: func(info httptrace.WroteRequestInfo) {
					if info.Err == nil {
						wrote.Store(time.Now().UnixNano())
					}
				},
			}))
		}
		response, err := peer.Conn.RoundTrip(req)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return Failure{fmt.Sprintf("http_%d", response.StatusCode), fmt.Sprintf("HTTP status %d", response.StatusCode)}
		}
		stage = "body"
		body, err := io.ReadAll(io.LimitReader(response.Body, 7))
		if err != nil {
			return err
		}
		if response.ProtoMajor != 2 {
			return Failure{"protocol", "HTTP/2 required"}
		}
		if string(body) != "ZHTPS\n" {
			return Failure{"body", fmt.Sprintf("unexpected body %q", body)}
		}
		if response.Header.Get("Content-Type") != "text/plain; charset=utf-8" || response.Header.Get("ETag") != `"zhtps-root-v1"` || response.ContentLength != 6 {
			return Failure{"headers", fmt.Sprintf("unexpected headers %v", response.Header)}
		}
		if _, err := http.ParseTime(response.Header.Get("Date")); err != nil {
			return Failure{"headers", err.Error()}
		}
		return nil
	}
	dialer := &net.Dialer{Timeout: *timeout}
	tlsConfig := &tls.Config{RootCAs: roots, ServerName: parsed.Hostname(), NextProtos: []string{"h2"}, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13}
	transport := &http2.Transport{}
	setupCtx, stopSetup := context.WithTimeout(context.Background(), *setupLimit)
	defer stopSetup()
	var next atomic.Int64
	var setupWait, holdingWait sync.WaitGroup
	holdingDone := make(chan struct{})
	for worker := 0; worker < *setupConcurrency; worker++ {
		setupWait.Add(1)
		go func() {
			defer setupWait.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= len(peers) {
					return
				}
				if setupCtx.Err() != nil {
					return
				}
				peer := &peers[i]
				begin := time.Now()
				ctx, cancel := context.WithTimeout(setupCtx, *timeout)
				socket, err := dialer.DialContext(ctx, "tcp", parsed.Host)
				if err == nil {
					peer.Socket = socket.(*net.TCPConn)
					secure := tls.Client(socket, tlsConfig)
					err = secure.HandshakeContext(ctx)
					if err == nil && secure.ConnectionState().NegotiatedProtocol != "h2" {
						err = Failure{"protocol", "ALPN h2 required"}
					}
					if err == nil {
						peer.Conn, err = transport.NewClientConn(secure)
					}
					if err != nil {
						socket.Close()
					}
				}
				cancel()
				if err == nil {
					err = request(peer)
				}
				record(&peer.Setup, "setup", i, -1, begin, err, false)
				if err != nil {
					if peer.Conn != nil {
						peer.Conn.Close()
						peer.Conn = nil
					}
					continue
				}
				// Keep early connections alive while a large population is still being opened.
				holdingWait.Add(1)
				go func(i int, peer *Peer) {
					defer holdingWait.Done()
					ticker := time.NewTicker(3 * time.Second)
					defer ticker.Stop()
					for {
						select {
						case <-holdingDone:
							return
						case <-ticker.C:
							begin := time.Now()
							err := request(peer)
							record(&peer.Holding, "holding", i, -1, begin, err, false)
							if peer.Conn.State().Closed {
								return
							}
						}
					}
				}(i, peer)
			}
		}()
	}
	setupWait.Wait()
	var setup Stats
	established := 0
	for i := range peers {
		peer := &peers[i]
		setup.merge(peer.Setup)
		if peer.Conn != nil {
			established++
			defer peer.Conn.Close()
		}
	}
	encoder := json.NewEncoder(os.Stdout)
	waitForStart := func() {
		var startNS int64
		if _, err := fmt.Fscan(os.Stdin, &startNS); err != nil {
			panic(err)
		}
		time.Sleep(time.Until(time.Unix(0, startNS)))
	}
	if *synchronize {
		if err := encoder.Encode(map[string]any{"phase": "prepared", "requested": *connections,
			"established": established, "setup": setup}); err != nil {
			panic(err)
		}
		// Other processes may still be opening connections. Keep this population alive
		// until the supervisor schedules warmup for all processes together.
		waitForStart()
	}
	close(holdingDone)
	holdingWait.Wait()
	var holding Stats
	for i := range peers {
		holding.merge(peers[i].Holding)
	}
	phase := func(label string, seconds time.Duration, measure bool) (Stats, time.Time, time.Time) {
		start := time.Now()
		deadline := start.Add(seconds)
		results := make([]Stats, len(peers)**streams)
		var wait sync.WaitGroup
		for i := range peers {
			peer := &peers[i]
			if peer.Conn == nil {
				continue
			}
			for slot := 0; slot < *streams; slot++ {
				i, slot := i, slot
				stats := &results[i**streams+slot]
				wait.Add(1)
				go func() {
					defer wait.Done()
					for time.Now().Before(deadline) {
						begin := time.Now()
						err := request(peer)
						record(stats, label, i, slot, begin, err, measure)
						if measure {
							peer.Attempted.Add(1)
							if err == nil {
								peer.Succeeded.Add(1)
							}
						}
						if err != nil {
							if peer.Conn.State().Closed || !peer.Conn.CanTakeNewRequest() {
								return
							}
							// Prevent immediate stream rejections from becoming an unbounded retry spin.
							time.Sleep(10 * time.Millisecond)
						}
					}
				}()
			}
		}
		wait.Wait()
		time.Sleep(time.Until(deadline))
		end := time.Now()
		var total Stats
		for _, result := range results {
			total.merge(result)
		}
		return total, start, end
	}
	warm, _, _ := phase("warmup", *warmup, false)
	ready := 0
	for i := range peers {
		peer := &peers[i]
		if peer.Conn != nil && !peer.Conn.State().Closed && !peer.Conn.State().Closing {
			ready++
		}
	}
	if *synchronize {
		if err := encoder.Encode(map[string]any{"phase": "ready", "requested": *connections, "established": established, "ready_connections": ready,
			"setup": setup, "holding": holding, "warmup": warm}); err != nil {
			panic(err)
		}
		waitForStart()
	}
	ready = 0
	for i := range peers {
		conn := peers[i].Conn
		if conn != nil && !conn.State().Closed && !conn.State().Closing {
			ready++
		}
	}
	before := cpuSeconds()
	measured, start, end := phase("measurement", *duration, true)
	cpu := cpuSeconds() - before
	if *synchronize {
		encoder.Encode(map[string]any{"phase": "measured", "start_ns": start.UnixNano(), "end_ns": end.UnixNano()})
	}
	sort.Slice(measured.Samples, func(i, j int) bool { return measured.Samples[i] < measured.Samples[j] })
	sort.Slice(measured.FailureSamples, func(i, j int) bool { return measured.FailureSamples[i] < measured.FailureSamples[j] })
	participated, succeeded, alive := 0, 0, 0
	for i := range peers {
		peer := &peers[i]
		if peer.Attempted.Load() > 0 {
			participated++
		}
		if peer.Succeeded.Load() > 0 {
			succeeded++
		}
		if peer.Conn != nil && !peer.Conn.State().Closed && !peer.Conn.State().Closing {
			alive++
		}
	}
	if err := buffer.Flush(); err != nil {
		panic(err)
	}
	elapsed := end.Sub(start).Seconds()
	if elapsed < duration.Seconds() {
		elapsed = duration.Seconds()
	}
	encoder.Encode(map[string]any{"phase": "result", "requested_connections": *connections, "streams": *streams,
		"setup": setup, "setup_unattempted": int64(*connections) - setup.Attempted, "holding": holding, "warmup": warm, "measurement": measured,
		"established_connections": established, "ready_connections": ready, "participating_connections": participated,
		"successful_connections": succeeded, "alive_connections": alive, "reconnections": 0,
		"start_ns": start.UnixNano(), "end_ns": end.UnixNano(), "seconds": elapsed, "window_seconds": duration.Seconds(),
		"requests_per_second": float64(measured.Succeeded) / elapsed, "client_cpu_seconds": cpu,
		"p50_ms": quantile(measured.Samples, 50), "p99_ms": quantile(measured.Samples, 99),
		"failure_p99_ms": quantile(measured.FailureSamples, 99), "latency_us": histogram(measured.Samples),
		"failure_latency_us": histogram(measured.FailureSamples), "failure_log_entries": logCount})
}
