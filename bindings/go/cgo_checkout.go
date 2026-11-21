//go:build !zova_prebuilt && !zova_external

package zova

// Search paths for a source checkout after `zig build c-abi`. Released module
// versions drop this file and build with cgo_prebuilt.go instead; see
// scripts/prepare-go-module.py.

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../zig-out/lib
*/
import "C"
