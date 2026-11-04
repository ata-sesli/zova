//! Progress reporting for backup, compact, and migrate.

use std::any::Any;
use std::ops::ControlFlow;
use std::os::raw::c_void;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};

use crate::error::Result;

/// The stage an operation is in. The phase fixes the unit of
/// [`Progress::done`] and [`Progress::total`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ProgressPhase {
    /// Copying one member file. Units: SQLite pages of the source member.
    Copy,
    /// Migrating one staged member to the current format. Units: format steps.
    Migrate,
    /// Checking the copied set. Units: stored objects, chunks, vectors, and KV
    /// entries.
    Verify,
    /// Publishing migrated member files. Units: files.
    Publish,
}

/// The member file a copy or migrate event refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ProgressMember {
    Main,
    ObjectStore,
    VectorStore,
    GraphStore,
}

/// One progress event. Events for one phase and member keep `total` fixed,
/// never decrease `done`, and end with `done == total`. `member` is `None`
/// for [`ProgressPhase::Verify`] and [`ProgressPhase::Publish`], which cover
/// the whole set.
///
/// Zova forwards the first event of each phase and member, whole-percent
/// changes, and the event that completes the group.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub phase: ProgressPhase,
    pub member: Option<ProgressMember>,
    pub done: u64,
    pub total: u64,
}

impl Progress {
    fn from_raw(raw: &zova_sys::zova_progress) -> Option<Self> {
        let phase = match raw.phase {
            zova_sys::ZOVA_PROGRESS_COPY => ProgressPhase::Copy,
            zova_sys::ZOVA_PROGRESS_MIGRATE => ProgressPhase::Migrate,
            zova_sys::ZOVA_PROGRESS_VERIFY => ProgressPhase::Verify,
            zova_sys::ZOVA_PROGRESS_PUBLISH => ProgressPhase::Publish,
            _ => return None,
        };
        let member = match raw.member {
            zova_sys::ZOVA_PROGRESS_MEMBER_NONE => None,
            zova_sys::ZOVA_PROGRESS_MEMBER_MAIN => Some(ProgressMember::Main),
            zova_sys::ZOVA_PROGRESS_MEMBER_OBJECT_STORE => Some(ProgressMember::ObjectStore),
            zova_sys::ZOVA_PROGRESS_MEMBER_VECTOR_STORE => Some(ProgressMember::VectorStore),
            zova_sys::ZOVA_PROGRESS_MEMBER_GRAPH_STORE => Some(ProgressMember::GraphStore),
            _ => return None,
        };
        Some(Self {
            phase,
            member,
            done: raw.done,
            total: raw.total,
        })
    }
}

/// Owns the caller's closure for one synchronous C call.
///
/// Returning [`ControlFlow::Break`] cancels the operation, which then fails
/// with [`crate::Status::Interrupted`]. A panic in the closure also cancels;
/// it is caught at the FFI boundary and resumed once the C call returns.
pub(crate) struct ProgressBridge<'a> {
    callback: &'a mut dyn FnMut(Progress) -> ControlFlow<()>,
    panic: Option<Box<dyn Any + Send>>,
}

impl<'a> ProgressBridge<'a> {
    pub(crate) fn new(callback: &'a mut dyn FnMut(Progress) -> ControlFlow<()>) -> Self {
        Self {
            callback,
            panic: None,
        }
    }

    pub(crate) fn callback(&self) -> zova_sys::zova_progress_fn {
        Some(trampoline)
    }

    /// The `progress_user_data` pointer; valid while `self` is not moved.
    pub(crate) fn user_data(&mut self) -> *mut c_void {
        (self as *mut Self).cast()
    }

    pub(crate) fn finish<T>(self, result: Result<T>) -> Result<T> {
        if let Some(payload) = self.panic {
            resume_unwind(payload);
        }
        result
    }
}

unsafe extern "C" fn trampoline(
    user_data: *mut c_void,
    progress: *const zova_sys::zova_progress,
) -> i32 {
    // SAFETY: user_data is the ProgressBridge passed with this callback, and
    // it outlives the synchronous call that invokes the trampoline.
    let bridge = unsafe { &mut *user_data.cast::<ProgressBridge<'_>>() };
    if bridge.panic.is_some() {
        return 1;
    }
    // SAFETY: Zova passes a valid event pointer for the duration of the call.
    let Some(progress) = (unsafe { progress.as_ref() }).and_then(Progress::from_raw) else {
        return 0;
    };
    match catch_unwind(AssertUnwindSafe(|| (bridge.callback)(progress))) {
        Ok(ControlFlow::Continue(())) => 0,
        Ok(ControlFlow::Break(())) => 1,
        Err(payload) => {
            bridge.panic = Some(payload);
            1
        }
    }
}
