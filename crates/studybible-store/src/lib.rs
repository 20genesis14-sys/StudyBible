//! Хранилище StudyBible: модуль на SQLite v1 и его безопасное открытие (ADR 0003).
//!
//! Схема: `meta` (ключ–значение), `books` (коды в порядке модуля),
//! `blocks`/`spans` (поток чтения), `verses` (плоский текст стихов для кэша и вывода).
//! FTS-индекса в модуле нет — он в локальном кэше (`search.rs`).

mod hash;
pub mod module;

pub use module::{Meta, Module, ModuleError, ModuleWriter};
