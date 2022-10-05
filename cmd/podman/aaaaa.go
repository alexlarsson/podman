package main

// This is called "aaaa" to lexically sort first so that the timestamp initializer runs early

import "github.com/containers/podman/v4/pkg/timestamp"

var f = timestamp.Print
