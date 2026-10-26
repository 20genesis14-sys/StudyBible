//! Прогресс чтения через `studybible_store::UserData`.
//!
//! В UserData нет отдельного типа «прогресс», поэтому используем записи
//! с псевдо-модулем `"*"` (у настоящих записей — `meta.id` модуля, так что
//! наши служебные не смешиваются с закладками и заметками пользователя):
//!
//!   * highlight `text="read"`, verse=0 — глава прочитана;
//!   * highlight `text="lv"`, verse=N — последний открытый стих главы;
//!   * mark `text="pos"` — последняя позиция чтения (всегда одна запись).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

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

/// Кэш открытых соединений `userdata.db` (один раз на путь в сессии).
static USERDATA: LazyLock<Mutex<HashMap<PathBuf, Arc<Mutex<UserData>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

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

fn open_cached(path: &str) -> Result<Arc<Mutex<UserData>>> {
    let key = PathBuf::from(path);
    {
        let map = USERDATA
            .lock()
            .map_err(|_| anyhow!("userdata cache poisoned"))?;
        if let Some(u) = map.get(&key) {
            return Ok(u.clone());
        }
    }
    let u = Arc::new(Mutex::new(UserData::open(&key)?));
    USERDATA
        .lock()
        .map_err(|_| anyhow!("userdata cache poisoned"))?
        .insert(key, u.clone());
    Ok(u)
}

fn lock_ud(u: &Mutex<UserData>) -> Result<std::sync::MutexGuard<'_, UserData>> {
    u.lock().map_err(|_| anyhow!("userdata cache poisoned"))
}

/// Путь модуля по `meta.id`: быстрая ветка — файл `<id>.sb`/`.sbz`;
/// иначе скан `modules/` с чтением `meta.id` из каждого файла
/// (имя при импорте могло быть любым — идентичность только в meta).
fn module_path(dir: &Path, id: &str) -> Option<std::path::PathBuf> {
    for ext in ["sbz", "sb"] {
        let p = dir.join(format!("{id}.{ext}"));
        if p.exists() {
            return Some(p);
        }
    }
    module_path_map(dir).get(id).cloned()
}

/// Карта `meta.id` → путь по всем `.sb`/`.sbz` каталога.
fn module_path_map(dir: &Path) -> std::collections::HashMap<String, std::path::PathBuf> {
    let mut map = std::collections::HashMap::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return map;
    };
    for e in rd.flatten() {
        let p = e.path();
        let ext = p.extension().and_then(|x| x.to_str());
        if !matches!(ext, Some("sb" | "sbz")) {
            continue;
        }
        if ext == Some("sbz") && p.with_extension("sb").exists() {
            continue;
        }
        if let Ok(m) = crate::api::module::open_cached(&p)
            && let Ok(g) = crate::api::module::lock_module(&m)
        {
            map.insert(g.meta().id.clone(), p);
        }
    }
    map
}

/// Открыть модуль по `meta.id` в `modules/` рядом с userdata.db
/// через общий кэш `MODULES` (без повторной распаковки `.sbz`).
/// None — служебный псевдомодуль или модуль не установлен.
fn resolve_module(ud_path: &str, id: &str) -> Option<std::sync::Arc<std::sync::Mutex<Module>>> {
    if id.is_empty() || id == PROGRESS_MODULE || id == "settings" {
        return None;
    }
    let dir = Path::new(ud_path).parent()?.join("modules");
    crate::api::module::open_cached(&module_path(&dir, id)?).ok()
}

/// Снять состояние прогресса одним JSON:
/// `{"read":["GEN:1",...], "last_position":"GEN:1"|null, "last_verse":{"GEN:1":5}}`.
pub async fn progress_load(path: String) -> Result<String> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    let mut read = Vec::new();
    let mut last_verse = Map::new();

    for e in ud.entries(Kind::Highlight, Some(PROGRESS_MODULE))? {
        if e.verse == 0 && e.text == TAG_READ {
            read.push(Value::from(format!("{}:{}", e.book, e.chapter)));
        } else if e.text == TAG_LAST_VERSE {
            last_verse.insert(format!("{}:{}", e.book, e.chapter), Value::from(e.verse));
        }
    }
    let last_position = if let Some(p) = ud.meta_get("last_position")? {
        Value::from(p)
    } else {
        // Фоллбэк на старую запись, если есть.
        let mut pos: Option<(i64, String)> = None;
        for e in ud.entries(Kind::Mark, Some(PROGRESS_MODULE))? {
            if e.text == TAG_POSITION && pos.as_ref().is_none_or(|(u, _)| e.updated >= *u) {
                pos = Some((e.updated, format!("{}:{}", e.book, e.chapter)));
            }
        }
        pos.map(|(_, p)| Value::from(p)).unwrap_or(Value::Null)
    };

    Ok(json!({
        "read": read,
        "last_position": last_position,
        "last_verse": last_verse,
    })
    .to_string())
}

/// Отметить главу прочитанной (повторная отметка — не дубль).
pub async fn progress_mark_read(path: String, book: String, chapter: i64) -> Result<()> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
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

/// «Продолжить отсюда»: позиция хранится в `meta('last_position')`.
pub async fn progress_set_position(
    path: String,
    book: String,
    chapter: i64,
    verse: i64,
) -> Result<()> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    ud.meta_set("last_position", &format!("{book}:{chapter}"))?;
    if verse > 0 {
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
    }
    Ok(())
}

/// Последний открытый стих главы (для автоскролла при возврате).
pub async fn progress_set_verse(
    path: String,
    book: String,
    chapter: i64,
    verse: i64,
) -> Result<()> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
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
/// Трогает только служебные записи псевдо-модуля и `meta.last_position`.
pub async fn progress_reset(path: String) -> Result<()> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    ud.meta_remove("last_position")?;
    for kind in [Kind::Highlight, Kind::Mark, Kind::Note] {
        for e in ud.entries(kind, Some(PROGRESS_MODULE))? {
            ud.remove(&e.id)?;
        }
    }
    Ok(())
}

/// Прочитать JSON настроек приложения из `meta('settings')`.
pub async fn settings_load(path: String) -> Result<Option<String>> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.meta_get("settings")?)
}

/// Записать JSON настроек приложения в `meta('settings')`.
pub async fn settings_save(path: String, json: String) -> Result<()> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    ud.meta_set("settings", &json)?;
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
    /// Селектор куска стиха `{exact,pre,post}` (JSON); пусто — весь стих.
    pub frag: String,
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
        frag: e.frag.clone(),
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
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud
        .entries(kind_of(&kind)?, module.as_deref())?
        .iter()
        .map(entry_info)
        .collect())
}

/// Все живые записи пользователя (`hl`, `note`, `mark`, `tag`) одной главы.
pub async fn entries_chapter(
    path: String,
    module: String,
    book: String,
    chapter: i64,
) -> Result<Vec<UserEntryInfo>> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    let b = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let ch = u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?;
    Ok(ud
        .entries_for_chapter(&module, b, ch)?
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
    frag: String,
    created: Option<i64>,
) -> Result<String> {
    let anchor = anchor_at(&module, &book, chapter, verse)?;
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    let k = kind_of(&kind)?;
    // Записи истории ('hist*') и служебные псевдомодули ('*', 'settings', '')
    // не привязываются к тексту стиха — модуль для них не открываем.
    let skip_bind = k == Kind::History || (k == Kind::Mark && text.starts_with("hist"));
    // Метаполя привязки (в.12) берём из кэшированного модуля сами —
    // Dart-стороне их передавать не нужно; у служебного `*` модуля нет,
    // его записи остаются с пустой метой (add() по-прежнему).
    let (bind, ctx) = if skip_bind {
        (Bind::default(), context)
    } else {
        resolve_module(&path, &module)
            .and_then(|arc| {
                let m = crate::api::module::lock_module(&arc).ok()?;
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
                Some((b, c))
            })
            .unwrap_or_else(|| (Bind::default(), context))
    };
    Ok(ud.add_frag(k, anchor, &text, &ctx, &frag, &bind, created)?)
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
    let Some(arc) = resolve_module(&path, &module) else {
        return Ok(vec![]);
    };
    let vrs_name = {
        let m = crate::api::module::lock_module(&arc)?;
        m.meta().versification.clone()
    };
    let vrs =
        Versification::builtin(&vrs_name).ok_or_else(|| anyhow!("версификация «{vrs_name}»"))?;
    let book_c = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let org = vrs.to_org(VerseKey::new(
        book_c,
        u16::try_from(chapter)?,
        u16::try_from(verse)?,
    ));
    // Установленность — по карте meta.id каталога: одно сканирование.
    let dir = Path::new(&path).parent().map(|p| p.join("modules"));
    let installed = dir.map(|d| module_path_map(&d)).unwrap_or_default();
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud
        .entries_foreign(&module, &org, |id| installed.contains_key(id))?
        .iter()
        .map(entry_info)
        .collect())
}

/// Диапазоны фрагмента-селектора в тексте стиха (userdata схема 4):
/// `frag` — JSON `{exact,pre,post}`, возвращаем плоский список
/// байтовых смещений `[s0,e0, s1,e1, …]`. Пустой/битый селектор или
/// отсутствие вхождений — пустой список; UI тогда ничего не красит.
#[flutter_rust_bridge::frb(sync)]
pub fn frag_ranges(text: String, frag: String) -> Vec<i64> {
    #[derive(serde::Deserialize, Default)]
    struct Sel {
        exact: String,
        #[serde(default)]
        pre: String,
        #[serde(default)]
        post: String,
    }
    let s: Sel = serde_json::from_str(&frag).unwrap_or_default();
    studybible_core::frag::find_frag(&text, &s.exact, &s.pre, &s.post)
        .into_iter()
        .flat_map(|(a, b)| [a as i64, b as i64])
        .collect()
}

/// Прогнать перепривязку записей к установленным модулям
/// (`UserData::relink`, в.12); возвращает строку-итог для лога/UI.
#[flutter_rust_bridge::frb(sync)]
pub fn entries_relink(path: String) -> Result<String> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    let dir = Path::new(&path).parent().map(|p| p.join("modules"));
    let paths = dir.map(|d| module_path_map(&d)).unwrap_or_default();
    let s = ud.relink(|id| {
        paths
            .get(id)
            .and_then(|p| crate::api::module::open_any(p).ok())
    })?;
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

/// Id записей-сирот из последнего прогона relink (в.12):
/// для секции «Потерянные» на экране записей.
#[flutter_rust_bridge::frb(sync)]
pub fn orphan_ids(path: String) -> Result<Vec<String>> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.orphan_ids()?)
}

/// Экспорт всех записей в zip (`userdata.json` внутри, spec/06).
pub async fn entries_export(path: String, file: String) -> Result<i64> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.export_zip(Path::new(&file))? as i64)
}

/// Экспорт всех записей в Markdown-файл `file` (только экспорт).
pub async fn entries_export_md(path: String, file: String) -> Result<i64> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.export_markdown(Path::new(&file))? as i64)
}

/// Импорт записей из zip («свежее updated побеждает»); строка-итог.
pub async fn entries_import(path: String, file: String) -> Result<String> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    let s = ud.import_zip(Path::new(&file))?;
    Ok(format!(
        "добавлено {}, обновлено {}, пропущено {}",
        s.added, s.updated, s.skipped
    ))
}

/// Обновить текст записи по id (`false` — записи нет).
pub async fn entry_update(path: String, id: String, text: String) -> Result<bool> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.update(&id, &text)?)
}

/// Удалить запись по id (`false` — записи нет).
pub async fn entry_remove(path: String, id: String) -> Result<bool> {
    let ud = open_cached(&path)?;
    let ud = lock_ud(&ud)?;
    Ok(ud.remove(&id)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_modules_skip_resolution() {
        assert!(resolve_module("/nonexistent/userdata.db", "").is_none());
        assert!(resolve_module("/nonexistent/userdata.db", "*").is_none());
        assert!(resolve_module("/nonexistent/userdata.db", "settings").is_none());
    }
}
