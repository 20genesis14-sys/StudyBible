//! Прогресс чтения через `studybible_store::UserData`.
//!
//! В UserData нет отдельного типа «прогресс», поэтому используем записи
//! с псевдо-модулем `"*"` (у настоящих записей — `meta.id` модуля, так что
//! наши служебные не смешиваются с закладками и заметками пользователя):
//!
//!   * highlight `text="read"`, verse=0 — глава прочитана;
//!   * highlight `text="lv"`, verse=N — последний открытый стих главы;
//!   * mark `text="pos"` — последняя позиция чтения (всегда одна запись).

use std::path::Path;

use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};
use studybible_core::BookCode;
use studybible_store::{Anchor, Entry, Kind, UserData};

/// Псевдо-модуль служебных записей прогресса.
const PROGRESS_MODULE: &str = "*";
const TAG_READ: &str = "read";
const TAG_LAST_VERSE: &str = "lv";
const TAG_POSITION: &str = "pos";

fn anchor<'a>(book: &str, chapter: i64, verse: i64) -> Result<Anchor<'a>> {
    anchor_at(PROGRESS_MODULE, book, chapter, verse)
}

fn anchor_at<'a>(module: &'a str, book: &str, chapter: i64, verse: i64) -> Result<Anchor<'a>> {
    Ok(Anchor {
        module,
        book: BookCode::new(book).ok_or_else(|| anyhow!("код книги {book}"))?,
        chapter: u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?,
        verse: u16::try_from(verse).map_err(|_| anyhow!("стих {verse}"))?,
    })
}

fn open(path: &str) -> Result<UserData> {
    Ok(UserData::open(Path::new(path))?)
}

/// Снять состояние прогресса одним JSON:
/// `{"read":["GEN:1",...], "last_position":"GEN:1"|null, "last_verse":{"GEN:1":5}}`.
pub async fn progress_load(path: String) -> Result<String> {
    let ud = open(&path)?;
    let mut read = Vec::new();
    let mut last_verse = Map::new();
    let mut last_position = Value::Null;

    for e in ud.entries(Kind::Highlight, Some(PROGRESS_MODULE))? {
        if e.verse == 0 && e.text == TAG_READ {
            read.push(Value::from(format!("{}:{}", e.book, e.chapter)));
        } else if e.text == TAG_LAST_VERSE {
            last_verse.insert(format!("{}:{}", e.book, e.chapter), Value::from(e.verse));
        }
    }
    // Позиция одна — берём самую свежую запись, если их несколько.
    let mut pos: Option<(i64, String)> = None;
    for e in ud.entries(Kind::Mark, Some(PROGRESS_MODULE))? {
        if e.text == TAG_POSITION && pos.as_ref().is_none_or(|(u, _)| e.updated >= *u) {
            pos = Some((e.updated, format!("{}:{}", e.book, e.chapter)));
        }
    }
    if let Some((_, p)) = pos {
        last_position = Value::from(p);
    }

    Ok(json!({
        "read": read,
        "last_position": last_position,
        "last_verse": last_verse,
    })
    .to_string())
}

/// Отметить главу прочитанной (повторная отметка — не дубль).
pub async fn progress_mark_read(path: String, book: String, chapter: i64) -> Result<()> {
    let ud = open(&path)?;
    let exists = ud
        .entries(Kind::Highlight, Some(PROGRESS_MODULE))?
        .iter()
        .any(|e| {
            e.text == TAG_READ && e.verse == 0 && e.book == book && e.chapter == chapter as u16
        });
    if !exists {
        ud.add(Kind::Highlight, anchor(&book, chapter, 0)?, TAG_READ, "")?;
    }
    Ok(())
}

/// «Продолжить отсюда»: одна запись-позиция на всю базу.
pub async fn progress_set_position(
    path: String,
    book: String,
    chapter: i64,
    verse: i64,
) -> Result<()> {
    let ud = open(&path)?;
    for e in ud.entries(Kind::Mark, Some(PROGRESS_MODULE))? {
        if e.text == TAG_POSITION {
            ud.remove(&e.id)?;
        }
    }
    ud.add(Kind::Mark, anchor(&book, chapter, verse)?, TAG_POSITION, "")?;
    Ok(())
}

/// Последний открытый стих главы (для автоскролла при возврате).
pub async fn progress_set_verse(
    path: String,
    book: String,
    chapter: i64,
    verse: i64,
) -> Result<()> {
    let ud = open(&path)?;
    for e in ud.entries(Kind::Highlight, Some(PROGRESS_MODULE))? {
        if e.text == TAG_LAST_VERSE && e.book == book && e.chapter == chapter as u16 {
            ud.remove(&e.id)?;
        }
    }
    ud.add(
        Kind::Highlight,
        anchor(&book, chapter, verse)?,
        TAG_LAST_VERSE,
        "",
    )?;
    Ok(())
}

/// Сбросить весь прогресс (кнопка «Сбросить» в настройках).
/// Трогает только служебные записи псевдо-модуля — пользовательские не затрагиваются.
pub async fn progress_reset(path: String) -> Result<()> {
    let ud = open(&path)?;
    for kind in [Kind::Highlight, Kind::Mark, Kind::Note] {
        for e in ud.entries(kind, Some(PROGRESS_MODULE))? {
            ud.remove(&e.id)?;
        }
    }
    Ok(())
}

// --- пользовательские записи (заметки, закладки, выделения к стихам) ---

/// Запись пользователя для UI — `store::Entry` в простых типах,
/// чтобы Dart-сторона не тянула serde_json по каждой записи.
pub struct UserEntryInfo {
    pub id: String,
    /// `meta.id` модуля, к которому привязана запись.
    pub module: String,
    /// `"note" | "mark" | "hl"` (`Kind::as_str`).
    pub kind: String,
    pub book: String,
    pub chapter: i64,
    pub verse: i64,
    /// Текст заметки, подпись закладки или цвет выделения.
    pub text: String,
    /// Контрольный фрагмент стиха для перепривязки при обновлении модуля.
    pub context: String,
    /// Unix-миллисекунды.
    pub created: i64,
    pub updated: i64,
}

fn kind_of(kind: &str) -> Result<Kind> {
    Kind::parse(kind).ok_or_else(|| anyhow!("вид записи {kind}"))
}

fn entry_info(e: &Entry) -> UserEntryInfo {
    UserEntryInfo {
        id: e.id.clone(),
        module: e.module.clone(),
        kind: e.kind.as_str().to_string(),
        book: e.book.to_string(),
        chapter: e.chapter.into(),
        verse: e.verse.into(),
        text: e.text.clone(),
        context: e.context.clone(),
        created: e.created,
        updated: e.updated,
    }
}

/// Записи одного вида; `module: None` — по всем модулям.
pub async fn entries_list(
    path: String,
    kind: String,
    module: Option<String>,
) -> Result<Vec<UserEntryInfo>> {
    let ud = open(&path)?;
    Ok(ud
        .entries(kind_of(&kind)?, module.as_deref())?
        .iter()
        .map(entry_info)
        .collect())
}

/// Добавить запись к стиху модуля; возвращает id записи.
pub async fn entry_add(
    path: String,
    kind: String,
    module: String,
    book: String,
    chapter: i64,
    verse: i64,
    text: String,
    context: String,
) -> Result<String> {
    let ud = open(&path)?;
    Ok(ud.add(
        kind_of(&kind)?,
        anchor_at(&module, &book, chapter, verse)?,
        &text,
        &context,
    )?)
}

/// Обновить текст записи по id (`false` — записи нет).
pub async fn entry_update(path: String, id: String, text: String) -> Result<bool> {
    let ud = open(&path)?;
    Ok(ud.update(&id, &text)?)
}

/// Удалить запись по id (`false` — записи нет).
pub async fn entry_remove(path: String, id: String) -> Result<bool> {
    let ud = open(&path)?;
    Ok(ud.remove(&id)?)
}
