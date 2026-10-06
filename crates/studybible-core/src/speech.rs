//! Порт «Речь» и подготовка текста к озвучиванию (ADR 0010).
//!
//! Ядро определяет порт и готовит текст; синтезатор — адаптер платформы
//! (в консоли — `tts`, в интерфейсах — системные синтезаторы ОС).
//! Читаем только русский и английский; древние языки не озвучиваем.

use std::fmt;

use crate::text::{Chapter, collapse_spaces};

#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "речь: {}", self.0)
    }
}

impl std::error::Error for Error {}

/// Системный синтезатор; реализация — на платформе.
pub trait Speech {
    /// Сказать текст; `interrupt` обрывает текущее высказывание.
    fn say(&mut self, text: &str, interrupt: bool) -> Result<(), Error>;
    /// Идёт ли сейчас озвучивание.
    fn speaking(&self) -> bool;
    /// Обрыв речи.
    fn stop(&mut self) -> Result<(), Error>;
}

/// Связный текст для озвучивания: стихи главы в диапазоне `[lo, hi]`
/// без сносок, ссылок и заголовков разделов. Надписание (стих 0) входит,
/// если `lo = 0`. Числа и ссылки словами — позже (уровни подготовки).
pub fn speakable(ch: &Chapter, lo: u16, hi: u16) -> String {
    let mut out = String::new();
    for (n, t) in ch.verse_texts() {
        if n >= lo && n <= hi {
            if !out.is_empty() && !out.ends_with(' ') && !t.is_empty() {
                out.push(' ');
            }
            out.push_str(&t);
        }
    }
    collapse_spaces(&out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::{Block, Span};

    #[test]
    fn speakable_skips_notes_and_headings() {
        let ch = Chapter {
            number: 1,
            blocks: vec![
                Block {
                    marker: "s1".into(),
                    spans: vec![Span::Text {
                        text: "Заголовок".into(),
                        style: String::new(),
                        attrs: String::new(),
                    }],
                },
                Block {
                    marker: "p".into(),
                    spans: vec![
                        Span::Verse(1),
                        Span::Text {
                            text: "Текст первый.".into(),
                            style: String::new(),
                            attrs: String::new(),
                        },
                        Span::Note {
                            kind: 'f',
                            caller: "+".into(),
                            text: "сноска".into(),
                            attrs: String::new(),
                        },
                        Span::Verse(2),
                        Span::Text {
                            text: "Текст второй".into(),
                            style: String::new(),
                            attrs: String::new(),
                        },
                    ],
                },
            ],
        };
        assert_eq!(speakable(&ch, 0, u16::MAX), "Текст первый. Текст второй");
        assert_eq!(speakable(&ch, 2, 2), "Текст второй");
    }
}
