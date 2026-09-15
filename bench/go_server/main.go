// A minimal net/http baseline for the GET / benchmark.
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

func main() {
	address := flag.String("listen", "127.0.0.1:8080", "listen address")
	certificate := flag.String("tls-certificate", "", "PEM certificate for TLS 1.3")
	key := flag.String("tls-key", "", "PEM private key")
	http2 := flag.Bool("http2", false, "enable HTTP/2 for the TLS comparison")
	flag.Parse()
	if (*certificate == "") != (*key == "") {
		log.Fatal("TLS requires both certificate and key")
	}
	json.NewEncoder(os.Stdout).Encode(map[string]int{
		"gomaxprocs": runtime.GOMAXPROCS(0),
		"num_cpu":    runtime.NumCPU(),
	})
	server := &http.Server{
		Addr: *address,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "GET" || r.URL.Path != "/" {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Header().Set("ETag", `"zhtps-root-v1"`)
			w.Header().Set("Content-Length", "6")
			io.WriteString(w, "ZHTPS\n")
		}),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       15 * time.Second,
	}
	if *certificate != "" {
		server.TLSConfig = &tls.Config{
			MinVersion: tls.VersionTLS13,
			MaxVersion: tls.VersionTLS13,
			NextProtos: []string{"http/1.1"},
		}
		if *http2 {
			server.TLSConfig.NextProtos = []string{"h2", "http/1.1"}
		} else {
			server.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
		}
		log.Fatal(server.ListenAndServeTLS(*certificate, *key))
	}
	log.Fatal(server.ListenAndServe())
}
