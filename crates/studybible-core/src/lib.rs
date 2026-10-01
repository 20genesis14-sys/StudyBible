//! Ядро StudyBible.
//!
//! Домен и порты («порты и адаптеры»). Ядро не обращается к файловой системе
//! напрямую и не блокирует главный поток: доступ к хранилищу, речи и прочему
//! идёт через порты, которые реализуют адаптеры платформ.

pub mod book;
pub mod normalize;
pub mod reference;
pub mod speech;
pub mod text;
pub mod versification;

pub use book::{Book, BookCatalog, BookCode, BookOrder, NameProfile};
pub use reference::{ParseError, Point, Reference};
pub use versification::{VerseKey, Versification};
