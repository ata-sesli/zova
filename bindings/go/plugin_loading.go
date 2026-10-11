package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// ExtensionOptions selects previously trusted native bundles. It never grants
// trust or loads executable paths from database metadata. Bundles and their
// dependencies must match the host OS/architecture.
type ExtensionOptions struct {
	BundlePaths []string
	// Empty selects Zova's existing default trust store.
	TrustStorePath string
}

// CreateWithExtensions creates a database with selected native bundles.
func CreateWithExtensions(path string, extensions ExtensionOptions) (*DB, error) {
	return openWithExtensions(path, true, OpenOptions{}, extensions)
}

// OpenWithExtensions opens with selected native bundles and ordinary options.
func OpenWithExtensions(path string, options OpenOptions, extensions ExtensionOptions) (*DB, error) {
	return openWithExtensions(path, false, options, extensions)
}

func openWithExtensions(path string, create bool, options OpenOptions, extensions ExtensionOptions) (*DB, error) {
	cPath, err := cString("path", path)
	if err != nil {
		return nil, err
	}
	defer freeCString(cPath)
	var trust *C.char
	if extensions.TrustStorePath != "" {
		trust, err = cString("trust store path", extensions.TrustStorePath)
		if err != nil {
			return nil, err
		}
		defer freeCString(trust)
	}
	var paths **C.char
	if len(extensions.BundlePaths) != 0 {
		paths = (**C.char)(C.calloc(C.size_t(len(extensions.BundlePaths)), C.size_t(unsafe.Sizeof(uintptr(0)))))
		if paths == nil {
			return nil, newError(StatusOutOfMemory, "cannot allocate bundle paths")
		}
		defer C.free(unsafe.Pointer(paths))
		slots := unsafe.Slice(paths, len(extensions.BundlePaths))
		for i, path := range extensions.BundlePaths {
			value, err := cString("bundle path", path)
			if err != nil {
				return nil, err
			}
			defer freeCString(value)
			slots[i] = value
		}
	}
	out := (**C.zova_database)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	if out == nil {
		return nil, newError(StatusOutOfMemory, "cannot allocate database output")
	}
	defer C.free(unsafe.Pointer(out))
	message := newCMessage()
	defer freeCMessage(message)
	var flags C.uint32_t
	if options.ReadOnly {
		flags = C.ZOVA_OPEN_READ_ONLY
	}
	req := C.zova_database_open_extensions_request{
		path: cPath, flags: flags, busy_timeout_ms: C.uint32_t(options.BusyTimeoutMS),
		extension_bundle_paths: paths, extension_bundle_count: C.size_t(len(extensions.BundlePaths)),
		trust_store_path: trust, out_db: out, out_error_message: message,
	}
	var status C.zova_status
	if create {
		status = C.zova_database_create_with_extensions(&req)
	} else {
		status = C.zova_database_open_with_extensions(&req)
	}
	if status != C.ZOVA_OK {
		return nil, statusWithMessage(status, takeMessage(message))
	}
	if *out == nil {
		return nil, newError(StatusInvalidArgument, "Zova returned a nil database handle")
	}
	return &DB{ptr: *out, statements: make(map[*Stmt]struct{}), writers: make(map[*ObjectWriter]struct{}), readers: make(map[*ObjectReader]struct{}), subs: make(map[*Subscription]struct{})}, nil
}
