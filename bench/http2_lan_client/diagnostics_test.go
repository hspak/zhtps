package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestSocketInfoTracksRealTraffic(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.Dial("tcp4", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	before, err := socketInfo(client.(*net.TCPConn))
	if err != nil {
		t.Fatal(err)
	}
	if len(before) < 136 || before[0] != 1 {
		t.Fatalf("invalid TCP_INFO %v", before)
	}
	server.Write([]byte("response"))
	buffer := make([]byte, 8)
	client.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := client.Read(buffer); err != nil {
		t.Fatal(err)
	}
	after, err := socketInfo(client.(*net.TCPConn))
	if err != nil {
		t.Fatal(err)
	}
	if delta := binary.NativeEndian.Uint64(after[128:136]) - binary.NativeEndian.Uint64(before[128:136]); delta != 8 {
		t.Fatalf("received TCP byte delta = %d, want 8", delta)
	}
	client.Close()
	if _, err := socketInfo(client.(*net.TCPConn)); err == nil {
		t.Fatal("closed socket probe succeeded")
	}
}

func TestHTTP2TimeoutDiagnostics(t *testing.T) {
	binaryPath := os.Getenv("HTTP2_DIAGNOSTIC_CLIENT")
	if binaryPath == "" {
		t.Skip("set HTTP2_DIAGNOSTIC_CLIENT to the freshly built client")
	}
	for _, stage := range []string{"headers", "body"} {
		t.Run(stage, func(t *testing.T) {
			var requests atomic.Int64
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/plain; charset=utf-8")
				w.Header().Set("ETag", `"zhtps-root-v1"`)
				w.Header().Set("Content-Length", "6")
				if requests.Add(1) == 1 {
					w.Write([]byte("ZHTPS\n"))
					return
				}
				if stage == "body" {
					w.Write([]byte("ZH"))
					w.(http.Flusher).Flush()
				}
				<-r.Context().Done()
			}))
			server.EnableHTTP2 = true
			server.StartTLS()
			defer server.Close()
			folder := t.TempDir()
			certificate := filepath.Join(folder, "cert.pem")
			os.WriteFile(certificate, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600)
			observer, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer observer.Close()
			notified := make(chan map[string]any, 1)
			go func() {
				buffer := make([]byte, 2048)
				n, address, err := observer.ReadFrom(buffer)
				if err != nil {
					return
				}
				var row map[string]any
				decoder := json.NewDecoder(bytes.NewReader(buffer[:n]))
				decoder.UseNumber()
				decoder.Decode(&row)
				row["captured"] = true
				response, _ := json.Marshal(row)
				observer.WriteTo(response, address)
				notified <- row
			}()
			failurePath := filepath.Join(folder, "failures.jsonl")
			command := exec.Command(binaryPath, "-url", server.URL, "-ca", certificate,
				"-connections", "1", "-streams", "4", "-warmup", "0s", "-duration", "10ms",
				"-timeout", "100ms", "-failures", failurePath, "-diagnostic-observer", observer.LocalAddr().String())
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("client: %v: %s", err, output)
			}
			var result struct {
				Measurement       Stats `json:"measurement"`
				FailureLogEntries int   `json:"failure_log_entries"`
			}
			if err := json.Unmarshal(output, &result); err != nil {
				t.Fatalf("%v: %s", err, output)
			}
			if result.Measurement.Failed != 4 || result.FailureLogEntries != 4 {
				t.Fatalf("lost failure accounting: %s", output)
			}
			file, err := os.Open(failurePath)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			scanner := bufio.NewScanner(file)
			captured := 0
			for scanner.Scan() {
				var row map[string]any
				if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
					t.Fatal(err)
				}
				if row["kind"] != "timeout" {
					t.Fatalf("wrong failure category: %v", row)
				}
				if value, ok := row["diagnostic"]; ok {
					captured++
					diagnostic := value.(map[string]any)
					if diagnostic["stage"] != stage || diagnostic["wrote_request_ns"].(float64) <= 0 {
						t.Fatalf("wrong request stage: %v", diagnostic)
					}
					if diagnostic["client_tcp_info_raw"] == nil || diagnostic["probe_error"] != nil || diagnostic["observer_error"] != nil {
						t.Fatalf("probe failed: %v", diagnostic)
					}
				}
			}
			if err := scanner.Err(); err != nil {
				t.Fatal(err)
			}
			if captured != 1 {
				t.Fatalf("captured %d times for one connection", captured)
			}
			select {
			case <-notified:
			case <-time.After(time.Second):
				t.Fatal("server observer was not notified")
			}
		})
	}
}
