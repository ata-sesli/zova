use crate::database::{cstring, db_status, DatabaseInner};
use crate::error::{Error, Result};
use std::marker::PhantomData;
use std::ptr::{self, NonNull};
use std::rc::Rc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notification {
    pub channel: String,
    pub payload: String,
    pub sequence: u64,
    pub dropped_before: u64,
}

pub struct Subscription {
    raw: Option<NonNull<zova_sys::zova_subscription>>,
    db: *mut zova_sys::zova_database,
    _database: Rc<DatabaseInner>,
    _not_send_sync: PhantomData<Rc<()>>,
}

impl Subscription {
    pub(crate) fn new(
        raw: NonNull<zova_sys::zova_subscription>,
        database: Rc<DatabaseInner>,
    ) -> Self {
        let db = database.raw_ptr();
        Self {
            raw: Some(raw),
            db,
            _database: database,
            _not_send_sync: PhantomData,
        }
    }

    pub fn try_receive(&mut self) -> Result<Option<Notification>> {
        let raw = self
            .raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_MISUSE, None))?;
        let mut notification = empty_notification();
        let mut has_notification = 0;
        let request = zova_sys::zova_subscription_try_receive_request {
            subscription: raw.as_ptr(),
            out_notification: &mut notification,
            out_has_notification: &mut has_notification,
        };
        db_status(self.db, unsafe {
            zova_sys::zova_subscription_try_receive(&request)
        })?;
        if has_notification == 0 {
            return Ok(None);
        }
        Ok(Some(take_notification(&mut notification)?))
    }

    pub fn close(&mut self) -> Result<()> {
        if let Some(raw) = self.raw {
            db_status(self.db, unsafe {
                zova_sys::zova_subscription_close(raw.as_ptr())
            })?;
            self.raw = None;
        }
        Ok(())
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe {
                let _ = zova_sys::zova_subscription_close(raw.as_ptr());
            }
        }
    }
}

pub(crate) fn empty_notification() -> zova_sys::zova_notification {
    zova_sys::zova_notification {
        channel: ptr::null_mut(),
        channel_len: 0,
        payload: ptr::null_mut(),
        payload_len: 0,
        sequence: 0,
        dropped_before: 0,
    }
}

pub(crate) fn take_notification(
    notification: &mut zova_sys::zova_notification,
) -> Result<Notification> {
    let channel = string_from_parts(notification.channel, notification.channel_len)?;
    let payload = string_from_parts(notification.payload, notification.payload_len)?;
    let out = Notification {
        channel,
        payload,
        sequence: notification.sequence,
        dropped_before: notification.dropped_before,
    };
    unsafe {
        zova_sys::zova_notification_free(notification);
    }
    Ok(out)
}

pub(crate) fn listen_raw(
    db: *mut zova_sys::zova_database,
    channel: &str,
) -> Result<NonNull<zova_sys::zova_subscription>> {
    let channel = cstring(channel, "notification channel")?;
    let mut subscription = ptr::null_mut();
    let request = zova_sys::zova_database_listen_request {
        db,
        channel: channel.as_ptr(),
        out_subscription: &mut subscription,
    };
    db_status(db, unsafe { zova_sys::zova_database_listen(&request) })?;
    NonNull::new(subscription).ok_or_else(|| Error::from_status(zova_sys::ZOVA_MISUSE, None))
}

pub(crate) fn notify_raw(
    db: *mut zova_sys::zova_database,
    channel: &str,
    payload: &str,
) -> Result<()> {
    let channel = cstring(channel, "notification channel")?;
    let request = zova_sys::zova_database_notify_request {
        db,
        channel: channel.as_ptr(),
        payload: payload.as_bytes().as_ptr(),
        payload_len: payload.len(),
    };
    db_status(db, unsafe { zova_sys::zova_database_notify(&request) })
}

fn string_from_parts(ptr: *mut std::os::raw::c_char, len: usize) -> Result<String> {
    if ptr.is_null() {
        return Ok(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len) };
    String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text)
}
