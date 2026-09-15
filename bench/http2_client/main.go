// A verified net/http HTTP/2 load generator with fixed connection/stream counts.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type result struct {
	samples  []time.Duration
	requests int64
	errors   int64
	first    string
}

func cpuSeconds() float64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return float64(usage.Utime.Sec+usage.Stime.Sec) +
		float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
}

func main() {
	url := flag.String("url", "https://localhost:8443/", "target URL")
	ca := flag.String("ca", "", "test certificate")
	connections := flag.Int("connections", 1, "independent HTTP/2 connections")
	streams := flag.Int("streams", 32, "concurrent requests per connection")
	duration := flag.Duration("duration", 3*time.Second, "measurement duration")
	warmup := flag.Duration("warmup", 2*time.Second, "unmeasured concurrent warmup")
	synchronize := flag.Bool("synchronize", false, "emit ready, read start Unix nanoseconds from stdin")
	flag.Parse()
	if *connections < 1 || *streams < 1 || *streams > 100 || *duration <= 0 || *warmup < 0 {
		panic("positive connections/duration, 1..100 streams and nonnegative warmup required")
	}
	pem, err := os.ReadFile(*ca)
	if err != nil {
		panic(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		panic("invalid CA")
	}
	var clients []*http.Client
	var dials atomic.Int64
	request := func(client *http.Client) error {
		response, err := client.Get(*url)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err != nil {
			return err
		}
		if response.ProtoMajor != 2 || response.StatusCode != 200 || string(body) != "ZHTPS\n" ||
			response.TLS == nil || response.TLS.Version != tls.VersionTLS13 ||
			response.TLS.NegotiatedProtocol != "h2" ||
			response.Header.Get("Content-Type") != "text/plain; charset=utf-8" ||
			response.Header.Get("ETag") != `"zhtps-root-v1"` || response.ContentLength != 6 {
			return fmt.Errorf("unexpected response: %s %d %q %v", response.Proto, response.StatusCode, body, response.Header)
		}
		if _, err := http.ParseTime(response.Header.Get("Date")); err != nil {
			return fmt.Errorf("invalid Date header: %w", err)
		}
		return nil
	}
	for i := 0; i < *connections; i++ {
		dialer := &net.Dialer{Timeout: 5 * time.Second}
		transport := &http.Transport{
			ForceAttemptHTTP2: true,
			TLSClientConfig: &tls.Config{
				RootCAs: roots, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
			},
			MaxConnsPerHost: 1,
			DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
				dials.Add(1)
				return dialer.DialContext(ctx, network, address)
			},
		}
		defer transport.CloseIdleConnections()
		client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
		if err := request(client); err != nil {
			panic(err)
		}
		clients = append(clients, client)
	}
	phase := func(start time.Time, duration time.Duration, record bool) (result, time.Time) {
		deadline := start.Add(duration)
		results := make([]result, *connections**streams)
		var wait sync.WaitGroup
		for i, client := range clients {
			for stream := 0; stream < *streams; stream++ {
				local := &results[i**streams+stream]
				wait.Add(1)
				go func() {
					defer wait.Done()
					for time.Now().Before(deadline) {
						begin := time.Now()
						if err := request(client); err != nil {
							local.errors++
							if local.first == "" {
								local.first = err.Error()
							}
							continue
						}
						local.requests++
						if record {
							local.samples = append(local.samples, time.Since(begin))
						}
					}
				}()
			}
		}
		wait.Wait()
		end := time.Now()
		var total result
		for _, local := range results {
			total.requests += local.requests
			total.errors += local.errors
			if total.first == "" {
				total.first = local.first
			}
		}
		if record {
			total.samples = make([]time.Duration, 0, total.requests)
		}
		for _, local := range results {
			total.samples = append(total.samples, local.samples...)
		}
		return total, end
	}
	warm, _ := phase(time.Now(), *warmup, false)
	if warm.errors != 0 {
		panic(warm.first)
	}
	encoder := json.NewEncoder(os.Stdout)
	if *synchronize {
		encoder.Encode(map[string]any{"phase": "ready", "warmup_requests": warm.requests})
		var startNS int64
		if _, err := fmt.Fscan(os.Stdin, &startNS); err != nil {
			panic(err)
		}
		time.Sleep(time.Until(time.Unix(0, startNS)))
	}
	before := cpuSeconds()
	start := time.Now()
	measured, end := phase(start, *duration, true)
	cpu := cpuSeconds() - before
	if *synchronize {
		encoder.Encode(map[string]any{"phase": "measured", "end_ns": end.UnixNano()})
	}
	elapsed := end.Sub(start).Seconds()
	sort.Slice(measured.samples, func(i, j int) bool { return measured.samples[i] < measured.samples[j] })
	percentile := func(p int) float64 {
		if len(measured.samples) == 0 {
			return 0
		}
		return float64(measured.samples[(len(measured.samples)-1)*p/100]) / float64(time.Millisecond)
	}
	// Mergeable upper bounds keep aggregate percentiles request-weighted.
	// Resolution is one microsecond below 1 ms and at most 1% above it.
	histogram := make(map[int64]int64)
	for _, latency := range measured.samples {
		micros := (latency.Nanoseconds() + 999) / 1000
		width := int64(1)
		for micros > 1000*width {
			width *= 10
		}
		histogram[(micros+width-1)/width*width]++
	}
	encoder.Encode(map[string]any{
		"requests": measured.requests, "errors": measured.errors, "first_error": measured.first,
		"seconds": elapsed, "requests_per_second": float64(measured.requests) / elapsed,
		"p50_ms": percentile(50), "p99_ms": percentile(99), "latency_us": histogram,
		"connections": *connections, "connections_opened": dials.Load(), "streams": *streams,
		"warmup_requests": warm.requests, "client_cpu_seconds": cpu,
		"start_ns": start.UnixNano(), "end_ns": end.UnixNano(),
	})
	if measured.errors != 0 || dials.Load() != int64(*connections) {
		os.Exit(1)
	}
}
