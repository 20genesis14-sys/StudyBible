//! Чтение модулей .sb для Flutter через `studybible_store::Module`.
//!
//! Формат JSON намеренно повторяет выгрузку
//! `apps/studybible-cli/src/bin/export.rs` — Dart-сторона разбирает его
//! теми же моделями (`lib/models.dart`), что и предвыгруженные JSON-ассеты.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result, anyhow};
use serde_json::{Map, Value, json};
use studybible_core::BookCode;
use studybible_core::text::{Block, BlockKind, Span};
use studybible_store::Module;

/// Модуль .sb, найденный в каталоге данных.
pub struct ModuleInfo {
    /// `meta.id` модуля — ключ выбора в UI (`russyn`, `engwebp`…).
    pub id: String,
    pub title: String,
    /// BCP 47 (`ru`, `en`, `he`, `grc`).
    pub language: String,
    /// Абсолютный путь к файлу .sb.
    pub path: String,
}

/// Открыть модуль `.sb` или `.sbz` (ADR 0016): сжатый файл один раз
/// распаковывается в кэш `<имя>.unpacked.sb` рядом и дальше читается
/// как обычная база. Кэш пересоздаётся, если источник новее.
fn open_any(path: &Path) -> Result<Module> {
    let bytes = std::fs::read(path).with_context(|| format!("не читается {}", path.display()))?;
    if !studybible_store::sbz::is_sbz(&bytes) {
        return Ok(Module::open(path)?);
    }
    let cache = Path::new(&format!("{}.unpacked.sb", path.display())).to_path_buf();
    let fresh = std::fs::metadata(&cache)
        .and_then(|c| std::fs::metadata(path).map(|s| (c, s)))
        .map(|(c, s)| {
            c.modified().unwrap_or(std::time::UNIX_EPOCH)
                >= s.modified().unwrap_or(std::time::UNIX_EPOCH)
        })
        .unwrap_or(false);
    if !fresh {
        let raw = studybible_store::sbz::unpack(&bytes)
            .with_context(|| format!("{}: распаковка .sbz", path.display()))?;
        std::fs::write(&cache, &raw)
            .with_context(|| format!("не пишется кэш {}", cache.display()))?;
    }
    Ok(Module::open(&cache)?)
}

/// Сканировать каталог и вернуть модули .sb/.sbz, которые открываются.
/// Битые и посторонние файлы пропускаются — они не должны ронять UI.
pub async fn list_modules(dir: String) -> Result<Vec<ModuleInfo>> {
    let mut out = Vec::new();
    let entries = std::fs::read_dir(&dir).with_context(|| format!("не читается каталог {dir}"))?;
    for e in entries.flatten() {
        let path = e.path();
        let ext = path.extension().and_then(|s| s.to_str());
        // Кэш распаковки (`*.sbz.unpacked.sb`) в список не берём.
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !matches!(ext, Some("sb") | Some("sbz")) || name.ends_with(".unpacked.sb") {
            continue;
        }
        if let Ok(m) = open_any(&path) {
            let meta = m.meta();
            out.push(ModuleInfo {
                id: meta.id.clone(),
                title: meta.title.clone(),
                language: meta.language.clone(),
                path: path.to_string_lossy().to_string(),
            });
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(out)
}

/// Документ модуля в формате export.rs, но без глав: `chapters` пуст —
/// их UI подтягивает лениво через [`chapter_doc`].
pub async fn module_doc(path: String) -> Result<String> {
    let m = open_any(Path::new(&path))?;
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

    let doc = json!({
        "id": meta.id,
        "title": meta.title,
        "language": meta.language,
        "versification": meta.versification,
        // ADR 0016: тип и возможности модуля (пусто у старых .sb).
        "kind": meta.kind,
        "features": meta.features,
        "rights": meta.rights,
        "books": books,
        "verse_counts": verse_counts,
        "chapters": {},
    });
    Ok(doc.to_string())
}

/// Глава в формате export.rs: `{"n":..,"blocks":[..]}`.
/// `None`, если такой главы в модуле нет.
pub async fn chapter_doc(path: String, book: String, chapter: i64) -> Result<Option<String>> {
    let m = open_any(Path::new(&path))?;
    let code = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let number = u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?;
    let Some(ch) = m.chapter(code, number)? else {
        return Ok(None);
    };
    let blocks: Vec<Value> = ch.blocks.iter().map(block_json).collect();
    // ADR 0016: критический аппарат главы, если таблица есть.
    let variants: Vec<Value> = m
        .variants(code, number)?
        .iter()
        .map(|v| {
            json!({
                "verse": v.verse,
                "from": v.token_from,
                "to": v.token_to,
                "readings": v.readings.iter().map(|r| json!({
                    "t": r.text,
                    "base": r.is_base,
                    "w": r.witnesses,
                })).collect::<Vec<_>>(),
            })
        })
        .collect();
    Ok(Some(
        json!({"n": ch.number, "blocks": blocks, "variants": variants}).to_string(),
    ))
}

// --- сериализация потока чтения (зеркало export.rs) ---

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

// --- поиск по FTS-индексу модуля ---

/// Результат поиска для UI (зеркало `store::search::Hit`).
pub struct SearchHitInfo {
    pub book: String,
    pub chapter: i64,
    pub verse: i64,
    /// Фрагмент текста с разметкой выделения совпадения.
    pub snippet: String,
}

/// Искать в модуле. `cache_path` — файл индекса рядом с модулем
/// (по соглашению CLI — `<module>.idx`); при несовпадении ключа
/// индекс перестраивается автоматически.
pub async fn module_search(
    module_path: String,
    cache_path: String,
    query: String,
    limit: i64,
) -> Result<Vec<SearchHitInfo>> {
    let m = open_any(Path::new(&module_path))?;
    let idx = studybible_store::SearchIndex::open(Path::new(&cache_path), &m)?;
    let hits = idx.search(&query, usize::try_from(limit).unwrap_or(usize::MAX))?;
    Ok(hits
        .iter()
        .map(|h| SearchHitInfo {
            book: h.book.to_string(),
            chapter: h.chapter.into(),
            verse: h.verse.into(),
            snippet: h.snippet.clone(),
        })
        .collect())
}
