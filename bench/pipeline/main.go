// A bounded closed-loop HTTP workload for pipelining and fragmented writes.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"
	"time"
)

func main() {
	address := flag.String("address", "127.0.0.1:8080", "server")
	connections := flag.Int("connections", 64, "persistent connections")
	depth := flag.Int("depth", 1, "requests per batch")
	fragment := flag.Int("fragment", 0, "maximum bytes per write; zero sends each batch together")
	duration := flag.Duration("duration", 5*time.Second, "measurement interval")
	flag.Parse()
	if *connections < 1 || *depth < 1 || *depth > 64 || *fragment < 0 || *duration <= 0 {
		panic("invalid workload")
	}
	request := []byte("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
	batch := bytes.Repeat(request, *depth)
	type result struct {
		Count uint64
		Error string
	}
	results := make(chan result, *connections)
	start := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(*connections)
	deadline := time.Time{}
	for worker := 0; worker < *connections; worker++ {
		go func() {
			connection, err := net.DialTimeout("tcp", *address, time.Second)
			ready.Done()
			if err != nil {
				results <- result{Error: err.Error()}
				return
			}
			defer connection.Close()
			reader := bufio.NewReader(connection)
			<-start
			var count uint64
			for time.Now().Before(deadline) {
				connection.SetDeadline(time.Now().Add(2 * time.Second))
				for offset := 0; offset < len(batch); {
					end := len(batch)
					if *fragment > 0 && end-offset > *fragment {
						end = offset + *fragment
					}
					n, e := connection.Write(batch[offset:end])
					if e != nil {
						results <- result{count, e.Error()}
						return
					}
					offset += n
				}
				for i := 0; i < *depth; i++ {
					response, e := http.ReadResponse(reader, &http.Request{Method: "GET"})
					if e != nil {
						results <- result{count, e.Error()}
						return
					}
					body, e := io.ReadAll(response.Body)
					response.Body.Close()
					if e != nil || response.StatusCode != 200 || !bytes.Equal(body, []byte("ZHTPS\n")) {
						results <- result{count, fmt.Sprintf("bad response: %d %q %v", response.StatusCode, body, e)}
						return
					}
					count++
				}
			}
			results <- result{Count: count}
		}()
	}
	ready.Wait()
	begin := time.Now()
	deadline = begin.Add(*duration)
	close(start)
	var total uint64
	var failures []string
	for worker := 0; worker < *connections; worker++ {
		r := <-results
		total += r.Count
		if r.Error != "" {
			failures = append(failures, r.Error)
		}
	}
	elapsed := time.Since(begin).Seconds()
	json.NewEncoder(os.Stdout).Encode(map[string]any{"connections": *connections, "depth": *depth, "fragment_bytes": *fragment, "validated_responses": total, "elapsed_seconds": elapsed, "responses_per_second": float64(total) / elapsed, "failures": failures})
	if len(failures) > 0 {
		os.Exit(1)
	}
}
