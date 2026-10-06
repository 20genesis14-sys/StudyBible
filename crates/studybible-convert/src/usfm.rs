//! Разбор USFM в поток чтения ядра и обратная запись (подмножество маркеров).

use std::collections::BTreeMap;
use std::fmt::Write as _;

use studybible_core::BookCode;
use studybible_core::text::{Block, BlockKind, Chapter, Span};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Book {
    pub code: BookCode,
    /// Маркеры заголовка книги до первой главы: `id`, `h`, `toc1`…`toc3`, `mt1`…
    pub header: BTreeMap<String, String>,
    pub chapters: Vec<Chapter>,
}

impl Default for Book {
    fn default() -> Self {
        Self {
            code: BookCode::new("XXX").expect("код"),
            header: BTreeMap::new(),
            chapters: vec![],
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "USFM: {}", self.0)
    }
}

impl std::error::Error for Error {}

const HEADER: [&str; 9] = [
    "id", "ide", "h", "toc1", "toc2", "toc3", "usfm", "sts", "rem",
];
const CHAR_STYLES: [&str; 20] = [
    "add", "wj", "nd", "w", "qs", "qac", "sc", "bk", "it", "bd", "bdit", "em", "k", "tl", "pn",
    "png", "ord", "sls", "no", "dc",
];

fn is_paragraph(m: &str) -> bool {
    let base = m.trim_end_matches(|c: char| c.is_ascii_digit());
    matches!(
        base,
        "p" | "m"
            | "pi"
            | "pm"
            | "pmo"
            | "pmc"
            | "pmr"
            | "mi"
            | "nb"
            | "pc"
            | "pr"
            | "ph"
            | "cls"
            | "li"
            | "lim"
            | "q"
            | "qr"
            | "qc"
            | "qa"
            | "qm"
            | "qd"
            | "s"
            | "ms"
            | "mr"
            | "r"
            | "sr"
            | "sp"
            | "sd"
            | "d"
            | "b"
            | "mt"
            | "mte"
            | "cl"
            | "lh"
            | "lf"
            | "ip"
            | "ipi"
            | "im"
            | "imi"
            | "ipq"
            | "imq"
            | "ipr"
            | "iq"
            | "ib"
            | "ili"
            | "iili"
            | "iot"
            | "io"
            | "ior"
            | "iex"
            | "imt"
            | "imte"
            | "is"
            | "iis"
            | "ie"
            | "ih"
    )
}

struct Token<'a> {
    marker: Option<&'a str>,
    text: &'a str,
}

/// Последовательность «маркер + текст до следующего маркера».
fn tokens(src: &str) -> Vec<Token<'_>> {
    let mut out = Vec::new();
    let mut rest = src;
    if let Some(i) = rest.find('\\') {
        out.push(Token {
            marker: None,
            text: &rest[..i],
        });
        rest = &rest[i..];
    } else {
        return vec![Token {
            marker: None,
            text: rest,
        }];
    }
    while let Some(after) = rest.strip_prefix('\\') {
        let len = after
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '+' || c == '*'))
            .unwrap_or(after.len());
        let marker = &after[..len];
        let mut body = &after[len..];
        if !marker.ends_with('*') {
            body = body.strip_prefix([' ', '\n', '\r', '\t']).unwrap_or(body);
            if body.starts_with('\n') {
                body = &body[1..];
            }
        }
        let end = body.find('\\').unwrap_or(body.len());
        out.push(Token {
            marker: Some(marker),
            text: &body[..end],
        });
        rest = &body[end..];
    }
    out
}

fn first_word(s: &str) -> (&str, &str) {
    let s = s.trim_start();
    let end = s.find(char::is_whitespace).unwrap_or(s.len());
    (&s[..end], &s[end..])
}

pub(crate) fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for c in s.chars() {
        if c.is_whitespace() {
            space = true;
        } else {
            if space {
                out.push(' ');
            }
            space = false;
            out.push(c);
        }
    }
    if space {
        out.push(' ');
    }
    out
}

pub fn parse(src: &str) -> Result<Book, Error> {
    let src = src.trim_start_matches('\u{feff}');
    let mut book = Book::default();
    let mut chapter: Option<Chapter> = None;
    let mut styles: Vec<String> = Vec::new();
    let toks = tokens(src);
    let mut i = 0;
    while i < toks.len() {
        let Token { marker, text } = toks[i];
        i += 1;
        let Some(m) = marker else {
            if let Some(ch) = chapter.as_mut() {
                push_text(ch, text, &styles);
            }
            continue;
        };
        let name = m.trim_start_matches('+');
        match name {
            "c" => {
                let (n, _) = first_word(text);
                let n = n.parse().map_err(|_| Error(format!("номер главы «{n}»")))?;
                book.chapters.extend(chapter.take());
                chapter = Some(Chapter {
                    number: n,
                    blocks: vec![],
                });
                styles.clear();
            }
            "v" => {
                let ch = chapter
                    .as_mut()
                    .ok_or_else(|| Error("стих до главы".into()))?;
                let (n, rest) = first_word(text);
                let n: u16 = n
                    .split('-')
                    .next()
                    .and_then(|v| v.trim_end_matches(char::is_alphabetic).parse().ok())
                    .ok_or_else(|| Error(format!("номер стиха «{n}»")))?;
                // Стих после заголовка раздела — новый блок без маркера,
                // чтобы текст стиха не попадал в блок заголовка.
                if current_block(ch).kind() == BlockKind::Heading {
                    ch.blocks.push(Block::default());
                }
                current_block(ch).spans.push(Span::Verse(n));
                push_text(ch, rest.strip_prefix(' ').unwrap_or(rest), &styles);
            }
            "f" | "x" | "fe" => {
                let close = format!("{name}*");
                let (caller, first) = first_word(text);
                let mut note = String::new();
                let mut skip = false;
                let add = |s: &str, skip: bool, note: &mut String| {
                    if !skip {
                        note.push_str(s);
                    }
                };
                add(first, false, &mut note);
                while i < toks.len() && toks[i].marker != Some(close.as_str()) {
                    let t = &toks[i];
                    let inner = t.marker.unwrap_or("").trim_start_matches('+');
                    if !inner.ends_with('*') {
                        skip = matches!(inner, "fr" | "xo" | "fv");
                    }
                    add(t.text, skip, &mut note);
                    i += 1;
                }
                // Текст после закрывающего маркера продолжает стих.
                let trailing = if i < toks.len() { toks[i].text } else { "" };
                i += 1;
                if let Some(ch) = chapter.as_mut() {
                    let kind = if name == "x" { 'x' } else { 'f' };
                    current_block(ch).spans.push(Span::Note {
                        kind,
                        caller: caller.to_string(),
                        text: normalize(&note).trim().to_string(),
                    });
                    push_text(ch, trailing, &styles);
                }
            }
            _ if name.ends_with('*') => {
                let open = name.trim_end_matches('*');
                if let Some(pos) = styles.iter().rposition(|s| s == open) {
                    styles.truncate(pos);
                }
                if let Some(ch) = chapter.as_mut() {
                    push_text(ch, text, &styles);
                }
            }
            _ if CHAR_STYLES.contains(&name) => {
                styles.push(name.to_string());
                if let Some(ch) = chapter.as_mut() {
                    push_text(ch, text, &styles);
                }
            }
            _ if chapter.is_none() => {
                if name == "id" {
                    let (code, _) = first_word(text);
                    book.code =
                        BookCode::new(code).ok_or_else(|| Error(format!("код книги «{code}»")))?;
                }
                if HEADER.contains(&name) || name.starts_with("mt") {
                    book.header
                        .insert(name.to_string(), normalize(text).trim().to_string());
                }
            }
            _ if is_paragraph(name) => {
                let ch = chapter.as_mut().expect("глава");
                styles.clear();
                ch.blocks.push(Block {
                    marker: name.to_string(),
                    spans: vec![],
                });
                push_text(ch, text, &styles);
            }
            _ => {
                if let Some(ch) = chapter.as_mut() {
                    push_text(ch, text, &styles);
                }
            }
        }
    }
    book.chapters.extend(chapter);
    if book.code.as_str() == "XXX" {
        return Err(Error("нет \\id".into()));
    }
    Ok(book)
}

pub(crate) fn current_block(ch: &mut Chapter) -> &mut Block {
    if ch.blocks.is_empty() {
        ch.blocks.push(Block::default());
    }
    ch.blocks.last_mut().expect("блок")
}

fn push_text(ch: &mut Chapter, text: &str, styles: &[String]) {
    let style = styles.last().cloned().unwrap_or_default();
    let text = normalize(text);
    let (text, attrs) = match text.split_once('|') {
        Some((t, a)) if !style.is_empty() => (t.to_string(), a.trim().to_string()),
        _ => (text, String::new()),
    };
    push_span(ch, &text, &style, attrs);
}

/// Текстовый промежуток без разбора `|`: стиль и атрибуты заданы явно (OSIS).
pub(crate) fn push_span(ch: &mut Chapter, text: &str, style: &str, attrs: String) {
    let text = normalize(text);
    if text.trim().is_empty() && !text.is_empty() {
        if let Some(Span::Text { text: t, .. }) =
            ch.blocks.last_mut().and_then(|b| b.spans.last_mut())
            && !t.ends_with(' ')
        {
            t.push(' ');
        }
        return;
    }
    if text.is_empty() {
        return;
    }
    current_block(ch).spans.push(Span::Text {
        text,
        style: style.to_string(),
        attrs,
    });
}

impl Book {
    pub fn chapter(&self, n: u16) -> Option<&Chapter> {
        self.chapters.iter().find(|c| c.number == n)
    }

    pub fn verse_text(&self, chapter: u16, verse: u16) -> Option<String> {
        self.chapter(chapter)?.verse_text(verse)
    }

    /// Последний номер стиха в каждой главе.
    pub fn chapter_sizes(&self) -> Vec<u16> {
        let mut v: Vec<&Chapter> = self.chapters.iter().collect();
        v.sort_by_key(|c| c.number);
        v.into_iter().map(Chapter::last_verse).collect()
    }

    /// Запись в USFM (подмножество маркеров, без исходного форматирования строк).
    pub fn to_usfm(&self) -> String {
        let mut out = String::new();
        for (m, t) in &self.header {
            if m == "id" {
                let _ = writeln!(out, "\\id {t}");
            }
        }
        for (m, t) in self.header.iter().filter(|(m, _)| *m != "id") {
            let _ = writeln!(out, "\\{m} {t}");
        }
        for ch in &self.chapters {
            let _ = writeln!(out, "\\c {}", ch.number);
            for b in &ch.blocks {
                if !b.marker.is_empty() {
                    let _ = write!(out, "\n\\{}", b.marker);
                }
                for s in &b.spans {
                    match s {
                        Span::Verse(n) => {
                            let _ = write!(out, "\n\\v {n} ");
                        }
                        Span::Text { text, style, attrs } if style.is_empty() => out.push_str(text),
                        Span::Text { text, style, attrs } => {
                            let a = if attrs.is_empty() {
                                String::new()
                            } else {
                                format!("|{attrs}")
                            };
                            let _ = write!(out, "\\{style} {text}{a}\\{style}*");
                        }
                        Span::Note { kind, caller, text } => {
                            let _ = write!(
                                out,
                                "\\{kind} {caller} \\{}t {text}\\{kind}*",
                                if *kind == 'x' { 'x' } else { 'f' }
                            );
                        }
                    }
                }
            }
        }
        out
    }
}
