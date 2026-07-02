package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// ExtensionInfo describes one extension installed in a Zova database.
type ExtensionInfo struct {
	Name            string
	Version         string
	StoragePrefix   string
	ZovaABIMin      string
	Capabilities    string
	Required        bool
	InstalledAtUnix int64
	ManifestJSON    string
}

// InstallExtension installs one extension from the current process registry.
func (db *DB) InstallExtension(name string) error {
	cName, err := cString("extension name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_database_extension_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_database_extension_install(&request))
	})
}

// ListExtensions returns installed extension metadata sorted by name.
func (db *DB) ListExtensions() ([]ExtensionInfo, error) {
	list := newCExtensionList()
	defer freeCExtensionList(list)
	err := db.withLock(func() error {
		request := C.zova_database_extension_list_request{
			db:       db.ptr,
			out_list: list,
		}
		return statusFromDB(db, C.zova_database_extension_list(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyExtensionList(list), nil
}

// ExtensionInfo returns installed metadata for one extension.
func (db *DB) ExtensionInfo(name string) (ExtensionInfo, error) {
	cName, err := cString("extension name", name)
	if err != nil {
		return ExtensionInfo{}, err
	}
	defer freeCString(cName)

	info := newCExtensionInfo()
	defer freeCExtensionInfo(info)
	err = db.withLock(func() error {
		request := C.zova_database_extension_info_request{
			db:       db.ptr,
			name:     cName,
			out_info: info,
		}
		return statusFromDB(db, C.zova_database_extension_info(&request))
	})
	if err != nil {
		return ExtensionInfo{}, err
	}
	return copyExtensionInfo(info), nil
}

// CheckExtension runs one installed extension's health check.
func (db *DB) CheckExtension(name string) error {
	cName, err := cString("extension name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_database_extension_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_database_extension_check(&request))
	})
}

// CheckExtensions runs health checks for every installed extension.
func (db *DB) CheckExtensions() error {
	return db.withLock(func() error {
		request := C.zova_database_simple_request{db: db.ptr}
		return statusFromDB(db, C.zova_database_extension_check_all(&request))
	})
}

// DropExtension drops one installed extension and its private storage.
func (db *DB) DropExtension(name string) error {
	cName, err := cString("extension name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_database_extension_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_database_extension_drop(&request))
	})
}

func newCExtensionInfo() *C.zova_extension_info {
	return (*C.zova_extension_info)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_extension_info{}))))
}

func freeCExtensionInfo(info *C.zova_extension_info) {
	if info == nil {
		return
	}
	C.zova_extension_info_free(info)
	C.free(unsafe.Pointer(info))
}

func newCExtensionList() *C.zova_extension_list {
	return (*C.zova_extension_list)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_extension_list{}))))
}

func freeCExtensionList(list *C.zova_extension_list) {
	if list == nil {
		return
	}
	C.zova_extension_list_free(list)
	C.free(unsafe.Pointer(list))
}

func copyExtensionInfo(info *C.zova_extension_info) ExtensionInfo {
	return ExtensionInfo{
		Name:            cStringN(info.name, info.name_len),
		Version:         cStringN(info.version, info.version_len),
		StoragePrefix:   cStringN(info.storage_prefix, info.storage_prefix_len),
		ZovaABIMin:      cStringN(info.zova_abi_min, info.zova_abi_min_len),
		Capabilities:    cStringN(info.capabilities, info.capabilities_len),
		Required:        info.required != 0,
		InstalledAtUnix: int64(info.installed_at_unix),
		ManifestJSON:    cStringN(info.manifest_json, info.manifest_json_len),
	}
}

func copyExtensionList(list *C.zova_extension_list) []ExtensionInfo {
	if list.items == nil || list.len == 0 {
		return []ExtensionInfo{}
	}
	items := unsafe.Slice(list.items, int(list.len))
	out := make([]ExtensionInfo, len(items))
	for i := range items {
		out[i] = copyExtensionInfo(&items[i])
	}
	return out
}
