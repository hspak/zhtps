// Linux socket observations for separate diagnostic runs. No probes run by default.
package main

import (
	"encoding/json"
	"errors"
	"net"
	"syscall"
	"time"
	"unsafe"
)

type RequestError struct {
	Err     error
	Stage   string
	WroteNS int64
}

func (e *RequestError) Error() string { return e.Err.Error() }
func (e *RequestError) Unwrap() error { return e.Err }

func socketInfo(conn *net.TCPConn) ([]byte, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return nil, err
	}
	buffer := make([]byte, 512)
	length := uint32(len(buffer))
	var probeErr error
	err = raw.Control(func(fd uintptr) {
		_, _, code := syscall.Syscall6(syscall.SYS_GETSOCKOPT, fd, syscall.IPPROTO_TCP,
			syscall.TCP_INFO, uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&length)), 0)
		if code != 0 {
			probeErr = code
		}
	})
	if err != nil {
		return nil, err
	}
	if probeErr != nil {
		return nil, probeErr
	}
	return buffer[:length], nil
}

func observeFailure(peer *Peer, failure error, failed time.Time, observer string) map[string]any {
	row := map[string]any{"failed_unix_ns": failed.UnixNano(), "capture_started_ns": time.Now().UnixNano(),
		"client": peer.Socket.LocalAddr().String(), "server": peer.Socket.RemoteAddr().String(),
		"http2": peer.Conn.State()}
	var request *RequestError
	if errors.As(failure, &request) {
		row["stage"] = request.Stage
		row["wrote_request_ns"] = request.WroteNS
	}
	info, err := socketInfo(peer.Socket)
	row["client_tcp_info_raw"] = info
	row["client_snapshot_ns"] = time.Now().UnixNano()
	if err != nil {
		row["probe_error"] = err.Error()
	}
	// One notification per captured connection; requests on other streams can continue.
	requestBody, _ := json.Marshal(map[string]any{"id": peer.Socket.LocalAddr().String(),
		"failed_unix_ns": failed.UnixNano(), "client": peer.Socket.LocalAddr().String(),
		"server": peer.Socket.RemoteAddr().String()})
	conn, err := net.DialTimeout("udp4", observer, 50*time.Millisecond)
	if err != nil {
		row["observer_error"] = err.Error()
		return row
	}
	defer conn.Close()
	for attempt := 1; attempt <= 3; attempt++ {
		row["observer_attempts"] = attempt
		conn.SetDeadline(time.Now().Add(50 * time.Millisecond))
		if _, err = conn.Write(requestBody); err != nil {
			continue
		}
		buffer := make([]byte, 2048)
		var n int
		n, err = conn.Read(buffer)
		if err != nil {
			continue
		}
		var reply map[string]json.RawMessage
		if err = json.Unmarshal(buffer[:n], &reply); err != nil {
			continue
		}
		var id string
		var timestamp int64
		json.Unmarshal(reply["id"], &id)
		json.Unmarshal(reply["failed_unix_ns"], &timestamp)
		if id != peer.Socket.LocalAddr().String() || timestamp != failed.UnixNano() {
			err = errors.New("observer acknowledgment did not match failure")
			continue
		}
		row["observer_reply"] = reply
		row["observer_finished_ns"] = time.Now().UnixNano()
		return row
	}
	if err != nil {
		row["observer_error"] = err.Error()
	}
	return row
}
