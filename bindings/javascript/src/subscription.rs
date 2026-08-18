use std::sync::{Arc, Mutex};

use napi::bindgen_prelude::{AsyncTask, BigInt};
use napi::{Env, Result, Task};
use napi_derive::napi;

use crate::database::DatabaseState;
use crate::error::{misuse_error, zova_error};

/// Thread-safe notification subscription handle shared with async tasks.
///
/// `zova::SharedSubscription` is `Send` but not `Clone`; `try_receive` takes
/// `&mut self`. The internal mutex lets the synchronous `try_receive` and the
/// worker-thread async receive serialize access to the same subscription, while
/// the owning `Arc` keeps the native handle alive until both are done.
#[derive(Clone)]
pub struct SharedSubscriptionHandle {
    inner: Arc<Mutex<Option<zova::SharedSubscription>>>,
}

impl SharedSubscriptionHandle {
    fn new(subscription: zova::SharedSubscription) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Some(subscription))),
        }
    }

    pub(crate) fn try_receive(&self) -> Result<Option<zova::Notification>> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_mut()
            .ok_or_else(|| misuse_error("subscription is closed"))?
            .try_receive()
            .map_err(zova_error)
    }

    fn close(&self) {
        let mut guard = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if guard.is_some() {
            let _ = guard
                .as_mut()
                .expect("just checked")
                .close()
                .map_err(zova_error);
            *guard = None;
        }
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_none()
    }
}

#[napi(js_name = "NativeSubscription")]
pub struct NativeSubscription {
    subscription: SharedSubscriptionHandle,
    database: Arc<DatabaseState>,
}

impl NativeSubscription {
    pub(crate) fn new(
        subscription: zova::SharedSubscription,
        database: Arc<DatabaseState>,
    ) -> Self {
        Self {
            subscription: SharedSubscriptionHandle::new(subscription),
            database,
        }
    }

    fn close_inner(&self) {
        let was_open = !self.subscription.is_closed();
        self.subscription.close();
        if was_open {
            self.database.child_closed();
        }
    }
}

#[napi]
impl NativeSubscription {
    #[napi]
    pub fn close(&self) {
        self.close_inner();
    }

    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.subscription.is_closed()
    }

    #[napi]
    pub fn try_receive(&self) -> Result<Option<NativeNotification>> {
        let received = self.subscription.try_receive()?;
        Ok(received.map(|notification| NativeNotification {
            channel: notification.channel,
            payload: notification.payload,
            sequence: BigInt::from(notification.sequence),
            dropped_before: BigInt::from(notification.dropped_before),
        }))
    }

    #[napi(ts_return_type = "Promise<NativeNotification | null>")]
    pub fn async_try_receive(&self) -> AsyncTask<SubscriptionReceiveTask> {
        AsyncTask::new(SubscriptionReceiveTask {
            subscription: self.subscription.clone(),
        })
    }
}

impl Drop for NativeSubscription {
    fn drop(&mut self) {
        self.close_inner();
    }
}

pub struct SubscriptionReceiveTask {
    subscription: SharedSubscriptionHandle,
}

impl Task for SubscriptionReceiveTask {
    type Output = Option<NativeNotification>;
    type JsValue = Option<NativeNotification>;

    fn compute(&mut self) -> Result<Self::Output> {
        let received = self.subscription.try_receive()?;
        Ok(received.map(|notification| NativeNotification {
            channel: notification.channel,
            payload: notification.payload,
            sequence: BigInt::from(notification.sequence),
            dropped_before: BigInt::from(notification.dropped_before),
        }))
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}

#[napi(object)]
pub struct NativeNotification {
    pub channel: String,
    pub payload: String,
    pub sequence: BigInt,
    pub dropped_before: BigInt,
}
