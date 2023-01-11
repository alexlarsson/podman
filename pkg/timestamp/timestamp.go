package timestamp

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"go.podman.io/podman/v6/pkg/earlytime"
)

var (
	startTime = earlytime.Start
	lastTime  = startTime
	logPrefix = "## "
	indent    = 0
	enabled   = false
	logMutex  sync.Mutex
)

func init() {
	enabled = os.Getenv("PODMAN_TIMESTAMPS") != ""
	for _, arg := range os.Args {
		if arg == "--timestamps" {
			enabled = true
		}
	}
}

func Print(str string) {
	if !enabled {
		return
	}
	printTimestamp(str, time.Time{})
}

// Start logs the start of an operation and returns a function that logs its
// completion and duration. Use defer Start("operation")() to time a function.
func Start(name string) func() {
	if !enabled {
		return func() {}
	}
	started := printTimestamp(">"+name, time.Time{})
	return func() {
		printTimestamp("<"+name, started)
	}
}

func printTimestamp(str string, started time.Time) time.Time {
	now, _ := printTimestampTo(os.Stdout, str, started)
	return now
}

func printTimestampTo(out io.Writer, str string, started time.Time) (time.Time, error) {
	logMutex.Lock()
	defer logMutex.Unlock()

	now := time.Now()
	timestamp := now.Sub(startTime)
	if len(str) > 0 && str[0] == '<' {
		indent -= 1
	}
	if !started.IsZero() {
		str += fmt.Sprintf(" (duration: %.2f ms)", now.Sub(started).Seconds()*1000)
	}
	s := fmt.Sprintf("%s%5.1f %6.2f: %*s%s", logPrefix, timestamp.Seconds()*1000, now.Sub(lastTime).Seconds()*1000, indent*2, "", str)
	if len(str) > 0 && str[0] == '>' {
		indent += 1
	}
	lastTime = now
	traceMarker(s)
	_, err := fmt.Fprintln(out, s)
	return now, err
}
