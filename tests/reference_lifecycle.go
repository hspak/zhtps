package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

var holding atomic.Uint64
var released atomic.Uint64

func respond(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/lifecycle-early":
		w.WriteHeader(403)
		io.WriteString(w, "denied")
	case "/lifecycle-echo":
		body, err := io.ReadAll(r.Body)
		if err != nil {
			// Native handlers do not return errors; this mapping belongs to the fixture.
			http.Error(w, "invalid body", 400)
			return
		}
		w.Write(body)
	case "/large":
		w.Header().Set("Content-Length", "8388608")
		io.Copy(w, strings.NewReader(strings.Repeat("x", 8*1024*1024)))
	case "/stream-cancel":
		holding.Add(1)
		defer released.Add(1)
		io.WriteString(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	case "/timeout", "/lifecycle-delay":
		// No application watchdog: this probes the distinction from transport timeouts.
		time.Sleep(250 * time.Millisecond)
		io.WriteString(w, "late")
	case "/inspect":
		json.NewEncoder(w).Encode(map[string]uint64{"holding": holding.Load(), "released": released.Load()})
	default:
		io.WriteString(w, "ok")
	}
}

func main() {
	milliseconds, err := strconv.Atoi(os.Args[1])
	if err != nil {
		panic(err)
	}
	reading := time.Duration(milliseconds) * time.Millisecond
	server := http.Server{
		Handler:           http.HandlerFunc(respond),
		ReadHeaderTimeout: reading,
		ReadTimeout:       reading,
		WriteTimeout:      600 * time.Millisecond,
		IdleTimeout:       300 * time.Millisecond,
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	go func() {
		if err := server.Serve(listener); err != http.ErrServerClosed {
			panic(err)
		}
	}()
	<-signals
	fmt.Fprintln(os.Stderr, "shutdown_started")
	deadline, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()
	if server.Shutdown(deadline) != nil {
		server.Close()
	}
}
