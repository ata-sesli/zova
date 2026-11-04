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
	args, err := newExtensionCArgs(extensions)
	if err != nil {
		return nil, err
	}
	defer args.free()
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
		extension_bundle_paths: args.paths, extension_bundle_count: args.count,
		trust_store_path: args.trust, out_db: out, out_error_message: message,
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

// MigrateDatabaseWithExtensions is MigrateDatabase with selected native
// bundles. Migration verifies the destination with every installed extension,
// so a database with a non-bundled extension installed needs that extension's
// bundle here. Bundles go through the same trust checks as OpenWithExtensions;
// empty options behave exactly like MigrateDatabase, and any failure
// publishes nothing.
func MigrateDatabaseWithExtensions(source, destination string, options MigrateOptions, extensions ExtensionOptions) error {
	cSource, err := cString("source path", source)
	if err != nil {
		return err
	}
	defer freeCString(cSource)
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)
	args, err := newExtensionCArgs(extensions)
	if err != nil {
		return err
	}
	defer args.free()
	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_database_migrate_extensions_request{
		source_path:            cSource,
		destination_path:       cDestination,
		flags:                  migrateFlags(options),
		extension_bundle_paths: args.paths,
		extension_bundle_count: args.count,
		trust_store_path:       args.trust,
		out_error_message:      message,
	}
	status := C.zova_database_migrate_with_extensions(&request)
	return statusWithMessage(status, takeMessage(message))
}

// extensionCArgs owns the C strings of one synchronous extension-selecting
// request until free is called.
type extensionCArgs struct {
	paths **C.char
	count C.size_t
	trust *C.char
	owned []*C.char
}

func newExtensionCArgs(extensions ExtensionOptions) (args extensionCArgs, err error) {
	defer func() {
		if err != nil {
			args.free()
		}
	}()
	if extensions.TrustStorePath != "" {
		if args.trust, err = cString("trust store path", extensions.TrustStorePath); err != nil {
			return args, err
		}
	}
	if len(extensions.BundlePaths) == 0 {
		return args, nil
	}
	args.paths = (**C.char)(C.calloc(C.size_t(len(extensions.BundlePaths)), C.size_t(unsafe.Sizeof(uintptr(0)))))
	if args.paths == nil {
		return args, newError(StatusOutOfMemory, "cannot allocate bundle paths")
	}
	slots := unsafe.Slice(args.paths, len(extensions.BundlePaths))
	for i, path := range extensions.BundlePaths {
		value, err := cString("bundle path", path)
		if err != nil {
			return args, err
		}
		args.owned = append(args.owned, value)
		slots[i] = value
	}
	args.count = C.size_t(len(extensions.BundlePaths))
	return args, nil
}

func (args *extensionCArgs) free() {
	for _, value := range args.owned {
		freeCString(value)
	}
	args.owned = nil
	if args.paths != nil {
		C.free(unsafe.Pointer(args.paths))
		args.paths = nil
	}
	if args.trust != nil {
		freeCString(args.trust)
		args.trust = nil
	}
	args.count = 0
}
