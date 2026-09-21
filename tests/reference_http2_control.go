package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
)

var holding atomic.Uint64
var released atomic.Uint64

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	server := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stream-cancel" {
			holding.Add(1)
			defer released.Add(1)
			io.WriteString(w, "data: first\n\n")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		if r.URL.Path == "/inspect" {
			json.NewEncoder(w).Encode(map[string]uint64{"holding": holding.Load(), "released": released.Load()})
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			// This response mapping belongs to the fixture, not the HTTP/2 parser.
			http.Error(w, "invalid body", 400)
			return
		}
		switch r.URL.Path {
		case "/large":
			body = []byte(strings.Repeat("x", 8*1024*1024))
		case "/lifecycle-echo":
		default:
			body = []byte("ok")
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	})}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	if err := server.ServeTLS(listener, os.Args[1], os.Args[2]); err != nil {
		panic(err)
	}
}
