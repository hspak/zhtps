// net/http streaming uploads with the same length and IEEE CRC32 response as ZHTPS.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"hash/crc32"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"sync"
	"time"
)

const bodyLimit = 8 * 1024 * 1024

var buffers = sync.Pool{New: func() any { return new([64 * 1024]byte) }}

func main() {
	address := flag.String("listen", "127.0.0.1:8080", "listen address")
	flag.Parse()
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"gomaxprocs": runtime.GOMAXPROCS(0),
		"num_cpu":    runtime.NumCPU(),
		"version":    runtime.Version(),
	})
	server := &http.Server{
		Addr: *address,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == "GET" && r.URL.Path == "/" {
				w.Header().Set("Content-Type", "text/plain; charset=utf-8")
				w.Header().Set("Content-Length", "6")
				io.WriteString(w, "ZHTPS\n")
				return
			}
			if r.Method != "POST" || r.URL.Path != "/upload" {
				http.NotFound(w, r)
				return
			}
			if r.ContentLength > bodyLimit {
				w.Header().Set("Connection", "close")
				http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
				return
			}
			body := http.MaxBytesReader(w, r.Body, bodyLimit)
			buffer := buffers.Get().(*[64 * 1024]byte)
			defer buffers.Put(buffer)
			checksum := crc32.NewIEEE()
			count, err := io.CopyBuffer(checksum, body, buffer[:])
			if err != nil {
				w.Header().Set("Connection", "close")
				http.Error(w, "invalid body", http.StatusBadRequest)
				return
			}
			var storage [64]byte
			response := fmt.Appendf(storage[:0], "%d:%08x\n", count, checksum.Sum32())
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Header().Set("Content-Length", fmt.Sprint(len(response)))
			w.Write(response)
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       15 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}
