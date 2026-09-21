// Minimal application; keep HTTP parsing, expectations and errors at Go defaults.
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
)

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	server := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "body read error", http.StatusBadRequest)
			return
		}
		if r.RequestURI != "/echo" {
			body = []byte("ZHTPS\n")
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	})}
	if len(os.Args) == 3 {
		err = server.ServeTLS(listener, os.Args[1], os.Args[2])
	} else {
		err = server.Serve(listener)
	}
	if err != nil {
		panic(err)
	}
}
