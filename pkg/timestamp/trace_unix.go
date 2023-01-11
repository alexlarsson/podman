//go:build !windows

package timestamp

import "syscall"

func traceMarker(s string) {
	_ = syscall.Access(s, 0)
}
