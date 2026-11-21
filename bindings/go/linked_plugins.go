package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// LinkedPlugin is a plugin compiled into the process instead of loaded from a
// trusted bundle.
//
// Descriptor must point to a zova_plugin_descriptor_v1 (see zova_plugin.h) in
// C memory, usually a static descriptor in a cgo-linked C library. It must
// stay valid and unchanged while any database opened with it is in use.
type LinkedPlugin struct {
	Descriptor unsafe.Pointer
}

// CreateOptions controls settings fixed when a database file is created.
type CreateOptions struct {
	// PageSize is the SQLite page size in bytes. Zero keeps the default.
	PageSize uint32
}

// CreateWithOptions creates a new .zova database with creation options.
func CreateWithOptions(path string, options CreateOptions) (*DB, error) {
	cPath, err := cString("path", path)
	if err != nil {
		return nil, err
	}
	defer freeCString(cPath)
	out := (**C.zova_database)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(out))
	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_database_create_options_request{
		path:              cPath,
		page_size:         C.uint32_t(options.PageSize),
		out_db:            out,
		out_error_message: message,
	}
	return newOpenedDB(C.zova_database_create_with_options(&request), out, message)
}

// CreateWithPlugins creates a database with selected bundles and linked
// plugins available for installation.
func CreateWithPlugins(path string, extensions ExtensionOptions, plugins []LinkedPlugin) (*DB, error) {
	return openWithPlugins(path, openModeCreate, OpenOptions{}, extensions, plugins)
}

// OpenWithPlugins opens a database whose installed extensions are provided by
// selected bundles or linked plugins.
func OpenWithPlugins(path string, options OpenOptions, extensions ExtensionOptions, plugins []LinkedPlugin) (*DB, error) {
	return openWithPlugins(path, openModeOpen, options, extensions, plugins)
}

// OpenForExtensionUpgrade opens a maintenance connection for
// DB.ExtensionUpgrade and DB.ExtensionRebuild. It validates the core format
// but does not run installed extension hooks, so it is not a normal
// application open. Close it after the maintenance commits or rolls back.
func OpenForExtensionUpgrade(path string, options OpenOptions, extensions ExtensionOptions) (*DB, error) {
	return openWithPlugins(path, openModeExtensionUpgrade, options, extensions, nil)
}

// OpenForExtensionUpgradeWithPlugins is OpenForExtensionUpgrade with linked
// plugins.
func OpenForExtensionUpgradeWithPlugins(path string, options OpenOptions, extensions ExtensionOptions, plugins []LinkedPlugin) (*DB, error) {
	return openWithPlugins(path, openModeExtensionUpgrade, options, extensions, plugins)
}

// MigrateDatabaseWithPlugins is MigrateDatabaseWithExtensions that also
// verifies the destination with linked plugins.
func MigrateDatabaseWithPlugins(source, destination string, options MigrateOptions, extensions ExtensionOptions, plugins []LinkedPlugin) error {
	return MigrateDatabaseWithPluginsAndProgress(source, destination, options, extensions, plugins, nil)
}

// ExtensionUpgrade upgrades an installed extension to the version of the code
// available on a connection from OpenForExtensionUpgrade.
func (db *DB) ExtensionUpgrade(name string) error {
	return db.extensionCall(name, func(request *C.zova_database_extension_request) C.zova_status {
		return C.zova_database_extension_upgrade(request)
	})
}

// ExtensionRebuild rebuilds an installed extension's derived state through
// its recovery hook on a connection from OpenForExtensionUpgrade.
func (db *DB) ExtensionRebuild(name string) error {
	return db.extensionCall(name, func(request *C.zova_database_extension_request) C.zova_status {
		return C.zova_database_extension_rebuild(request)
	})
}

// VerifyExtensionBundle checks a native bundle's manifest, files, and trust.
// An empty trustStorePath selects the default trust store.
func VerifyExtensionBundle(bundlePath, trustStorePath string) error {
	return extensionBundleCall(bundlePath, trustStorePath, func(request *C.zova_extension_bundle_request) C.zova_status {
		return C.zova_extension_bundle_verify(request)
	})
}

// TrustExtensionBundle records a verified native bundle in the trust store.
// An empty trustStorePath selects the default trust store.
func TrustExtensionBundle(bundlePath, trustStorePath string) error {
	return extensionBundleCall(bundlePath, trustStorePath, func(request *C.zova_extension_bundle_request) C.zova_status {
		return C.zova_extension_bundle_trust(request)
	})
}

// UntrustExtensionBundle removes trust for a bundle path or extension name
// and reports whether an entry was removed. An empty trustStorePath selects
// the default trust store.
func UntrustExtensionBundle(identifier, trustStorePath string) (bool, error) {
	var arena cArena
	defer arena.free()
	cIdentifier, err := arena.str("extension identifier", identifier)
	if err != nil {
		return false, err
	}
	cTrust, err := arena.trustStore(trustStorePath)
	if err != nil {
		return false, err
	}
	removed := (*C.uint8_t)(arena.alloc(1, unsafe.Sizeof(C.uint8_t(0))))
	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_extension_bundle_untrust_request{
		identifier:        cIdentifier,
		trust_store_path:  cTrust,
		out_removed:       removed,
		out_error_message: message,
	}
	if status := C.zova_extension_bundle_untrust(&request); status != C.ZOVA_OK {
		return false, statusWithMessage(status, takeMessage(message))
	}
	return *removed != 0, nil
}

type openMode int

const (
	openModeCreate openMode = iota
	openModeOpen
	openModeExtensionUpgrade
)

func openWithPlugins(path string, mode openMode, options OpenOptions, extensions ExtensionOptions, plugins []LinkedPlugin) (*DB, error) {
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
	var arena cArena
	defer arena.free()
	cPlugins := arena.plugins(plugins)
	out := (**C.zova_database)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(out))
	message := newCMessage()
	defer freeCMessage(message)
	var flags C.uint32_t
	if options.ReadOnly {
		flags = C.ZOVA_OPEN_READ_ONLY
	}
	request := C.zova_database_open_plugins_request{
		path: cPath, flags: flags, busy_timeout_ms: C.uint32_t(options.BusyTimeoutMS),
		extension_bundle_paths: args.paths, extension_bundle_count: args.count,
		trust_store_path: args.trust, plugins: cPlugins, plugin_count: C.size_t(len(plugins)),
		out_db: out, out_error_message: message,
	}
	var status C.zova_status
	switch {
	case mode == openModeCreate:
		status = C.zova_database_create_with_plugins(&request)
	case mode == openModeOpen:
		status = C.zova_database_open_with_plugins(&request)
	case len(plugins) == 0:
		// The plain maintenance open takes the extensions request.
		plain := C.zova_database_open_extensions_request{
			path: cPath, flags: flags, busy_timeout_ms: C.uint32_t(options.BusyTimeoutMS),
			extension_bundle_paths: args.paths, extension_bundle_count: args.count,
			trust_store_path: args.trust, out_db: out, out_error_message: message,
		}
		status = C.zova_database_open_for_extension_upgrade(&plain)
	default:
		status = C.zova_database_open_for_extension_upgrade_with_plugins(&request)
	}
	return newOpenedDB(status, out, message)
}

func newOpenedDB(status C.zova_status, out **C.zova_database, message *C.zova_message) (*DB, error) {
	if status != C.ZOVA_OK {
		return nil, statusWithMessage(status, takeMessage(message))
	}
	if *out == nil {
		return nil, newError(StatusInvalidArgument, "Zova returned a nil database handle")
	}
	return &DB{
		ptr:        *out,
		statements: make(map[*Stmt]struct{}),
		writers:    make(map[*ObjectWriter]struct{}),
		readers:    make(map[*ObjectReader]struct{}),
		subs:       make(map[*Subscription]struct{}),
	}, nil
}

func (db *DB) extensionCall(name string, call func(*C.zova_database_extension_request) C.zova_status) error {
	cName, err := cString("extension name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)
	return db.withLock(func() error {
		request := C.zova_database_extension_request{db: db.ptr, name: cName}
		return statusFromDB(db, call(&request))
	})
}

func extensionBundleCall(bundlePath, trustStorePath string, call func(*C.zova_extension_bundle_request) C.zova_status) error {
	var arena cArena
	defer arena.free()
	cBundle, err := arena.str("bundle path", bundlePath)
	if err != nil {
		return err
	}
	cTrust, err := arena.trustStore(trustStorePath)
	if err != nil {
		return err
	}
	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_extension_bundle_request{
		bundle_path:       cBundle,
		trust_store_path:  cTrust,
		out_error_message: message,
	}
	return statusWithMessage(call(&request), takeMessage(message))
}

func (a *cArena) trustStore(path string) (*C.char, error) {
	if path == "" {
		return nil, nil
	}
	return a.str("trust store path", path)
}

func (a *cArena) plugins(plugins []LinkedPlugin) **C.struct_zova_plugin_descriptor_v1 {
	ptr := a.alloc(len(plugins), unsafe.Sizeof(uintptr(0)))
	if ptr == nil {
		return nil
	}
	slots := unsafe.Slice((**C.struct_zova_plugin_descriptor_v1)(ptr), len(plugins))
	for i, plugin := range plugins {
		slots[i] = (*C.struct_zova_plugin_descriptor_v1)(plugin.Descriptor)
	}
	return (**C.struct_zova_plugin_descriptor_v1)(ptr)
}
