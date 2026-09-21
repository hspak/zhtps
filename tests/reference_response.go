package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
)

func respond(w http.ResponseWriter, r *http.Request) {
	name := r.URL.RawQuery
	if name == "panic-before" {
		panic("response comparison panic")
	}
	if name == "handler-error" {
		// Native handlers do not return errors; this mapping belongs to the fixture.
		http.Error(w, "internal error", 500)
		return
	}
	if strings.HasPrefix(name, "stream") || name == "panic-after" {
		switch name {
		case "stream-short":
			w.Header().Set("Content-Length", "9")
		case "stream-long":
			w.Header().Set("Content-Length", "2")
		case "stream-exact", "stream-error-exact":
			w.Header().Set("Content-Length", "3")
		case "stream-trailer":
			w.Header().Set("Trailer", "x-checksum")
		}
		w.(http.Flusher).Flush()
		if name == "stream-error-before" {
			panic(http.ErrAbortHandler)
		}
		if name != "stream-empty" {
			if _, err := w.Write([]byte("abc")); err != nil {
				fmt.Fprintln(os.Stderr, "write_error:", err)
			}
		}
		if name == "stream-trailer" {
			w.Header().Set("x-checksum", "ok")
		}
		if name == "stream-error-after" || name == "stream-error-exact" || name == "panic-after" {
			w.(http.Flusher).Flush()
			if name == "panic-after" {
				panic("response comparison panic")
			}
			panic(http.ErrAbortHandler)
		}
		return
	}
	body := "abc"
	status := 200
	if name == "empty" {
		body = ""
	}
	if strings.HasPrefix(name, "status-") {
		status, _ = strconv.Atoi(strings.TrimPrefix(name, "status-"))
		if status != 304 {
			body = ""
		}
	}
	if name == "body-204" {
		status = 204
	}
	if name == "body-205" {
		status = 205
	}
	switch name {
	case "duplicate-cookie":
		w.Header().Add("Set-Cookie", "a=1")
		w.Header().Add("Set-Cookie", "b=2")
	case "invalid-name":
		w.Header().Set("bad name", "x")
	case "invalid-value":
		w.Header().Set("x-test", "x\r\ny")
	case "nul-value":
		w.Header().Set("x-test", "x\x00y")
	case "whitespace-value":
		w.Header().Set("x-test", " \tabc\t ")
	case "empty-field":
		w.Header().Set("x-test", "")
	}
	w.WriteHeader(status)
	if _, err := w.Write([]byte(body)); err != nil {
		fmt.Fprintln(os.Stderr, "write_error:", err)
	}
}

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	server := http.Server{Handler: http.HandlerFunc(respond)}
	if len(os.Args) == 3 {
		err = server.ServeTLS(listener, os.Args[1], os.Args[2])
	} else {
		err = server.Serve(listener)
	}
	if err != nil {
		panic(err)
	}
}
