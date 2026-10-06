//! Разбор OSIS XML в поток чтения ядра и обратная запись (подмножество элементов).
//!
//! Разбираются: `div type="book"`/`chapter`, `chapter` и `verse` (обёртка и вехи
//! `sID`/`eID`), `p`, `lg`/`l`, `div type="section"` с `title`, `note`
//! (`crossReference` → ссылка `x`, прочие → сноска `f`), `reference`,
//! `transChange type="added"` → `add`, `q who="Jesus"` → `wj`, `divineName` → `nd`,
//! `w` (lemma `strong:H…` → `strong="H…"`), `hi` → `it`/`bd`/`em`/`sc`.
//! Прочие символьные стили пишутся/читаются как `seg type="x-usfm-{стиль}"`,
//! несвойственные маркеры блоков — как `milestone type="x-usfm-marker" marker="…"`.
//! Один файл может содержать несколько книг, поэтому `parse` отдаёт `Vec<Book>`.

use std::fmt::Write as _;

use quick_xml::Reader;
use quick_xml::XmlVersion;
use quick_xml::escape::{escape, unescape};
use quick_xml::events::{BytesStart, Event};

use studybible_core::text::{Block, BlockKind, Chapter, Span};
use studybible_core::{BookCatalog, BookCode};

use crate::usfm::{self, Book, normalize};

#[derive(Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "OSIS: {}", self.0)
    }
}

impl std::error::Error for Error {}

/// Локальное имя элемента/атрибута без префикса пространства имён.
fn attr(e: &BytesStart, name: &str) -> Option<String> {
    e.attributes().flatten().find_map(|a| {
        (a.key.local_name().as_ref() == name).then(|| {
            a.normalized_value(XmlVersion::Implicit1_0)
                .ok()
                .map(String::from)
        })?
    })
}

/// Последний сегмент osisID (`Gen.1.1` → `1`); объединённые стихи — по первому.
fn id_num(id: &str) -> Option<u16> {
    id.split_whitespace()
        .next()?
        .rsplit('.')
        .next()?
        .split('-')
        .next()?
        .trim_end_matches(char::is_alphabetic)
        .parse()
        .ok()
}

/// Маркер блока строки поэзии `<l>`: `level` → `q{N}`, без `level` → `q`.
fn line_marker(e: &BytesStart) -> String {
    match attr(e, "level") {
        Some(level) => format!("q{level}"),
        None => "q".into(),
    }
}

/// Атрибуты слова `<w>`: `lemma="strong:H7225 strongMorph:TH8794"` →
/// `strong="H7225" morph="TH8794"`; прочие пары `k="v"` сохраняются как есть.
fn w_attrs(e: &BytesStart) -> String {
    let mut out: Vec<String> = Vec::new();
    for key in ["lemma", "morph"] {
        let Some(v) = attr(e, key) else { continue };
        for t in v.split_whitespace() {
            if let Some(x) = t.strip_prefix("strong:") {
                out.push(format!("strong=\"{x}\""));
            } else if let Some(x) = t
                .strip_prefix("strongMorph:")
                .or_else(|| t.strip_prefix("morph:"))
            {
                out.push(format!("morph=\"{x}\""));
            } else if t.contains('=') {
                out.push(t.to_string());
            } else {
                out.push(format!("lemma=\"{t}\""));
            }
        }
    }
    out.join(" ")
}

/// Обратное преобразование атрибутов `w` (`strong="H1"` → `strong:H1`).
fn w_attrs_osis(attrs: &str) -> String {
    attrs
        .split_whitespace()
        .map(|t| match t.split_once('=') {
            Some(("strong", v)) => format!("strong:{}", v.trim_matches('"')),
            Some(("morph", v)) => format!("strongMorph:{}", v.trim_matches('"')),
            _ => t.to_string(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Default)]
struct Parser {
    books: Vec<Book>,
    book: Option<Book>,
    chapter: Option<Chapter>,
    /// Стек `type` открытых `div` — для заголовков разделов.
    div_types: Vec<String>,
    /// Стек открытых символьных стилей: (элемент, стиль USFM).
    styles: Vec<(String, String)>,
    /// Атрибуты открытого `<w>`.
    w_attrs: Option<String>,
    /// Собираемая сноска: (вид, метка, текст).
    note: Option<(char, String, String)>,
    /// Заголовок книги в сборе: (ключ header, текст).
    title: Option<(String, String)>,
    /// Глубина открытого `title` — текст внутри него идёт в текущий блок,
    /// даже если это заголовок раздела.
    in_title: usize,
    /// Пропускаемый контент (`header` и т. п.): глубина элементов.
    skip: usize,
    /// Следующий текст/стих открывает новый блок-продолжение
    /// (контент после закрытого `p`/`l`/`title`).
    pending_break: bool,
}

impl Parser {
    fn osis_book(id: &str) -> Result<BookCode, Error> {
        // `osisID` книги — `Gen`; бывает и с префиксом работы — берём хвост.
        let tail = id.rsplit('.').next().unwrap_or(id);
        let cat = BookCatalog::builtin();
        cat.by_osis(id)
            .or_else(|| cat.by_osis(tail))
            .map(|b| b.code)
            .ok_or_else(|| Error(format!("неизвестная книга «{id}»")))
    }

    fn close_chapter(&mut self) {
        if let (Some(b), Some(ch)) = (self.book.as_mut(), self.chapter.take()) {
            b.chapters.push(ch);
        }
    }

    fn close_book(&mut self) {
        self.close_chapter();
        if let Some(b) = self.book.take() {
            self.books.push(b);
        }
    }

    fn open_chapter(&mut self, e: &BytesStart) -> Result<(), Error> {
        let id = attr(e, "osisID")
            .or_else(|| attr(e, "sID"))
            .unwrap_or_default();
        let n = id_num(&id).ok_or_else(|| Error(format!("номер главы «{id}»")))?;
        if self.book.is_none() {
            return Err(Error("глава до книги".into()));
        }
        self.close_chapter();
        self.chapter = Some(Chapter {
            number: n,
            blocks: vec![],
        });
        Ok(())
    }

    fn open_verse(&mut self, e: &BytesStart) -> Result<(), Error> {
        if attr(e, "eID").is_some() {
            return Ok(()); // веха конца стиха
        }
        let id = attr(e, "osisID")
            .or_else(|| attr(e, "sID"))
            .unwrap_or_default();
        let n = id_num(&id).ok_or_else(|| Error(format!("номер стиха «{id}»")))?;
        let ch = self
            .chapter
            .as_mut()
            .ok_or_else(|| Error("стих до главы".into()))?;
        // Стих после заголовка или закрытого блока — новый блок-продолжение,
        // чтобы текст стиха не попадал в чужой блок.
        let fresh = ch
            .blocks
            .last()
            .is_some_and(|b| b.marker.is_empty() && b.spans.is_empty());
        if usfm::current_block(ch).kind() == BlockKind::Heading || (self.pending_break && !fresh) {
            ch.blocks.push(Block::default());
        }
        self.pending_break = false;
        usfm::current_block(ch).spans.push(Span::Verse(n));
        Ok(())
    }

    /// Новый блок; контент после заголовков и закрытых блоков — продолжение.
    fn new_block(&mut self, marker: &str) {
        if let Some(ch) = self.chapter.as_mut() {
            ch.blocks.push(Block {
                marker: marker.to_string(),
                spans: vec![],
            });
        }
        self.pending_break = false;
    }

    /// Блок заголовка раздела по типу текущего `div` или суффиксу `x-usfm-`.
    fn open_title(&mut self, e: &BytesStart) {
        let ty = attr(e, "type").unwrap_or_default();
        if let Some(m) = ty
            .split_whitespace()
            .find_map(|t| t.strip_prefix("x-usfm-"))
        {
            if self.chapter.is_some() {
                self.new_block(m);
            } else {
                self.title = Some((m.to_string(), String::new()));
            }
        } else if self.chapter.is_some() {
            let marker = if ty.split_whitespace().any(|t| t == "psalm") {
                "d".to_string()
            } else {
                // Маркер заголовка — по ближайшему объемлющему `div` раздела.
                let mut marker = "s1";
                for t in self.div_types.iter().rev() {
                    if t.split_whitespace().any(|x| x == "majorSection") {
                        marker = "ms1";
                        break;
                    } else if t.split_whitespace().any(|x| x == "subSection") {
                        marker = "s2";
                        break;
                    } else if t.split_whitespace().any(|x| x == "section") {
                        break;
                    }
                }
                marker.to_string()
            };
            self.new_block(&marker);
        } else {
            // Заголовок книги до первой главы → заголовок header.
            let key = match ty.split_whitespace().next() {
                Some("main") => "mt1",
                Some("runningHead") => "h",
                _ => {
                    if self
                        .book
                        .as_ref()
                        .is_some_and(|b| b.header.contains_key("mt1"))
                    {
                        "h"
                    } else {
                        "mt1"
                    }
                }
            };
            self.title = Some((key.to_string(), String::new()));
        }
        self.in_title += 1;
    }

    fn open_note(&mut self, e: &BytesStart) {
        let kind = match attr(e, "type").as_deref() {
            Some("crossReference") => 'x',
            _ => 'f',
        };
        let caller = attr(e, "n").unwrap_or_else(|| "+".into());
        self.note = Some((kind, caller, String::new()));
    }

    fn open_style(&mut self, e: &BytesStart, elem: &str, style: String) {
        self.styles.push((elem.to_string(), style.clone()));
        if style == "w" {
            self.w_attrs = Some(w_attrs(e));
        }
    }

    fn text(&mut self, s: &str) {
        if self.skip > 0 {
            return;
        }
        if let Some((_, buf)) = self.title.as_mut() {
            buf.push_str(s);
            return;
        }
        if let Some((_, _, buf)) = self.note.as_mut() {
            buf.push_str(s);
            return;
        }
        let Some(ch) = self.chapter.as_mut() else {
            return; // текст вне главы (вводные разделы, front) — не в потоке чтения
        };
        // Содержательный текст после заголовка или закрытого блока —
        // новый блок-продолжение; пробелы между элементами блока не ломают.
        if self.in_title == 0 && !s.trim().is_empty() {
            if self.pending_break || usfm::current_block(ch).kind() == BlockKind::Heading {
                ch.blocks.push(Block::default());
            }
            self.pending_break = false;
        }
        let style = self
            .styles
            .last()
            .map(|(_, s)| s.clone())
            .unwrap_or_default();
        let attrs = if style == "w" {
            self.w_attrs.clone().unwrap_or_default()
        } else {
            String::new()
        };
        usfm::push_span(ch, s, &style, attrs);
    }

    fn start(&mut self, e: &BytesStart) -> Result<(), Error> {
        let name = e.local_name().as_ref().to_string();
        if self.skip > 0 {
            self.skip += 1;
            return Ok(());
        }
        if self.note.is_some() {
            return Ok(()); // элементы внутри сноски — только текст
        }
        match name.as_str() {
            "header" | "figure" | "index" | "titlePage" => self.skip = 1,
            "div" => {
                let ty = attr(e, "type").unwrap_or_default();
                self.div_types.push(ty.clone());
                if ty.split_whitespace().any(|t| t == "book") {
                    self.close_book();
                    let id = attr(e, "osisID").unwrap_or_default();
                    let code = Self::osis_book(&id)?;
                    self.book = Some(Book {
                        code,
                        ..Book::default()
                    });
                } else if ty.split_whitespace().any(|t| t == "chapter") {
                    self.open_chapter(e)?;
                } else if ty.split_whitespace().any(|t| t == "paragraph") {
                    self.new_block("p");
                }
            }
            "chapter" => self.open_chapter(e)?,
            "verse" => self.open_verse(e)?,
            "p" => self.new_block("p"),
            "l" => self.new_block(&line_marker(e)),
            "title" => self.open_title(e),
            "note" => self.open_note(e),
            "transChange" => {
                if attr(e, "type")
                    .unwrap_or_default()
                    .split_whitespace()
                    .any(|t| t == "added")
                {
                    self.open_style(e, &name, "add".into());
                }
            }
            "divineName" => self.open_style(e, &name, "nd".into()),
            "q" => {
                if attr(e, "who").as_deref() == Some("Jesus") {
                    self.open_style(e, &name, "wj".into());
                }
            }
            "w" => self.open_style(e, &name, "w".into()),
            "hi" => {
                let style = match attr(e, "type").as_deref() {
                    Some("italic") => "it",
                    Some("bold") => "bd",
                    Some("bold italic") | Some("bold-italic") => "bdit",
                    Some("emphasis") => "em",
                    Some("small-caps") => "sc",
                    _ => "",
                };
                if !style.is_empty() {
                    self.open_style(e, &name, style.into());
                }
            }
            "seg" => {
                if let Some(s) = attr(e, "type")
                    .unwrap_or_default()
                    .split_whitespace()
                    .find_map(|t| t.strip_prefix("x-usfm-"))
                {
                    self.open_style(e, &name, s.to_string());
                }
            }
            "milestone" => match attr(e, "type").as_deref() {
                Some("x-usfm-marker") => {
                    self.new_block(&attr(e, "marker").unwrap_or_default());
                }
                Some("x-usfm-empty-block") => self.new_block(""),
                _ => {}
            },
            "lb" => self.text(" "),
            _ => {}
        }
        Ok(())
    }

    fn empty(&mut self, e: &BytesStart) -> Result<(), Error> {
        let name = e.local_name().as_ref().to_string();
        if self.skip > 0 || self.note.is_some() {
            return Ok(());
        }
        match name.as_str() {
            "div" => {
                let ty = attr(e, "type").unwrap_or_default();
                if ty.split_whitespace().any(|t| t == "chapter") {
                    self.open_chapter(e)?;
                    self.close_chapter();
                }
            }
            "chapter" => {
                if attr(e, "eID").is_some() {
                    self.close_chapter();
                } else {
                    self.open_chapter(e)?;
                }
            }
            "verse" => self.open_verse(e)?,
            "p" => self.new_block("p"),
            "l" => self.new_block(&line_marker(e)),
            "note" => {
                self.open_note(e);
                let (kind, caller, buf) = self.note.take().expect("сноска");
                if let Some(ch) = self.chapter.as_mut() {
                    usfm::current_block(ch).spans.push(Span::Note {
                        kind,
                        caller,
                        text: normalize(&buf).trim().to_string(),
                    });
                }
            }
            "milestone" => match attr(e, "type").as_deref() {
                Some("x-usfm-marker") => {
                    self.new_block(&attr(e, "marker").unwrap_or_default());
                }
                Some("x-usfm-empty-block") => self.new_block(""),
                _ => {}
            },
            "lb" => self.text(" "),
            _ => {}
        }
        Ok(())
    }

    fn end(&mut self, name: &str) {
        let name = name.to_string();
        if self.skip > 0 {
            self.skip -= 1;
            return;
        }
        if self.note.is_some() {
            if name == "note" {
                let (kind, caller, buf) = self.note.take().expect("сноска");
                if let Some(ch) = self.chapter.as_mut() {
                    usfm::current_block(ch).spans.push(Span::Note {
                        kind,
                        caller,
                        text: normalize(&buf).trim().to_string(),
                    });
                }
            }
            return; // прочие концы внутри сноски игнорируются
        }
        match name.as_str() {
            "div" => {
                let ty = self.div_types.pop().unwrap_or_default();
                if ty.split_whitespace().any(|t| t == "book") {
                    self.close_book();
                } else if ty.split_whitespace().any(|t| t == "chapter") {
                    self.close_chapter();
                }
            }
            "chapter" => self.close_chapter(),
            "title" => {
                if let Some((key, buf)) = self.title.take()
                    && let Some(b) = self.book.as_mut()
                    && !buf.trim().is_empty()
                {
                    b.header.insert(key, normalize(&buf).trim().to_string());
                }
                self.in_title = self.in_title.saturating_sub(1);
                self.pending_break = true;
            }
            "p" | "l" | "lg" => self.pending_break = true,
            _ => {
                if self.styles.last().is_some_and(|(e, _)| *e == name) {
                    let (_, s) = self.styles.pop().expect("стиль");
                    if s == "w" {
                        self.w_attrs = None;
                    }
                }
            }
        }
    }
}

/// Разбор документа OSIS: все книги `div type="book"` по порядку.
pub fn parse(src: &str) -> Result<Vec<Book>, Error> {
    let src = src.trim_start_matches('\u{feff}');
    let mut r = Reader::from_str(src);
    let mut p = Parser::default();
    loop {
        match r.read_event().map_err(|e| Error(e.to_string()))? {
            Event::Start(e) => p.start(&e)?,
            Event::Empty(e) => p.empty(&e)?,
            Event::End(e) => p.end(e.local_name().as_ref()),
            Event::Text(t) => {
                let raw = t.xml10_content();
                let s = unescape(&raw).map_err(|e| Error(e.to_string()))?;
                p.text(&s);
            }
            Event::CData(t) => p.text(&t.into_inner()),
            Event::Eof => break,
            _ => {}
        }
    }
    p.close_book();
    if p.books.is_empty() {
        return Err(Error("ни одной книги".into()));
    }
    Ok(p.books)
}

/// Код книги OSIS для записи; запасной вариант — код USFM.
fn osis_name(code: BookCode) -> String {
    BookCatalog::builtin()
        .by_code(code)
        .map(|b| b.osis.to_string())
        .unwrap_or_else(|| code.as_str().to_string())
}

/// Стихи внутри блока: вехи `sID`/`eID` вместо обёрток — стих может
/// охватывать границу блока, обёртка дала бы невалидный XML.
fn spans_osis(out: &mut String, spans: &[Span], osis: &str, chapter: u16, open: &mut Option<u16>) {
    for s in spans {
        match s {
            Span::Verse(n) => {
                if let Some(prev) = open.take() {
                    let _ = write!(out, "<verse eID=\"{osis}.{chapter}.{prev}\"/>");
                }
                let _ = write!(
                    out,
                    "<verse osisID=\"{osis}.{chapter}.{n}\" sID=\"{osis}.{chapter}.{n}\"/>"
                );
                *open = Some(*n);
            }
            Span::Text { text, style, attrs } => {
                let t = escape(text);
                match style.as_str() {
                    "" => out.push_str(&t),
                    "add" => {
                        let _ = write!(out, "<transChange type=\"added\">{t}</transChange>");
                    }
                    "wj" => {
                        let _ = write!(out, "<q who=\"Jesus\" marker=\"\">{t}</q>");
                    }
                    "nd" => {
                        let _ = write!(out, "<divineName>{t}</divineName>");
                    }
                    "w" => {
                        let _ = write!(out, "<w lemma=\"{}\">{t}</w>", w_attrs_osis(attrs));
                    }
                    s => {
                        let _ = write!(out, "<seg type=\"x-usfm-{s}\">{t}</seg>");
                    }
                }
            }
            Span::Note { kind, caller, text } => {
                let (ty, inner) = if *kind == 'x' {
                    (
                        "crossReference",
                        format!("<reference>{}</reference>", escape(text)),
                    )
                } else {
                    ("x-footnote", escape(text).into_owned())
                };
                let _ = write!(
                    out,
                    "<note type=\"{ty}\" n=\"{}\">{inner}</note>",
                    escape(caller)
                );
            }
        }
    }
}

impl Book {
    /// Запись в OSIS (подмножество элементов; круговое преобразование
    /// сохраняет поток чтения, но не исходную разметку файла).
    pub fn to_osis(&self) -> String {
        let osis = osis_name(self.code);
        let mut out = String::from("<osis><osisText><div type=\"book\" osisID=\"");
        out.push_str(&osis);
        out.push_str("\">");
        for (k, v) in self.header.iter().filter(|(k, _)| *k != "id") {
            // `mt1` — `type="main"`, прочие заголовки — `x-usfm-{ключ}`.
            let ty = match k.as_str() {
                "mt1" => "main".to_string(),
                k => format!("x-usfm-{k}"),
            };
            let _ = write!(out, "<title type=\"{ty}\">{}</title>", escape(v));
        }
        for ch in &self.chapters {
            let id = format!("{osis}.{}", ch.number);
            let _ = write!(out, "<chapter osisID=\"{id}\" sID=\"{id}\"/>");
            let mut open: Option<u16> = None;
            for b in &ch.blocks {
                let mut spans =
                    |out: &mut String| spans_osis(out, &b.spans, &osis, ch.number, &mut open);
                match b.marker.as_str() {
                    "" => {
                        out.push_str("<milestone type=\"x-usfm-empty-block\"/>");
                        spans(&mut out);
                    }
                    "d" => {
                        out.push_str("<title type=\"psalm\">");
                        spans(&mut out);
                        out.push_str("</title>");
                    }
                    "b" => {
                        let _ = write!(out, "<milestone type=\"x-usfm-marker\" marker=\"b\"/>");
                    }
                    "p" => {
                        out.push_str("<p>");
                        spans(&mut out);
                        out.push_str("</p>");
                    }
                    m if b.kind() == BlockKind::Heading => {
                        let _ = write!(out, "<div type=\"section\"><title type=\"x-usfm-{m}\">");
                        spans(&mut out);
                        out.push_str("</title></div>");
                    }
                    "q" => {
                        out.push_str("<l>");
                        spans(&mut out);
                        out.push_str("</l>");
                    }
                    m if m.starts_with('q') && m[1..].chars().all(|c| c.is_ascii_digit()) => {
                        let _ = write!(out, "<l level=\"{}\">", &m[1..]);
                        spans(&mut out);
                        out.push_str("</l>");
                    }
                    m => {
                        let _ = write!(out, "<milestone type=\"x-usfm-marker\" marker=\"{m}\"/>");
                        spans(&mut out);
                    }
                }
            }
            if let Some(prev) = open.take() {
                let _ = write!(out, "<verse eID=\"{id}.{prev}\"/>");
            }
            let _ = write!(out, "<chapter eID=\"{id}\"/>");
        }
        out.push_str("</div></osisText></osis>");
        out
    }
}
