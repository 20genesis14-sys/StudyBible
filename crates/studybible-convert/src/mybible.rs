//! Источник MyBible (модуль `*.SQLite3`): таблицы `info`, `books`,
//! `verses(book_number, chapter, verse, text)`; необязательные
//! `stories` — заголовки разделов. Комментарии — отдельный файл
//! `*.commentaries.SQLite3` (`commentaries` с диапазоном стихов),
//! словарь — `*.dictionary.SQLite3` (`dictionary(topic, definition)`).
//!
//! Номера книг MyBible: 10 = Бытие … 730 = Откровение; таблица по
//! спецификации формата (сверена с BibleMultiConverter MyBibleZone).
//! Несопоставленный номер книги — ошибка, а не молчаливый пропуск.
//!
//! Разметка `verses.text`: `<S>N</S>` — номер Стронга к предыдущему
//! слову (префикс H для ВЗ / G для НЗ; `info.strong_numbers_prefix`
//! переопределяет), `<f>`/`<n>` — сноски, `<i>` — `\add`, `<J>` — `wj`,
//! `<e>`/`<t>` — курсив, `<h>` — заголовок раздела, `<pb/>` — абзац,
//! `<br/>` — перенос строки; прочие теги снимаются, текст остаётся.

use std::collections::BTreeMap;
use std::path::Path;

use studybible_core::BookCode;
use studybible_core::book::{BookCatalog, NameProfile};
use studybible_core::text::{Block, Chapter, Span};

use crate::{tsv, usfm};

fn err(e: impl std::fmt::Display) -> usfm::Error {
    usfm::Error(format!("MyBible: {e}"))
}

/// Номер книги MyBible → код нашего каталога. По спецификации формата
/// (та же таблица у BibleMultiConverter `MyBibleZone.BOOK_INFO`).
fn book_code(n: i64) -> Result<BookCode, usfm::Error> {
    let code = match n {
        10 => "GEN",
        20 => "EXO",
        30 => "LEV",
        40 => "NUM",
        50 => "DEU",
        60 => "JOS",
        70 => "JDG",
        80 => "RUT",
        90 => "1SA",
        100 => "2SA",
        110 => "1KI",
        120 => "2KI",
        130 => "1CH",
        140 => "2CH",
        145 => "MAN", // Молитва Манассии
        150 => "EZR",
        160 => "NEH",
        165 => "1ES", // Вторая книга Ездры
        170 => "TOB",
        180 => "JDT",
        190 => "EST",
        220 => "JOB",
        230 => "PSA",
        240 => "PRO",
        250 => "ECC",
        260 => "SNG",
        270 => "WIS",
        280 => "SIR",
        290 => "ISA",
        300 => "JER",
        310 => "LAM",
        315 => "LJE", // Послание Иеремии
        320 => "BAR",
        330 => "EZK",
        340 => "DAN",
        350 => "HOS",
        360 => "JOL",
        370 => "AMO",
        380 => "OBA",
        390 => "JON",
        400 => "MIC",
        410 => "NAM",
        420 => "HAB",
        430 => "ZEP",
        440 => "HAG",
        450 => "ZEC",
        460 => "MAL",
        462 => "1MA",
        464 => "2MA",
        466 => "3MA",
        468 => "2ES", // Третья книга Ездры
        470 => "MAT",
        480 => "MRK",
        490 => "LUK",
        500 => "JHN",
        510 => "ACT",
        520 => "ROM",
        530 => "1CO",
        540 => "2CO",
        550 => "GAL",
        560 => "EPH",
        570 => "PHP",
        580 => "COL",
        590 => "1TH",
        600 => "2TH",
        610 => "1TI",
        620 => "2TI",
        630 => "TIT",
        640 => "PHM",
        650 => "HEB",
        660 => "JAS",
        670 => "1PE",
        680 => "2PE",
        690 => "1JN",
        700 => "2JN",
        710 => "3JN",
        720 => "JUD",
        730 => "REV",
        // 192 AddEsth, 305 PrAzar, 323 AddDan, 325 Sus, 341 DanGr,
        // 345 Bel, 467 4Macc, 780 EpLao — в каталоге книг нет.
        _ => return Err(usfm::Error(format!("MyBible: неизвестный номер книги {n}"))),
    };
    Ok(BookCode::new(code).expect("код"))
}

/// Таблица info → ключ→значение.
fn info_map(conn: &rusqlite::Connection) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if let Ok(mut st) = conn.prepare("SELECT name, value FROM info")
        && let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
    {
        for r in rows.flatten() {
            out.insert(r.0.to_lowercase(), r.1);
        }
    }
    out
}

/// Есть ли таблица в базе.
fn has_table(conn: &rusqlite::Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
        [name],
        |_| Ok(()),
    )
    .is_ok()
}

/// Заголовки разделов из stories: (книга, глава, стих) → название.
fn stories(conn: &rusqlite::Connection) -> Result<BTreeMap<(i64, i64, i64), String>, usfm::Error> {
    let mut out = BTreeMap::new();
    if !has_table(conn, "stories") {
        return Ok(out);
    }
    let mut st = conn
        .prepare(
            "SELECT book_number, chapter, verse, title FROM stories
             ORDER BY book_number, chapter, verse, order_if_several",
        )
        .map_err(err)?;
    let rows = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
            ))
        })
        .map_err(err)?;
    for r in rows.flatten() {
        out.entry((r.0, r.1, r.2))
            .and_modify(|t: &mut String| {
                t.push(' ');
                t.push_str(&r.3);
            })
            .or_insert(r.3);
    }
    Ok(out)
}

/// Названия книг из books: номер → длинное имя.
fn book_names(conn: &rusqlite::Connection) -> Result<BTreeMap<i64, String>, usfm::Error> {
    let mut out = BTreeMap::new();
    if !has_table(conn, "books") {
        return Ok(out);
    }
    let mut st = conn
        .prepare("SELECT book_number, long_name FROM books ORDER BY book_number")
        .map_err(err)?;
    let rows = st
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .map_err(err)?;
    for r in rows.flatten() {
        out.insert(r.0, r.1);
    }
    Ok(out)
}

/// Снять все теги, оставить текст (для сносок/заголовков).
pub(crate) fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    usfm::normalize(&out).trim().to_string()
}

/// Привязать номер Стронга к последнему слову накопленных спанов:
/// хвостовое слово последнего текстового спана выносится в спан `w`.
fn attach_strong(spans: &mut Vec<Span>, num: &str) {
    let Some(Span::Text { text, .. }) = spans.last_mut() else {
        return;
    };
    let trimmed = text.trim_end();
    let start = trimmed
        .rfind(char::is_whitespace)
        .map(|i| i + 1)
        .unwrap_or(0);
    if start == trimmed.len() {
        return;
    }
    let word = trimmed[start..].to_string();
    text.truncate(start);
    // Хвост текстового спана без слова убираем совсем.
    if text.trim().is_empty() {
        spans.pop();
    }
    spans.push(Span::Text {
        text: format!("{word} "),
        style: "w".into(),
        attrs: format!("strong=\"{num}\""),
    });
}

/// Стих MyBible (`verses.text` с тегами) → блоки потока чтения.
/// `strong_prefix` — «H»/«G» по завету или `strong_numbers_prefix`;
/// пустая строка — теги `<S>` игнорируются (BibleQuote без StrongNumbers).
/// Общий разбор инлайн-разметки: используется и biblequote.rs.
pub(crate) fn verse_html_blocks(html: &str, strong_prefix: &str) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut spans: Vec<Span> = Vec::new();
    let mut styles: Vec<&'static str> = Vec::new();
    let mut note: Option<String> = None;
    let mut pos = 0;
    let bytes = html.as_bytes();
    let flush = |blocks: &mut Vec<Block>, spans: &mut Vec<Span>| {
        if !spans.is_empty() {
            blocks.push(Block {
                marker: "p".into(),
                spans: std::mem::take(spans),
            });
        }
    };
    while pos < bytes.len() {
        if bytes[pos] != b'<' {
            let end = html[pos..]
                .find('<')
                .map(|i| pos + i)
                .unwrap_or(bytes.len());
            let t = usfm::normalize(&html[pos..end]);
            if let Some(buf) = note.as_mut() {
                buf.push_str(&t);
            } else if !t.trim().is_empty() {
                let style = styles.last().copied().unwrap_or("");
                spans.push(Span::Text {
                    text: t,
                    style: style.into(),
                    attrs: String::new(),
                });
            }
            pos = end;
            continue;
        }
        let end = html[pos..]
            .find('>')
            .map(|i| pos + i + 1)
            .unwrap_or(bytes.len());
        let raw = &html[pos..end];
        let inner = raw[1..raw.len() - 1].trim();
        let closing = inner.starts_with('/');
        let name: String = inner
            .trim_start_matches('/')
            .split(|c: char| c.is_whitespace() || c == '/')
            .next()
            .unwrap_or("")
            .to_lowercase();
        pos = end;
        if let Some(buf) = note.as_mut() {
            if closing && matches!(name.as_str(), "f" | "n") {
                spans.push(Span::Note {
                    kind: 'f',
                    caller: "+".into(),
                    text: buf.trim().to_string(),
                    attrs: String::new(),
                });
                note = None;
            }
            continue;
        }
        match (closing, name.as_str()) {
            (true, "i") => drop_first(&mut styles, "add"),
            (true, "j") => drop_first(&mut styles, "wj"),
            (true, "e" | "t") => drop_first(&mut styles, "it"),
            (true, _) => {}
            (false, "s") => {
                // <S>N</S>: номер Стронга к предыдущему слову.
                let end_s = html[pos..]
                    .find("</S>")
                    .or_else(|| html[pos..].find("</s>"));
                if let Some(e) = end_s {
                    let num = strip_tags(&html[pos..pos + e]);
                    pos += e + 4;
                    if !strong_prefix.is_empty() {
                        for n in num.split_whitespace() {
                            let n = n.trim_start_matches(['H', 'G', 'h', 'g']);
                            if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) {
                                attach_strong(&mut spans, &format!("{strong_prefix}{n}"));
                            }
                        }
                    }
                }
            }
            (false, "f" | "n") => note = Some(String::new()),
            (false, "i") => styles.push("add"),
            (false, "j") => styles.push("wj"),
            (false, "e" | "t") => styles.push("it"),
            (false, "h") => {
                // Заголовок раздела в тексте стиха → блок s1.
                flush(&mut blocks, &mut spans);
                let end_h = html[pos..]
                    .find("</h>")
                    .or_else(|| html[pos..].find("</H>"));
                if let Some(e) = end_h {
                    let t = strip_tags(&html[pos..pos + e]);
                    pos += e + 4;
                    if !t.is_empty() {
                        blocks.push(Block {
                            marker: "s1".into(),
                            spans: vec![Span::Text {
                                text: format!("{t} "),
                                style: String::new(),
                                attrs: String::new(),
                            }],
                        });
                    }
                }
            }
            (false, "pb" | "br") => flush(&mut blocks, &mut spans),
            _ => {} // прочие теги снимаем — текст остаётся
        }
    }
    flush(&mut blocks, &mut spans);
    blocks
}

fn drop_first(styles: &mut Vec<&'static str>, s: &'static str) {
    if let Some(i) = styles.iter().rposition(|x| *x == s) {
        styles.remove(i);
    }
}

/// Разобрать `*.SQLite3` (Библия) в книги ядра.
pub fn parse_file(path: &Path) -> Result<Vec<usfm::Book>, usfm::Error> {
    let conn = rusqlite::Connection::open(path).map_err(err)?;
    if !has_table(&conn, "verses") {
        return Err(err("нет таблицы verses"));
    }
    let info = info_map(&conn);
    let strong_prefix = info
        .get("strong_numbers_prefix")
        .map(|s| s.trim().to_uppercase())
        .filter(|s| matches!(s.as_str(), "H" | "G" | "HG" | "GH"))
        .unwrap_or_default();
    let stories = stories(&conn)?;
    let names = book_names(&conn)?;
    let title = info
        .get("description")
        .or_else(|| info.get("name"))
        .cloned();

    let mut st = conn
        .prepare(
            "SELECT book_number, chapter, verse, text FROM verses
             ORDER BY book_number, chapter, verse",
        )
        .map_err(err)?;
    let rows = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
            ))
        })
        .map_err(err)?;

    let catalog = BookCatalog::builtin();
    let mut books: Vec<usfm::Book> = Vec::new();
    for r in rows {
        let (bn, ch_n, v_n, text) = r.map_err(err)?;
        let code = book_code(bn)?;
        let book = match books.iter_mut().find(|b| b.code == code) {
            Some(b) => b,
            None => {
                let mut header = BTreeMap::new();
                header.insert("id".into(), code.as_str().to_string());
                if let Some(t) = names.get(&bn) {
                    header.insert("h".into(), t.clone());
                    header.insert("toc1".into(), t.clone());
                }
                // Короткое имя — синодальное сокращение каталога.
                if let Some(b) = catalog.by_code(code) {
                    header.insert("toc3".into(), b.abbr(NameProfile::Synodal).to_string());
                }
                books.push(usfm::Book {
                    code,
                    header,
                    chapters: vec![],
                });
                books.last_mut().unwrap()
            }
        };
        if book.chapters.last().is_none_or(|c| c.number != ch_n as u16) {
            book.chapters.push(Chapter {
                number: ch_n as u16,
                blocks: vec![],
            });
        }
        let ch = book.chapters.last_mut().unwrap();
        // Заголовок раздела из stories перед стихом.
        if let Some(t) = stories.get(&(bn, ch_n, v_n)) {
            let t = strip_tags(t);
            if !t.is_empty() {
                ch.blocks.push(Block {
                    marker: "s1".into(),
                    spans: vec![Span::Text {
                        text: format!("{t} "),
                        style: String::new(),
                        attrs: String::new(),
                    }],
                });
            }
        }
        // Префикс Стронга: из info или по завету (книги < 470 — ВЗ).
        let prefix = match strong_prefix.as_str() {
            "H" => "H",
            "G" => "G",
            _ => {
                if bn < 470 {
                    "H"
                } else {
                    "G"
                }
            }
        };
        let mut vb = verse_html_blocks(&text, prefix);
        // Маркер стиха — первый спан первого блока стиха.
        if vb.is_empty() {
            vb.push(Block {
                marker: "p".into(),
                spans: vec![],
            });
        }
        vb[0].spans.insert(0, Span::Verse(v_n as u16));
        ch.blocks.extend(vb);
    }
    if books.is_empty() {
        return Err(err("таблица verses пуста"));
    }
    // Название модуля полезно отладчикам — в заголовок первой книги
    // поля писать не будем (title берётся из modules.json); список
    // имён info нужен только для языка/описания на стороне CLI.
    let _ = title;
    Ok(books)
}

/// Разобрать `*.commentaries.SQLite3` в модуль комментариев:
/// запись `commentaries` привязывается к первому стиху диапазона
/// (как у gen_henry.py).
pub fn parse_commentary_file(path: &Path) -> Result<Vec<usfm::Book>, usfm::Error> {
    let conn = rusqlite::Connection::open(path).map_err(err)?;
    if !has_table(&conn, "commentaries") {
        return Err(err("нет таблицы commentaries"));
    }
    let mut st = conn
        .prepare(
            "SELECT book_number, chapter_number_from, verse_number_from,
                    chapter_number_to, verse_number_to, marker, text
             FROM commentaries
             ORDER BY book_number, chapter_number_from, verse_number_from",
        )
        .map_err(err)?;
    let rows = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(6)?,
            ))
        })
        .map_err(err)?;

    // (книга, глава) → список (стих, абзацы текста).
    type ByCh = BTreeMap<u16, Vec<(u16, Vec<String>)>>;
    let mut by_book: BTreeMap<BookCode, ByCh> = BTreeMap::new();
    let mut order: Vec<BookCode> = Vec::new();
    for r in rows {
        let (bn, ch_from, v_from, text) = r.map_err(err)?;
        let code = book_code(bn)?;
        if !by_book.contains_key(&code) {
            order.push(code);
        }
        let t = strip_tags(&text);
        if t.is_empty() {
            continue;
        }
        by_book
            .entry(code)
            .or_default()
            .entry(ch_from as u16)
            .or_default()
            .push((v_from as u16, vec![t]));
    }

    let mut books = Vec::new();
    for code in order {
        let mut book = usfm::Book {
            code,
            ..usfm::Book::default()
        };
        book.header.insert("id".into(), code.as_str().to_string());
        for (ch_n, verses) in by_book.remove(&code).unwrap_or_default() {
            let mut ch = Chapter {
                number: ch_n,
                blocks: vec![],
            };
            for (v, paras) in verses {
                for (i, text) in paras.into_iter().enumerate() {
                    let mut spans = Vec::new();
                    if i == 0 {
                        spans.push(Span::Verse(v));
                    }
                    spans.push(Span::Text {
                        text: format!("{text} "),
                        style: String::new(),
                        attrs: String::new(),
                    });
                    ch.blocks.push(Block {
                        marker: "p".into(),
                        spans,
                    });
                }
            }
            book.chapters.push(ch);
        }
        books.push(book);
    }
    Ok(books)
}

/// Разобрать `*.dictionary.SQLite3` в статьи словарного модуля
/// (те же `EntryInput`, что даёт `tsv::parse_entries`).
pub fn parse_dictionary_file(path: &Path) -> Result<Vec<tsv::EntryInput>, usfm::Error> {
    let conn = rusqlite::Connection::open(path).map_err(err)?;
    if !has_table(&conn, "dictionary") {
        return Err(err("нет таблицы dictionary"));
    }
    let mut st = conn
        .prepare("SELECT topic, definition FROM dictionary ORDER BY topic")
        .map_err(err)?;
    let rows = st
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(err)?;
    let mut out = Vec::new();
    for r in rows.flatten() {
        let headword = r.0.trim();
        if headword.is_empty() {
            continue;
        }
        out.push(tsv::EntryInput {
            headword: headword.to_string(),
            text: strip_tags(&r.1),
            norm: headword.to_lowercase(),
        });
    }
    if out.is_empty() {
        return Err(err("таблица dictionary пуста"));
    }
    Ok(out)
}
