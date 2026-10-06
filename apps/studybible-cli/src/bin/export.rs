//! Выгрузка данных модуля `.sb` в JSON для прототипа Flutter.
//!
//!   export <файл.sb> <out.json> [КОД:гл[-гл],КОД:гл...]
//!
//! Без списка выгружает только каталог книг с числом глав.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::{Map, Value, json};
use studybible_core::BookCode;
use studybible_core::text::{Block, BlockKind, Span};
use studybible_store::Module;

fn span_json(s: &Span) -> Value {
    match s {
        Span::Verse(n) => json!({"v": n}),
        Span::Text { text, style, attrs } => {
            json!({"t": text, "s": style, "a": attrs})
        }
        Span::Note { kind, caller, text } => {
            json!({"n": kind.to_string(), "c": caller, "t": text})
        }
    }
}

fn block_json(b: &Block) -> Value {
    let kind = match b.kind() {
        BlockKind::Paragraph => "p",
        BlockKind::Poetry => "q",
        BlockKind::Heading => "h",
        BlockKind::Superscription => "d",
        BlockKind::Blank => "b",
    };
    json!({
        "k": kind,
        "m": b.marker,
        "s": b.spans.iter().map(span_json).collect::<Vec<_>>(),
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let sb = PathBuf::from(args.next().expect("файл .sb"));
    let out = PathBuf::from(args.next().expect("out.json"));
    let spec = args.next().unwrap_or_default();

    let m = Module::open(&sb)?;
    let meta = m.meta();

    // Число глав по каждой книге.
    let mut chapter_counts: BTreeMap<String, i64> = BTreeMap::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT book, MAX(chapter) FROM verses GROUP BY book")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for r in rows {
            let (b, c) = r?;
            chapter_counts.insert(b, c);
        }
    }

    let mut books = Vec::new();
    for (code, title) in m.books()? {
        books.push(json!({
            "code": code.as_str(),
            "title": title,
            "chapters": chapter_counts.get(code.as_str()).copied().unwrap_or(0),
        }));
    }

    // Число стихов по каждой главе (для экрана выбора стиха).
    let mut verse_counts = Map::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT book, chapter, MAX(verse) FROM verses GROUP BY book, chapter")?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for r in rows {
            let (b, c, v) = r?;
            verse_counts.insert(format!("{b}:{c}"), Value::from(v));
        }
    }

    // Выбранные главы.
    let mut chapters = Map::new();
    for item in spec.split(',').filter(|s| !s.is_empty()) {
        let (code, range) = item.split_once(':').expect("КОД:гл[-гл]");
        let book = BookCode::new(code).unwrap_or_else(|| panic!("код {code}"));
        let (a, b) = match range.split_once('-') {
            Some((a, b)) => (a.parse::<u16>().unwrap(), b.parse::<u16>().unwrap()),
            None => {
                let n = range.parse::<u16>().unwrap();
                (n, n)
            }
        };
        for ch in a..=b {
            if let Some(c) = m.chapter(book, ch)? {
                let blocks: Vec<Value> = c.blocks.iter().map(block_json).collect();
                chapters.insert(
                    format!("{code}:{ch}"),
                    json!({"n": c.number, "blocks": blocks}),
                );
            }
        }
    }

    let doc = json!({
        "id": meta.id,
        "title": meta.title,
        "language": meta.language,
        "versification": meta.versification,
        "books": books,
        "verse_counts": verse_counts,
        "chapters": chapters,
    });
    std::fs::write(&out, serde_json::to_string(&doc)?)?;
    println!("{} -> {}", sb.display(), out.display());
    Ok(())
}
