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
use studybible_core::versification::{VerseKey, Versification};
use studybible_store::{Anchor, Bind, Entry, Kind, Module, UserData, canon_range};

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

/// Открыть модуль по `meta.id`: файл `<id>.sb`/`.sbz` в `modules/`
/// рядом с userdata.db. None — модуль не установлен.
fn resolve_module(ud_path: &str, id: &str) -> Option<Module> {
    let dir = Path::new(ud_path).parent()?.join("modules");
    for ext in ["sbz", "sb"] {
        let p = dir.join(format!("{id}.{ext}"));
        if p.exists() {
            return crate::api::module::open_any(&p).ok();
        }
    }
    None
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
#[allow(clippy::too_many_arguments)]
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
    let anchor = anchor_at(&module, &book, chapter, verse)?;
    let ud = open(&path)?;
    // Метаполя привязки (в.12) берём из установленного модуля сами —
    // Dart-стороне их передавать не нужно; у служебного `*` модуля нет,
    // его записи остаются с пустой метой (add() по-прежнему).
    let (bind, ctx) = resolve_module(&path, &module)
        .map(|m| {
            let meta = m.meta();
            let ver = if meta.content_hash.is_empty() {
                meta.version.clone()
            } else {
                meta.content_hash.clone()
            };
            let c = if context.is_empty() {
                m.verse_text(anchor.book, anchor.chapter, anchor.verse)
                    .ok()
                    .flatten()
                    .map(|t| t.chars().take(40).collect::<String>())
                    .unwrap_or_default()
            } else {
                context.clone()
            };
            let canon = Versification::builtin(&meta.versification).and_then(|v| {
                canon_range(v, VerseKey::new(anchor.book, anchor.chapter, anchor.verse))
            });
            let (from, to) = canon.map(|(f, t)| (Some(f), Some(t))).unwrap_or_default();
            let b = Bind {
                vrs: meta.versification.clone(),
                module_ver: ver,
                canon_from: from,
                canon_to: to,
            };
            (b, c)
        })
        .unwrap_or_else(|| (Bind::default(), context));
    Ok(ud.add_ex(kind_of(&kind)?, anchor, &text, &ctx, &bind)?)
}

/// Чужие записи к стиху (в.12, этап А): записи других модулей, чья
/// каноническая координата пересекает стих текущего модуля в сетке org.
/// По решению пользователя — только записи установленных модулей;
/// `module` не установлен → пустой список.
pub async fn entries_foreign_list(
    path: String,
    module: String,
    book: String,
    chapter: i64,
    verse: i64,
) -> Result<Vec<UserEntryInfo>> {
    let Some(m) = resolve_module(&path, &module) else {
        return Ok(vec![]);
    };
    let vrs = Versification::builtin(&m.meta().versification)
        .ok_or_else(|| anyhow!("версификация «{}»", m.meta().versification))?;
    let book_c = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let org = vrs.to_org(VerseKey::new(
        book_c,
        u16::try_from(chapter)?,
        u16::try_from(verse)?,
    ));
    // Кэш установленности: файл модуля открываем один раз на id.
    let mut seen = std::collections::HashMap::<String, bool>::new();
    let ud = open(&path)?;
    Ok(ud
        .entries_foreign(&module, &org, |id| {
            *seen
                .entry(id.to_string())
                .or_insert_with(|| resolve_module(&path, id).is_some())
        })?
        .iter()
        .map(entry_info)
        .collect())
}

/// Прогнать перепривязку записей к установленным модулям
/// (`UserData::relink`, в.12); возвращает строку-итог для лога/UI.
#[flutter_rust_bridge::frb(sync)]
pub fn entries_relink(path: String) -> Result<String> {
    let ud = open(&path)?;
    let s = ud.relink(|id| resolve_module(&path, id))?;
    Ok(format!(
        "проверено {}, свежих {}, переписано меты {}, переехало {}, \
         сирот {} [{}], пропущено {}",
        s.checked,
        s.fresh,
        s.stamped,
        s.moved,
        s.orphaned.len(),
        s.orphaned.join(", "),
        s.skipped
    ))
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
