package main

// This is called "aaaa" to lexically sort first so that the timestamp initializer runs early

import "github.com/containers/podman/v5/pkg/timestamp"

var f = timestamp.Print
