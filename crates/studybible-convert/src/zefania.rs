//! Разбор Zefania XML (Zefania Markup Language) в поток чтения ядра.
//!
//! Формат: `<XMLBIBLE><BIBLEBOOK bnumber="1" bname="Genesis">
//! <CHAPTER cnumber="1"><VERS vnumber="1">текст</VERS></CHAPTER>
//! </BIBLEBOOK></XMLBIBLE>`. Один файл обычно несёт весь модуль,
//! поэтому `parse` отдаёт `Vec<Book>` (как у OSIS).
//!
//! Разбираются: `BIBLEBOOK` (книга — по `bname`/`bsname` через каталог
//! или по `bnumber` в каноническом порядке), `CHAPTER`/`VERS`,
//! `STYLE` (`font-style:italic` → `it`, `font-weight:bold` → `bd`,
//! `small-caps` → `sc`), `NOTE` → сноска `f`, `GRAM`/`GR`/`STRONG`
//! с `str="H…"`/`str="G…"` → слово `w` с `strong=`, `CAPTION`/`DIVCAP`
//! → заголовок раздела `s1`, `BR` → перевод строки, `PROLOG`/`TITLE`
//! книги → заголовок `h`. Прочие элементы прозрачны (текст проходит).

use quick_xml::Reader;
use quick_xml::XmlVersion;
use quick_xml::escape::unescape;
use quick_xml::events::{BytesStart, Event};

use studybible_core::text::{Block, BlockKind, Chapter, Span};
use studybible_core::{BookCatalog, BookOrder, NameProfile};

use crate::usfm::{self, Book, normalize};

#[derive(Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Zefania: {}", self.0)
    }
}

impl std::error::Error for Error {}

fn attr(e: &BytesStart, name: &str) -> Option<String> {
    e.attributes().flatten().find_map(|a| {
        (a.key.local_name().as_ref() == name).then(|| {
            a.normalized_value(XmlVersion::Implicit1_0)
                .ok()
                .map(String::from)
        })?
    })
}

/// Книга по bname/bsname (каталог во всех профилях) или по bnumber
/// (позиция в каноническом порядке).
fn book_of(e: &BytesStart) -> Result<Book, Error> {
    let cat = BookCatalog::builtin();
    for key in ["bname", "bsname"] {
        if let Some(name) = attr(e, key) {
            for p in NameProfile::ALL {
                if let Some(b) = cat.lookup(p, &name) {
                    return Ok(Book {
                        code: b.code,
                        header: [("h".into(), name.clone())].into_iter().collect(),
                        ..Book::default()
                    });
                }
            }
        }
    }
    if let Some(n) = attr(e, "bnumber").and_then(|s| s.parse::<u16>().ok()) {
        let ord = cat.ordered(BookOrder::List);
        if let Some(b) = ord.get(usize::from(n.saturating_sub(1))) {
            return Ok(Book {
                code: b.code,
                ..Book::default()
            });
        }
        return Err(Error(format!("книга №{n} вне канона")));
    }
    Err(Error("книга без bname/bnumber".into()))
}

/// Стиль символов из css/class атрибута STYLE.
fn style_of(e: &BytesStart) -> String {
    let css = attr(e, "css")
        .or_else(|| attr(e, "class"))
        .unwrap_or_default()
        .to_lowercase();
    if css.contains("small-caps") {
        "sc".into()
    } else if css.contains("italic") || css.contains("emphasis") {
        "it".into()
    } else if css.contains("bold") {
        "bd".into()
    } else {
        String::new()
    }
}

/// Атрибут strong из GRAM/GR/STRONG: `str="H7225"` → `strong="H7225"`;
/// несколько номеров — через пробел сохраняем первый.
fn strong_of(e: &BytesStart) -> Option<String> {
    for key in ["str", "strid", "strong"] {
        if let Some(v) = attr(e, key) {
            let first = v.split_whitespace().next().unwrap_or(&v);
            return Some(format!("strong=\"{first}\""));
        }
    }
    None
}

#[derive(Default)]
struct Parser {
    books: Vec<Book>,
    book: Option<Book>,
    chapter: Option<Chapter>,
    /// Стек символьных стилей: (элемент, стиль).
    styles: Vec<(String, String)>,
    /// Атрибуты открытого слова `w` (GRAM/STRONG).
    w_attrs: Option<String>,
    /// Собираемая сноска (текст NOTE).
    note: Option<String>,
    /// Текст CAPTION/TITLE/PROLOG в сборе → заголовок/шапка.
    heading: Option<String>,
    /// Пропускаемый контент (INFORMATION и т. п.): глубина.
    skip: usize,
}

impl Parser {
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

    fn text(&mut self, s: &str) {
        if self.skip > 0 {
            return;
        }
        if let Some(buf) = self.note.as_mut() {
            buf.push_str(s);
            return;
        }
        if let Some(buf) = self.heading.as_mut() {
            buf.push_str(s);
            return;
        }
        let Some(ch) = self.chapter.as_mut() else {
            return;
        };
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

    /// Заголовок (CAPTION/DIVCAP) — блок `s1` с собранным текстом.
    fn flush_heading(&mut self) {
        if let Some(buf) = self.heading.take() {
            let text = normalize(&buf).trim().to_string();
            if text.is_empty() {
                return;
            }
            if let Some(ch) = self.chapter.as_mut() {
                ch.blocks.push(Block {
                    marker: "s1".into(),
                    spans: vec![],
                });
                usfm::push_span(ch, &text, "", String::new());
            } else if let Some(b) = self.book.as_mut() {
                // PROLOG/TITLE до глав — заголовок книги.
                b.header.insert("h".into(), text);
            }
        }
    }

    fn start(&mut self, e: &BytesStart) -> Result<(), Error> {
        let name = e.local_name().as_ref().to_string().to_lowercase();
        if self.skip > 0 {
            self.skip += 1;
            return Ok(());
        }
        match name.as_str() {
            "information" | "xmetadata" | "data" => self.skip = 1,
            "biblebook" => {
                self.close_book();
                self.book = Some(book_of(e)?);
            }
            "chapter" => {
                if self.book.is_none() {
                    return Err(Error("глава до книги".into()));
                }
                self.close_chapter();
                let n = attr(e, "cnumber")
                    .unwrap_or_default()
                    .parse()
                    .map_err(|_| Error("глава без cnumber".into()))?;
                self.chapter = Some(Chapter {
                    number: n,
                    blocks: vec![],
                });
            }
            "vers" => {
                self.flush_heading();
                let Some(ch) = self.chapter.as_mut() else {
                    return Ok(()); // VERS вне главы (редко) — пропускаем
                };
                let n: u16 = attr(e, "vnumber")
                    .unwrap_or_default()
                    .parse()
                    .map_err(|_| Error("стих без vnumber".into()))?;
                if usfm::current_block(ch).kind() == BlockKind::Heading {
                    ch.blocks.push(Block::default());
                }
                usfm::current_block(ch).spans.push(Span::Verse(n));
            }
            "caption" | "divcap" | "title" | "prolog" => {
                self.flush_heading();
                self.heading = Some(String::new());
            }
            "note" => self.note = Some(String::new()),
            "gram" | "gr" | "strong" | "w" => {
                self.styles.push((name, "w".into()));
                self.w_attrs = strong_of(e);
            }
            "style" | "i" | "b" | "em" | "sc" => {
                let st = match name.as_str() {
                    "i" => "it".into(),
                    "b" => "bd".into(),
                    "em" => "it".into(),
                    "sc" => "sc".into(),
                    _ => style_of(e),
                };
                if st.is_empty() {
                    self.styles.push((name, String::new()));
                } else {
                    self.styles.push((name, st));
                }
            }
            "br" | "lb" => self.text(" "),
            _ => {}
        }
        Ok(())
    }

    fn end(&mut self, name: &str) {
        let name = name.to_lowercase();
        if self.skip > 0 {
            self.skip -= 1;
            return;
        }
        match name.as_str() {
            "biblebook" => self.close_book(),
            "chapter" => self.close_chapter(),
            "caption" | "divcap" | "title" | "prolog" => self.flush_heading(),
            "note" => {
                if let Some(buf) = self.note.take()
                    && let Some(ch) = self.chapter.as_mut()
                {
                    usfm::current_block(ch).spans.push(Span::Note {
                        kind: 'f',
                        caller: "+".into(),
                        text: normalize(&buf).trim().to_string(),
                    });
                }
            }
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

/// Разбор документа Zefania: все книги BIBLEBOOK по порядку.
pub fn parse(src: &str) -> Result<Vec<Book>, Error> {
    let src = src.trim_start_matches('\u{feff}');
    let mut r = Reader::from_str(src);
    let mut p = Parser::default();
    loop {
        match r.read_event().map_err(|e| Error(e.to_string()))? {
            Event::Start(e) => p.start(&e)?,
            Event::Empty(e) => {
                // <BR/>, пустые вехи — как start+end.
                p.start(&e)?;
                p.end(e.local_name().as_ref());
            }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_verses_styles_strong_notes() {
        let xml = r#"<?xml version="1.0"?>
<XMLBIBLE biblename="Test" version="1.0">
  <INFORMATION><title>Test</title></INFORMATION>
  <BIBLEBOOK bnumber="1" bname="Genesis" bsname="Gen">
    <CHAPTER cnumber="1">
      <CAPTION>Сотворение мира</CAPTION>
      <VERS vnumber="1"><GRAM str="H7225">В начале</GRAM> сотворил
        <STYLE css="font-weight:bold">Бог</STYLE> небо<BR/>
        <NOTE type="x">см. Иов 38</NOTE></VERS>
      <VERS vnumber="2">Земля же была <I>безвидна</I>.</VERS>
    </CHAPTER>
  </BIBLEBOOK>
</XMLBIBLE>"#;
        let books = parse(xml).expect("разбор");
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].code.as_str(), "GEN");
        let ch = &books[0].chapters[0];
        assert_eq!(ch.number, 1);
        // Заголовок + два стиха.
        assert_eq!(ch.blocks[0].marker, "s1");
        assert_eq!(ch.verse_text(1).unwrap().contains("небо"), true);
        assert_eq!(ch.verse_text(2).unwrap(), "Земля же была безвидна.");
        // В стихе 1 есть слово со Стронгом и сноска.
        let mut strong = false;
        let mut note = false;
        for b in &ch.blocks {
            for s in &b.spans {
                match s {
                    Span::Text { style, attrs, .. } if style == "w" && attrs.contains("H7225") => {
                        strong = true;
                    }
                    Span::Note { kind, text, .. } if *kind == 'f' && text.contains("Иов 38") => {
                        note = true;
                    }
                    _ => {}
                }
            }
        }
        assert!(strong, "GRAM → слово со Стронгом");
        assert!(note, "NOTE → сноска");
    }
}
