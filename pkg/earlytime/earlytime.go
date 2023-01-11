// Package earlytime records a startup baseline with minimal initialization dependencies.
package earlytime

import "time"

// Start is captured before packages that import earlytime are initialized.
var Start = time.Now()
