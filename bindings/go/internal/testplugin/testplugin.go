// Package testplugin provides a statically linked plugin descriptor for the
// zova package tests. cgo cannot be used in _test.go files.
package testplugin

/*
#cgo CFLAGS: -I../../../../include
#include <stddef.h>
#include "zova_plugin.h"

static const zova_plugin_descriptor_v1 linked_test = {
	sizeof(zova_plugin_descriptor_v1),
	ZOVA_PLUGIN_ABI_V1,
	0,
	"linked_test",
	"1.0.0",
	"_zova_ext_linked_test_",
	"1.0.0",
	NULL,
	NULL,
	NULL,
	NULL,
	NULL,
};

static const void *linked_test_descriptor(void) {
	return &linked_test;
}
*/
import "C"

import "unsafe"

// Descriptor returns a static descriptor named linked_test, version 1.0.0,
// with no hooks.
func Descriptor() unsafe.Pointer {
	return unsafe.Pointer(C.linked_test_descriptor())
}
