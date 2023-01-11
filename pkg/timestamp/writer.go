package timestamp

import (
	"bytes"
	"fmt"
	"io"
	"sync"
	"time"
)

// LogWriter timestamps helper log records when tracing is enabled. Indented
// continuation lines retain their original formatting. The returned function
// flushes a partial line without closing out. Times reflect receipt by Podman.
func LogWriter(name string, out io.Writer) (io.Writer, func()) {
	if !enabled {
		return out, func() {}
	}
	w := &logWriter{name: name, out: out}
	return w, func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		if len(w.pending) > 0 {
			_ = w.writeLine(w.pending)
			w.pending = nil
		}
	}
}

type logWriter struct {
	mu      sync.Mutex
	name    string
	out     io.Writer
	pending []byte
}

func (w *logWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := 0
	for len(p) > 0 {
		end := bytes.IndexByte(p, '\n')
		if end < 0 {
			w.pending = append(w.pending, p...)
			return n + len(p), nil
		}
		w.pending = append(w.pending, p[:end]...)
		err := w.writeLine(w.pending)
		w.pending = w.pending[:0]
		if err != nil {
			return n, err
		}
		n += end + 1
		p = p[end+1:]
	}
	return n, nil
}

func (w *logWriter) writeLine(line []byte) error {
	if len(line) == 0 || line[0] == ' ' || line[0] == '\t' {
		_, err := fmt.Fprintln(w.out, string(line))
		return err
	}
	_, err := printTimestampTo(w.out, w.name+": "+string(line), time.Time{})
	return err
}
