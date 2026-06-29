package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// Notification is one in-memory same-handle app event.
type Notification struct {
	Channel       string
	Payload       string
	Sequence      uint64
	DroppedBefore uint64
}

// Subscription owns one notification queue for a channel.
type Subscription struct {
	db     *DB
	ptr    *C.zova_subscription
	closed bool
}

// Notify queues an explicit app notification.
func (db *DB) Notify(channel, payload string) error {
	cChannel, err := cString("notification channel", channel)
	if err != nil {
		return err
	}
	defer freeCString(cChannel)

	data, cleanup := cBytes([]byte(payload))
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_database_notify_request{
			db:          db.ptr,
			channel:     cChannel,
			payload:     data,
			payload_len: C.size_t(len(payload)),
		}
		return statusFromDB(db, C.zova_database_notify(&request))
	})
}

// Listen creates a queue-only subscription for a channel.
func (db *DB) Listen(channel string) (*Subscription, error) {
	cChannel, err := cString("notification channel", channel)
	if err != nil {
		return nil, err
	}
	defer freeCString(cChannel)

	outRaw := (**C.zova_subscription)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(outRaw))
	sub := &Subscription{db: db}
	err = db.withLock(func() error {
		request := C.zova_database_listen_request{
			db:               db.ptr,
			channel:          cChannel,
			out_subscription: outRaw,
		}
		if err := statusFromDB(db, C.zova_database_listen(&request)); err != nil {
			return err
		}
		if *outRaw == nil {
			return newError(StatusInvalidArgument, "Zova returned a nil subscription handle")
		}
		sub.ptr = *outRaw
		db.subs[sub] = struct{}{}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return sub, nil
}

// TryReceive returns the next notification, or nil when the queue is empty.
func (s *Subscription) TryReceive() (*Notification, error) {
	var out *C.zova_notification
	var has *C.uint8_t
	err := s.withLock(func(db *DB) error {
		out = (*C.zova_notification)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_notification{}))))
		if out == nil {
			return newError(StatusOutOfMemory, "could not allocate notification output")
		}
		has = (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
		if has == nil {
			return newError(StatusOutOfMemory, "could not allocate notification flag")
		}
		request := C.zova_subscription_try_receive_request{
			subscription:         s.ptr,
			out_notification:     out,
			out_has_notification: has,
		}
		return statusFromDB(db, C.zova_subscription_try_receive(&request))
	})
	if has != nil {
		defer C.free(unsafe.Pointer(has))
	}
	if out != nil {
		defer C.free(unsafe.Pointer(out))
		defer C.zova_notification_free(out)
	}
	if err != nil {
		return nil, err
	}
	if has == nil || *has == 0 {
		return nil, nil
	}
	return notificationFromC(out), nil
}

// Close closes the subscription.
func (s *Subscription) Close() error {
	return s.withLock(func(db *DB) error {
		status := C.zova_subscription_close(s.ptr)
		if err := statusFromDB(db, status); err != nil {
			return err
		}
		delete(db.subs, s)
		s.ptr = nil
		s.closed = true
		return nil
	})
}

func (s *Subscription) withLock(fn func(*DB) error) error {
	if s == nil || s.db == nil {
		return closedError("subscription")
	}
	db := s.db
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.closed || db.ptr == nil {
		return closedError("database")
	}
	if s.closed || s.ptr == nil {
		return closedError("subscription")
	}
	return fn(db)
}

func notificationFromC(raw *C.zova_notification) *Notification {
	return &Notification{
		Channel:       cStringWithLen(raw.channel, raw.channel_len),
		Payload:       cStringWithLen(raw.payload, raw.payload_len),
		Sequence:      uint64(raw.sequence),
		DroppedBefore: uint64(raw.dropped_before),
	}
}

func cStringWithLen(data *C.char, len C.size_t) string {
	if data == nil || len == 0 {
		return ""
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(data)), int(len))
	return string(bytes)
}
