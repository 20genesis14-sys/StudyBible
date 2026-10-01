//! Хэш содержимого модуля — часть ключа кэша поиска.

use sha2::Sha256;
use sha2::digest::{Digest, Output};
use studybible_core::BookCode;
use studybible_core::text::{Chapter, Span};

pub fn new() -> Sha256 {
    Sha256::new()
}

/// Потоковое обновление: `book chapter block seq kind …`.
pub fn feed(h: &mut Sha256, book: BookCode, chapter: u16, ch: &Chapter) {
    for (i, b) in ch.blocks.iter().enumerate() {
        h.update(format!("{book} {chapter} {i} {}\u{0}", b.marker));
        for s in &b.spans {
            match s {
                Span::Verse(n) => h.update(format!("v{n}\u{0}")),
                Span::Text { text, style, attrs } => {
                    h.update(format!("t{style}\u{1}{attrs}\u{1}{text}\u{0}"));
                }
                Span::Note { kind, caller, text } => {
                    h.update(format!("n{kind}{caller}\u{1}{text}\u{0}"));
                }
            }
        }
    }
}

pub fn hex(h: Output<Sha256>) -> String {
    format!("{h:x}")
}
