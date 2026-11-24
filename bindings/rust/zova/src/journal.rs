//! Journal mode and WAL checkpoint calls over a whole database set.

use crate::progress::ProgressMember;

/// SQLite journal mode of one member file.
///
/// [`crate::Database::set_journal_mode`] accepts `Delete`, `Truncate`,
/// `Persist` and `Wal`. `Memory` is reported by in-memory databases; `Off` is
/// reported only when a file was switched outside Zova.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum JournalMode {
    Delete,
    Truncate,
    Persist,
    Memory,
    Wal,
    Off,
}

impl JournalMode {
    /// Stable machine-readable name shared by every Zova binding.
    pub fn name(self) -> &'static str {
        match self {
            Self::Delete => "delete",
            Self::Truncate => "truncate",
            Self::Persist => "persist",
            Self::Memory => "memory",
            Self::Wal => "wal",
            Self::Off => "off",
        }
    }

    pub(crate) fn code(self) -> u32 {
        match self {
            Self::Delete => zova_sys::ZOVA_JOURNAL_MODE_DELETE,
            Self::Truncate => zova_sys::ZOVA_JOURNAL_MODE_TRUNCATE,
            Self::Persist => zova_sys::ZOVA_JOURNAL_MODE_PERSIST,
            Self::Memory => zova_sys::ZOVA_JOURNAL_MODE_MEMORY,
            Self::Wal => zova_sys::ZOVA_JOURNAL_MODE_WAL,
            Self::Off => zova_sys::ZOVA_JOURNAL_MODE_OFF,
        }
    }

    fn from_code(code: u32) -> Option<Self> {
        match code {
            zova_sys::ZOVA_JOURNAL_MODE_DELETE => Some(Self::Delete),
            zova_sys::ZOVA_JOURNAL_MODE_TRUNCATE => Some(Self::Truncate),
            zova_sys::ZOVA_JOURNAL_MODE_PERSIST => Some(Self::Persist),
            zova_sys::ZOVA_JOURNAL_MODE_MEMORY => Some(Self::Memory),
            zova_sys::ZOVA_JOURNAL_MODE_WAL => Some(Self::Wal),
            zova_sys::ZOVA_JOURNAL_MODE_OFF => Some(Self::Off),
            _ => None,
        }
    }
}

/// SQLite WAL checkpoint mode for [`crate::Database::checkpoint`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[non_exhaustive]
pub enum CheckpointMode {
    /// Copy as many frames as possible without waiting for readers or writers.
    #[default]
    Passive,
    /// Wait for writers, then copy every frame unless a reader still needs one.
    Full,
    /// As `Full`, then wait for readers so the next writer restarts the WAL.
    Restart,
    /// As `Restart`, then truncate the WAL file to zero bytes.
    Truncate,
}

impl CheckpointMode {
    pub(crate) fn code(self) -> u32 {
        match self {
            Self::Passive => zova_sys::ZOVA_CHECKPOINT_PASSIVE,
            Self::Full => zova_sys::ZOVA_CHECKPOINT_FULL,
            Self::Restart => zova_sys::ZOVA_CHECKPOINT_RESTART,
            Self::Truncate => zova_sys::ZOVA_CHECKPOINT_TRUNCATE,
        }
    }
}

/// Journal mode of one member of a database set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JournalModeMember {
    pub member: ProgressMember,
    pub journal_mode: JournalMode,
}

/// What [`crate::Database::checkpoint`] did for one member file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointedMember {
    pub member: ProgressMember,
    pub journal_mode: JournalMode,
    /// The checkpoint could not finish because another handle held a lock.
    pub busy: bool,
    /// Frames in the WAL file after the checkpoint; 0 when not in WAL mode.
    pub wal_frames: u64,
    /// Frames now copied into the database file; 0 when not in WAL mode.
    pub checkpointed_frames: u64,
}

fn member_from_code(code: u32) -> Option<ProgressMember> {
    match code {
        zova_sys::ZOVA_PROGRESS_MEMBER_MAIN => Some(ProgressMember::Main),
        zova_sys::ZOVA_PROGRESS_MEMBER_OBJECT_STORE => Some(ProgressMember::ObjectStore),
        zova_sys::ZOVA_PROGRESS_MEMBER_VECTOR_STORE => Some(ProgressMember::VectorStore),
        zova_sys::ZOVA_PROGRESS_MEMBER_GRAPH_STORE => Some(ProgressMember::GraphStore),
        _ => None,
    }
}

pub(crate) fn journal_mode_members(
    raw: &zova_sys::zova_journal_mode_report,
) -> Vec<JournalModeMember> {
    let count = raw.member_count.min(raw.members.len());
    raw.members[..count]
        .iter()
        .filter_map(|entry| {
            Some(JournalModeMember {
                member: member_from_code(entry.member)?,
                journal_mode: JournalMode::from_code(entry.journal_mode)?,
            })
        })
        .collect()
}

pub(crate) fn checkpointed_members(
    raw: &zova_sys::zova_checkpoint_result,
) -> Vec<CheckpointedMember> {
    let count = raw.member_count.min(raw.members.len());
    raw.members[..count]
        .iter()
        .filter_map(|entry| {
            Some(CheckpointedMember {
                member: member_from_code(entry.member)?,
                journal_mode: JournalMode::from_code(entry.journal_mode)?,
                busy: entry.busy != 0,
                wal_frames: entry.wal_frames,
                checkpointed_frames: entry.checkpointed_frames,
            })
        })
        .collect()
}
