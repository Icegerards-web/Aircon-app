//go:build tools

package wgbridge

// Keeps golang.org/x/mobile in go.mod: "gomobile bind" needs it.
import _ "golang.org/x/mobile/bind"
