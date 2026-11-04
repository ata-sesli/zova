use std::ops::ControlFlow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi::Status;
use napi_derive::napi;

/// One progress event, as delivered to JavaScript.
#[napi(object)]
pub struct NativeProgress {
    pub phase: String,
    pub member: Option<String>,
    pub done: f64,
    pub total: f64,
}

impl From<zova::Progress> for NativeProgress {
    fn from(progress: zova::Progress) -> Self {
        let phase = match progress.phase {
            zova::ProgressPhase::Copy => "copy",
            zova::ProgressPhase::Migrate => "migrate",
            zova::ProgressPhase::Verify => "verify",
            zova::ProgressPhase::Publish => "publish",
            _ => "unknown",
        };
        let member = progress.member.map(|member| {
            match member {
                zova::ProgressMember::Main => "main",
                zova::ProgressMember::ObjectStore => "object_store",
                zova::ProgressMember::VectorStore => "vector_store",
                zova::ProgressMember::GraphStore => "graph_store",
                _ => "unknown",
            }
            .to_owned()
        });
        Self {
            phase: phase.to_owned(),
            member,
            done: progress.done as f64,
            total: progress.total as f64,
        }
    }
}

/// Receives each event, then `null` once the operation has returned. The
/// worker never waits for JavaScript, so events arrive asynchronously and the
/// trailing `null` marks that every earlier event has been delivered.
pub type ProgressFunction =
    ThreadsafeFunction<Option<NativeProgress>, (), Option<NativeProgress>, Status, false>;

/// A cancellation flag shared between JavaScript and a worker-thread
/// operation. The operation checks it at each progress event.
#[napi]
pub struct NativeCancelToken {
    cancelled: Arc<AtomicBool>,
}

#[napi]
impl NativeCancelToken {
    #[napi(constructor)]
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    #[napi]
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
}

/// Progress reporting and cancellation for one asynchronous task.
pub(crate) struct TaskProgress {
    function: Option<ProgressFunction>,
    cancelled: Option<Arc<AtomicBool>>,
}

impl TaskProgress {
    pub(crate) fn new(
        function: Option<ProgressFunction>,
        token: Option<&NativeCancelToken>,
    ) -> Self {
        Self {
            function,
            cancelled: token.map(|token| token.cancelled.clone()),
        }
    }

    pub(crate) fn is_active(&self) -> bool {
        self.function.is_some() || self.cancelled.is_some()
    }

    pub(crate) fn report(&self, progress: zova::Progress) -> ControlFlow<()> {
        if let Some(cancelled) = &self.cancelled {
            if cancelled.load(Ordering::SeqCst) {
                return ControlFlow::Break(());
            }
        }
        if let Some(function) = &self.function {
            function.call(
                Some(progress.into()),
                ThreadsafeFunctionCallMode::NonBlocking,
            );
        }
        ControlFlow::Continue(())
    }

    /// Queue the end marker behind every delivered event.
    pub(crate) fn finish(&self) {
        if let Some(function) = &self.function {
            function.call(None, ThreadsafeFunctionCallMode::NonBlocking);
        }
    }
}
