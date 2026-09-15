// Measure upload checksum work without net/http or socket I/O.
package main

import (
	"encoding/json"
	"hash/crc32"
	"os"
	"syscall"
)

func cpuNs() int64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return (usage.Utime.Sec+usage.Stime.Sec)*1e9 + (usage.Utime.Usec+usage.Stime.Usec)*1000
}

func main() {
	const size = 8 * 1024 * 1024
	const iterations = 64
	bytes := make([]byte, size)
	for index := range bytes {
		bytes[index] = byte(index)
	}
	var sum uint64
	warmChecksum := crc32.ChecksumIEEE(bytes)
	started := cpuNs()
	for range iterations {
		bytes[0]++
		checksum := crc32.NewIEEE()
		for offset := 0; offset < len(bytes); offset += 64 * 1024 {
			checksum.Write(bytes[offset : offset+64*1024])
		}
		sum += uint64(checksum.Sum32())
	}
	elapsed := cpuNs() - started
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"bytes": size, "iterations": iterations, "chunk_bytes": 65536,
		"cpu_ns": elapsed, "checksum_sum": sum,
		"warm_checksum": warmChecksum,
	})
}
