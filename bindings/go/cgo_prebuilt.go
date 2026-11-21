//go:build zova_prebuilt && !zova_external

package zova

// Search paths for the headers and static libraries in native/. Released
// module versions carry native/ and build with these paths by default.
// In a checkout, scripts/prepare-go-module.py fills native/ and the
// zova_prebuilt build tag selects this file.
//
// The zova_external build tag drops both this file and cgo_checkout.go, so
// CGO_CFLAGS and CGO_LDFLAGS alone locate another zova.h and libzova_c.a.

/*
#cgo CFLAGS: -I${SRCDIR}/native/include
#cgo darwin,amd64 LDFLAGS: -L${SRCDIR}/native/darwin_amd64
#cgo darwin,arm64 LDFLAGS: -L${SRCDIR}/native/darwin_arm64
#cgo linux,amd64 LDFLAGS: -L${SRCDIR}/native/linux_amd64
#cgo linux,arm64 LDFLAGS: -L${SRCDIR}/native/linux_arm64
#cgo windows,amd64 LDFLAGS: -L${SRCDIR}/native/windows_amd64
*/
import "C"
