// Optional local diagnostics; the normal baseline build includes main.go only.
package main

import (
	"encoding/json"
	"os"
	"os/signal"
	"runtime"
	"runtime/metrics"
	"runtime/pprof"
	"syscall"
)

func init() {
	prefix := os.Getenv("ZHTPS_GO_PROFILE")
	if prefix == "" {
		return
	}
	file, err := os.Create(prefix + ".cpu.pprof")
	if err != nil {
		panic(err)
	}
	if err := pprof.StartCPUProfile(file); err != nil {
		panic(err)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	go func() {
		<-signals
		pprof.StopCPUProfile()
		file.Close()
		var memory runtime.MemStats
		runtime.ReadMemStats(&memory)
		var samples []metrics.Sample
		for _, description := range metrics.All() {
			samples = append(samples, metrics.Sample{Name: description.Name})
		}
		metrics.Read(samples)
		values := make(map[string]any)
		for _, sample := range samples {
			switch sample.Value.Kind() {
			case metrics.KindUint64:
				values[sample.Name] = sample.Value.Uint64()
			case metrics.KindFloat64:
				values[sample.Name] = sample.Value.Float64()
			}
		}
		report, err := os.Create(prefix + ".runtime.json")
		if err != nil {
			panic(err)
		}
		json.NewEncoder(report).Encode(map[string]any{"memory": memory, "metrics": values})
		report.Close()
		os.Exit(0)
	}()
}
