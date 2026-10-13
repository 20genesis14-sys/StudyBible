//! Поток чтения главы (ADR 0007): блоки и строчные промежутки.
//!
//! Маркеры хранятся как в USFM (`p`, `q1`, `s1`, `d`, `add`, `wj`, `nd`, `w`…), чтобы
//! подмножество USFM проходило круговое преобразование.

/// Блок главы: абзац, строка поэзии, заголовок и т. п.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Block {
    /// Маркер USFM блока; пустой — продолжение без явного маркера.
    pub marker: String,
    pub spans: Vec<Span>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Span {
    /// Начало стиха.
    Verse(u16),
    Text {
        text: String,
        /// Символьный стиль USFM (`add`, `wj`, `nd`, `w`…); пусто — обычный текст.
        style: String,
        /// Атрибуты слова (`strong="H7225"`), если есть.
        attrs: String,
    },
    /// Сноска (`f`) или перекрёстная ссылка (`x`).
    Note {
        kind: char,
        caller: String,
        text: String,
        /// Атрибуты привязки к части стиха (ADR 0016, п. 8):
        /// `q="…"` — цитируемый текст привязки (USFM `\fq`/`\xq`,
        /// OSIS `<catchWord>`), `part="a"` — буква части стиха
        /// (USFM `\fr`/`\xo`, `1:1a`). Пусто — ссылка на целый стих.
        attrs: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Chapter {
    pub number: u16,
    pub blocks: Vec<Block>,
}

/// Вид блока для вывода и для выбора текста стиха.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum BlockKind {
    Paragraph,
    Poetry,
    /// Заголовок раздела — не входит в текст стиха.
    Heading,
    /// Надписание псалма — текст стиха 0.
    Superscription,
    Blank,
}

impl Block {
    pub fn kind(&self) -> BlockKind {
        let base = self.marker.trim_end_matches(|c: char| c.is_ascii_digit());
        match base {
            "q" | "qr" | "qc" | "qm" | "qd" => BlockKind::Poetry,
            "s" | "ms" | "mr" | "r" | "sr" | "sp" | "cl" | "qa" | "sd" => BlockKind::Heading,
            "is" | "iis" | "imt" | "imte" | "mt" | "mte" | "ih" => BlockKind::Heading,
            "d" => BlockKind::Superscription,
            "b" => BlockKind::Blank,
            _ => BlockKind::Paragraph,
        }
    }
}

impl Chapter {
    /// Чистый текст стихов главы без сносок и заголовков; надписание — стих 0.
    pub fn verse_texts(&self) -> Vec<(u16, String)> {
        let mut out: Vec<(u16, String)> = Vec::new();
        let mut current: Option<u16> = None;
        for block in &self.blocks {
            let kind = block.kind();
            if kind == BlockKind::Heading {
                continue;
            }
            if kind == BlockKind::Superscription && current.is_none() {
                current = Some(0);
                out.push((0, String::new()));
            }
            for span in &block.spans {
                match span {
                    Span::Verse(n) => {
                        current = Some(*n);
                        out.push((*n, String::new()));
                    }
                    Span::Text { text, .. } if current.is_some() => {
                        let last = &mut out.last_mut().expect("стих открыт").1;
                        if !last.is_empty()
                            && !last.ends_with(' ')
                            && !text.starts_with([' ', ',', '.', ';', ':', '!', '?'])
                        {
                            last.push(' ');
                        }
                        last.push_str(text);
                    }
                    _ => {}
                }
            }
            if let Some((_, t)) = out
                .last_mut()
                .filter(|(_, t)| !t.is_empty() && !t.ends_with(' '))
            {
                t.push(' ');
            }
        }
        for (_, t) in &mut out {
            *t = collapse_spaces(t);
        }
        out.retain(|(n, t)| *n != 0 || !t.is_empty());
        out
    }

    pub fn verse_text(&self, verse: u16) -> Option<String> {
        self.verse_texts()
            .into_iter()
            .find(|(n, _)| *n == verse)
            .map(|(_, t)| t)
    }

    pub fn last_verse(&self) -> u16 {
        self.verse_texts()
            .iter()
            .map(|(n, _)| *n)
            .max()
            .unwrap_or(0)
    }
}

/// Версия словесного токенизатора (ADR 0025): привязка слоя разметки
/// к тексту перевода хранит `tokenizer`, значения применяются только
/// при совпадении версии.
pub const WORDS_VERSION: &str = "w1";

/// Токенизация `w1`: слова стиха для слоёв разметки (links.word —
/// порядковый номер в этом списке, с нуля).
///
/// Правила:
/// - вход — уже собранный текст стиха ([`Chapter::verse_text`]);
/// - токены режутся по пробелам;
/// - краевые знаки препинания снимаются (`"God," → "God"`,
///   `"(the)" → "the"`), внутренние сохраняются (`don't`,
///   `son-in-law`, `Maher-shalal-hash-baz`, `3:00`);
/// - токены без букв/цифр (`—`, `«`, `…`) не считаются словами и
///   не входят в нумерацию.
///
/// Функция детерминирована и не зависит от локали — один и тот же
/// код исполняется и в приложении (wasm), и в `studybible tokenize`.
pub fn words(text: &str) -> Vec<&str> {
    text.split_whitespace()
        .filter_map(|t| {
            let w = t.trim_matches(|c: char| !c.is_alphanumeric());
            (!w.is_empty()).then_some(w)
        })
        .collect()
}

/// Пробельные последовательности → один пробел, без пробелов по краям и перед знаками препинания.
pub fn collapse_spaces(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for word in s.split_whitespace() {
        if !out.is_empty() && !word.starts_with([',', '.', ';', ':', '!', '?', ')', '»', '”']) {
            out.push(' ');
        }
        out.push_str(word);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_w1_basics() {
        assert_eq!(
            words("In the beginning God created the heavens and the earth."),
            [
                "In",
                "the",
                "beginning",
                "God",
                "created",
                "the",
                "heavens",
                "and",
                "the",
                "earth"
            ]
        );
        // Внутренняя пунктуация сохраняется, краевая снимается.
        assert_eq!(
            words("don't (the) son-in-law, — Maher-shalal-hash-baz; «3:00»"),
            [
                "don't",
                "the",
                "son-in-law",
                "Maher-shalal-hash-baz",
                "3:00"
            ]
        );
        // Токены без букв/цифр не входят в нумерацию.
        assert_eq!(words("а — б … в «г»"), ["а", "б", "в", "г"]);
        assert!(words("— … «»").is_empty());
        assert_eq!(WORDS_VERSION, "w1");
    }
}
