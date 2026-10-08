//! Хранилище StudyBible: модуль на SQLite v1 и его безопасное открытие (ADR 0003).
//!
//! Схема: `meta` (ключ–значение), `books` (коды в порядке модуля),
//! `blocks`/`spans` (поток чтения), `verses` (плоский текст стихов для кэша и вывода).
//! FTS-индекс — локальный кэш (`search.rs`); у модуля с таблицей `fts`
//! (ADR 0016) поиск идёт прямо по ней.

mod hash;
pub mod module;
pub mod sbz;
pub mod search;
pub mod userdata;

pub use module::{
    Alignment, Mark, Meta, Module, ModuleError, ModuleWriter, Reading, Token, Variant,
};
pub use search::{Hit, SearchIndex};
pub use userdata::{
    Anchor, Bind, Entry, ImportStats, Kind, RelinkStats, UserData, UserError, canon_range,
};
