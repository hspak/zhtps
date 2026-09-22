// Fixed-rate offers are scheduled independently of response completions. Bounded
// generator queues and request deadlines make unsent load explicit in the report.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type offeredPhase struct {
	rate     int64
	duration time.Duration
}

func parseSchedule(value string) ([]offeredPhase, error) {
	var phases []offeredPhase
	for _, item := range strings.Split(value, ",") {
		parts := strings.SplitN(item, ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("phase must be rate:duration")
		}
		rate, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil || rate < 1 || rate > 50_000_000 {
			return nil, fmt.Errorf("rate must be 1..50000000")
		}
		duration, err := time.ParseDuration(parts[1])
		if err != nil || duration <= 0 || duration > time.Hour {
			return nil, fmt.Errorf("duration must be positive and at most one hour")
		}
		phases = append(phases, offeredPhase{rate, duration})
	}
	if len(phases) > 16 {
		return nil, fmt.Errorf("at most 16 phases")
	}
	return phases, nil
}

func (p offeredPhase) offers() int64 {
	return int64(p.duration/time.Second)*p.rate + int64(p.duration%time.Second)*p.rate/int64(time.Second)
}

func (p offeredPhase) offset(index int64) time.Duration {
	return time.Duration(index/p.rate)*time.Second + time.Duration(index%p.rate*int64(time.Second)/p.rate)
}

type offeredOptions struct {
	sourceIPs                            int
	address                              string
	connections, shards, queue           int
	churn                                bool
	timeout, maxLag                      time.Duration
	phases                               []offeredPhase
	method, path, contentType, userAgent string
	requestBody, expectedBody            []byte
	maxRequests                          uint64
	allowChunked                         bool
	wireRequest                          string
}

func readWorkloadFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, 64*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(body) > 64*1024*1024 {
		return nil, fmt.Errorf("workload body exceeds 64 MiB")
	}
	return body, nil
}

func (options *offeredOptions) prepare() error {
	if options.method == "" {
		options.method = "GET"
	}
	if options.path == "" {
		options.path = "/"
	}
	if options.expectedBody == nil {
		options.expectedBody = []byte("ZHTPS\n")
	}
	if options.contentType == "" {
		options.contentType = "application/octet-stream"
	}
	if !strings.HasPrefix(options.path, "/") || strings.ContainsAny(options.path, "\r\n \t") ||
		strings.ContainsAny(options.contentType, "\r\n") || strings.ContainsAny(options.userAgent, "\r\n") {
		return fmt.Errorf("invalid request path, content type, or user agent")
	}
	if _, _, err := net.SplitHostPort(options.address); err != nil {
		return err
	}
	if _, err := http.NewRequest(options.method, "http://"+options.address+options.path, nil); err != nil {
		return err
	}
	if len(options.requestBody) > 64*1024*1024 || len(options.expectedBody) > 64*1024*1024 {
		return fmt.Errorf("workload body exceeds 64 MiB")
	}
	header := options.method + " " + options.path + " HTTP/1.1\r\nHost: " + options.address + "\r\n"
	if options.userAgent != "" {
		header += "User-Agent: " + options.userAgent + "\r\n"
	}
	if len(options.requestBody) != 0 || options.method == "POST" || options.method == "PUT" || options.method == "PATCH" {
		header += fmt.Sprintf("Content-Length: %d\r\nContent-Type: %s\r\n", len(options.requestBody), options.contentType)
	}
	options.wireRequest = header + "\r\n" + string(options.requestBody)
	return nil
}

type offer struct {
	phase     int
	scheduled time.Time
}

type offeredOutcome struct {
	started, sent, connections, expired uint64
	dialAttempts, writtenBytes          uint64
	success, service, rejected, failed  histogram
	failures                            map[string]uint64
	windowSuccesses                     uint64
}

type offerSchedule struct {
	dropped uint64
	lag     histogram
}

type offeredClient struct {
	conn        net.Conn
	reader      *bufio.Reader
	request     string
	requestInfo http.Request
	localAddr   *net.TCPAddr
	requests    uint64
	bodyBuffer  [4096]byte
}

func (c *offeredClient) close() {
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
	c.requests = 0
}

func deferSourcePort(_, _ string, raw syscall.RawConn) error {
	var optionError error
	err := raw.Control(func(fd uintptr) {
		// IP_BIND_ADDRESS_NO_PORT keeps bind(port=0) from scanning/reserving the
		// source port range before connect can apply TCP TIME_WAIT reuse rules.
		optionError = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, 24, 1)
	})
	if err != nil {
		return err
	}
	return optionError
}

func (c *offeredClient) exchange(options offeredOptions, result *offeredOutcome, deadline time.Time) error {
	if c.conn == nil {
		var err error
		result.dialAttempts++
		dialer := net.Dialer{Deadline: deadline, LocalAddr: c.localAddr}
		if c.localAddr != nil {
			dialer.Control = deferSourcePort
		}
		c.conn, err = dialer.Dial("tcp", options.address)
		if err != nil {
			return err
		}
		result.connections++
		if c.reader == nil {
			c.reader = bufio.NewReader(c.conn)
		} else {
			c.reader.Reset(c.conn)
		}
	}
	if err := c.conn.SetDeadline(deadline); err != nil {
		return err
	}
	written, err := io.WriteString(c.conn, c.request)
	result.writtenBytes += uint64(written)
	if err != nil {
		return err
	}
	if written != len(c.request) {
		return io.ErrShortWrite
	}
	result.sent++
	c.requests++
	response, err := http.ReadResponse(c.reader, &c.requestInfo)
	if err != nil {
		return err
	}
	if response.StatusCode != 200 {
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
		if response.Close || options.churn || (options.maxRequests != 0 && c.requests >= options.maxRequests) {
			c.close()
		}
		return httpFailure{response.StatusCode}
	}
	chunked := options.allowChunked && response.ContentLength == -1 &&
		len(response.TransferEncoding) == 1 && response.TransferEncoding[0] == "chunked"
	if response.ContentLength != int64(len(options.expectedBody)) && !chunked {
		return fmt.Errorf("unexpected content length %d", response.ContentLength)
	}
	remaining := options.expectedBody
	for len(remaining) != 0 {
		amount := min(len(remaining), len(c.bodyBuffer))
		if _, err := io.ReadFull(response.Body, c.bodyBuffer[:amount]); err != nil {
			return err
		}
		if !bytes.Equal(c.bodyBuffer[:amount], remaining[:amount]) {
			return fmt.Errorf("unexpected response body")
		}
		remaining = remaining[amount:]
	}
	if chunked {
		n, err := io.ReadFull(response.Body, c.bodyBuffer[:1])
		if err != nil && err != io.EOF {
			return err
		}
		if n != 0 || err != io.EOF {
			return fmt.Errorf("unexpected chunked response boundary")
		}
	}
	if err := response.Body.Close(); err != nil {
		return err
	}
	if response.Close || options.churn || (options.maxRequests != 0 && c.requests >= options.maxRequests) {
		c.close()
	}
	return nil
}

func offeredWorker(options offeredOptions, index int, jobs <-chan offer, ends []time.Time, results []*offeredOutcome) {
	client := offeredClient{request: options.wireRequest, requestInfo: http.Request{Method: options.method}}
	defer client.close()
	if options.sourceIPs > 0 {
		client.localAddr = &net.TCPAddr{IP: net.IPv4(127, 0, 0, byte(2+index%options.sourceIPs))}
	}
	for job := range jobs {
		if results[job.phase] == nil {
			results[job.phase] = new(offeredOutcome)
		}
		result := results[job.phase]
		started := time.Now()
		if started.Sub(job.scheduled) > options.maxLag || !started.Before(ends[job.phase]) {
			result.expired++
			continue
		}
		result.started++
		err := client.exchange(options, result, started.Add(options.timeout))
		finished := time.Now()
		if err == nil {
			result.success.record(finished.Sub(job.scheduled))
			result.service.record(finished.Sub(started))
			if finished.Before(ends[job.phase]) {
				result.windowSuccesses++
			}
		} else {
			kind := failureKind(err)
			countFailure(&result.failures, kind)
			if strings.HasPrefix(kind, "http_") {
				result.rejected.record(finished.Sub(job.scheduled))
			} else {
				result.failed.record(finished.Sub(job.scheduled))
			}
			var rejection httpFailure
			if !errors.As(err, &rejection) {
				client.close()
			}
		}
	}
}

func scheduleOffers(options offeredOptions, shard int, starts []time.Time, jobs chan<- offer, results []offerSchedule) {
	defer close(jobs)
	for phaseIndex, phase := range options.phases {
		result := &results[phaseIndex]
		for index := int64(shard); index < phase.offers(); {
			scheduled := starts[phaseIndex].Add(phase.offset(index))
			now := time.Now()
			if scheduled.After(now) {
				time.Sleep(scheduled.Sub(now))
				now = time.Now()
			}
			// Catch up scheduled offers without blocking on network workers. A late
			// generator is never allowed to turn old offers into an unbounded burst.
			for index < phase.offers() {
				scheduled = starts[phaseIndex].Add(phase.offset(index))
				if scheduled.After(now) {
					break
				}
				lag := now.Sub(scheduled)
				result.lag.record(lag)
				if lag > options.maxLag {
					result.dropped++
				} else {
					select {
					case jobs <- offer{phaseIndex, scheduled}:
					default:
						result.dropped++
					}
				}
				index += int64(options.shards)
			}
		}
	}
}

func latencyReport(h *histogram) map[string]any {
	return map[string]any{"count": h.count, "p50_us": h.quantile(.5), "p95_us": h.quantile(.95),
		"p99_us": h.quantile(.99), "p999_us": h.quantile(.999), "p9999_us": h.quantile(.9999),
		"max_us": float64(h.max) / 1000}
}

func runOffered(options offeredOptions) map[string]any {
	if err := options.prepare(); err != nil {
		panic(err)
	}
	starts, ends := make([]time.Time, len(options.phases)), make([]time.Time, len(options.phases))
	started := time.Now().Add(250 * time.Millisecond)
	next := started
	for index, phase := range options.phases {
		starts[index] = next
		next = next.Add(phase.duration)
		ends[index] = next
	}
	results := make([][]*offeredOutcome, options.connections)
	schedules := make([][]offerSchedule, options.shards)
	var workers, schedulers sync.WaitGroup
	cpuStart := cpuSeconds()
	for shard := 0; shard < options.shards; shard++ {
		jobs := make(chan offer, options.queue)
		for index := shard; index < options.connections; index += options.shards {
			results[index] = make([]*offeredOutcome, len(options.phases))
			workers.Add(1)
			go func(index int) { defer workers.Done(); offeredWorker(options, index, jobs, ends, results[index]) }(index)
		}
		schedules[shard] = make([]offerSchedule, len(options.phases))
		schedulers.Add(1)
		go func(shard int) {
			defer schedulers.Done()
			scheduleOffers(options, shard, starts, jobs, schedules[shard])
		}(shard)
	}
	schedulers.Wait()
	workers.Wait()
	finished := time.Now()
	var phases []map[string]any
	for phaseIndex, phase := range options.phases {
		var combined offeredOutcome
		var scheduling offerSchedule
		for _, worker := range results {
			result := worker[phaseIndex]
			if result == nil {
				continue
			}
			combined.started += result.started
			combined.sent += result.sent
			combined.connections += result.connections
			combined.dialAttempts += result.dialAttempts
			combined.writtenBytes += result.writtenBytes
			combined.expired += result.expired
			combined.windowSuccesses += result.windowSuccesses
			combined.success.merge(&result.success)
			combined.service.merge(&result.service)
			combined.rejected.merge(&result.rejected)
			combined.failed.merge(&result.failed)
			for kind, count := range result.failures {
				if combined.failures == nil {
					combined.failures = make(map[string]uint64)
				}
				combined.failures[kind] += count
			}
		}
		for _, schedule := range schedules {
			scheduling.dropped += schedule[phaseIndex].dropped
			scheduling.lag.merge(&schedule[phaseIndex].lag)
		}
		accounted := combined.success.count + combined.rejected.count + combined.failed.count + combined.expired + scheduling.dropped
		if accounted != uint64(phase.offers()) {
			panic("lost scheduled offers")
		}
		phases = append(phases, map[string]any{
			"offered_rate": phase.rate, "duration_seconds": phase.duration.Seconds(), "offered": phase.offers(),
			"started": combined.started, "sent": combined.sent, "sent_per_second": float64(combined.sent) / phase.duration.Seconds(),
			"connections_opened": combined.connections, "generator_queue_drops": scheduling.dropped, "generator_expired": combined.expired,
			"dial_attempts": combined.dialAttempts, "request_bytes_written": combined.writtenBytes,
			"response_bytes_validated": combined.success.count * uint64(len(options.expectedBody)),
			"successes":                combined.success.count, "window_successes": combined.windowSuccesses,
			"window_successes_per_second": float64(combined.windowSuccesses) / phase.duration.Seconds(),
			"failures":                    combined.failures, "success_latency": latencyReport(&combined.success),
			"success_service_latency": latencyReport(&combined.service), "rejection_latency": latencyReport(&combined.rejected),
			"failure_latency": latencyReport(&combined.failed), "scheduler_lag": latencyReport(&scheduling.lag),
			"start_unix_ns": starts[phaseIndex].UnixNano(), "end_unix_ns": ends[phaseIndex].UnixNano(),
		})
	}
	return map[string]any{"phases": phases, "connections": options.connections, "shards": options.shards,
		"queue_per_shard": options.queue, "churn": options.churn, "timeout_ms": options.timeout.Milliseconds(),
		"max_generator_lag_ms": options.maxLag.Milliseconds(), "generator_cpu_seconds": cpuSeconds() - cpuStart,
		"source_ips": options.sourceIPs,
		"go_version": runtime.Version(), "gomaxprocs": runtime.GOMAXPROCS(0),
		"workload": map[string]any{"method": options.method, "path": options.path,
			"request_body_bytes": len(options.requestBody), "expected_body_bytes": len(options.expectedBody),
			"content_type": options.contentType, "user_agent": options.userAgent, "allow_chunked": options.allowChunked,
			"request_body_sha256":         fmt.Sprintf("%x", sha256.Sum256(options.requestBody)),
			"expected_body_sha256":        fmt.Sprintf("%x", sha256.Sum256(options.expectedBody)),
			"max_requests_per_connection": options.maxRequests},
		"elapsed_seconds": finished.Sub(started).Seconds()}
}
