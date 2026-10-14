//! Пользовательская база: закладки, выделения, заметки (ADR 0008).
//!
//! Отдельная SQLite с версией схемы. Удаление — надгробие (`deleted`), чтобы при
//! слиянии архивов удаление побеждало старую запись; слияние — «побеждает свежее
//! `updated`». Экспорт — zip с `userdata.json`.

use std::fmt;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use studybible_core::BookCode;
use studybible_core::versification::{VerseKey, Versification};

/// Схема 2 (08.10.2026, вопрос №12): + колонки `vrs` (версификация
/// модуля на момент записи) и `module_ver` (content_hash, иначе
/// version) — основа перепривязки при обновлении модуля.
/// Схема 3 (там же, этап А): + `canon_book`, `canon_c1`, `canon_v1`,
/// `canon_c2`, `canon_v2` — канонический диапазон стиха в сетке org
/// для кросс-переводных записей.
/// Схема 4: + `frag` — текстовый селектор куска стиха
/// `{exact,pre,post}` (JSON); пусто = запись на весь стих.
const SCHEMA_VERSION: &str = "4";

#[derive(Debug)]
pub enum UserError {
    Sqlite(rusqlite::Error),
    Io(std::io::Error),
    Zip(zip::result::ZipError),
    BadFormat(String),
}

impl fmt::Display for UserError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(e) => write!(f, "SQLite: {e}"),
            Self::Io(e) => write!(f, "ввод-вывод: {e}"),
            Self::Zip(e) => write!(f, "zip: {e}"),
            Self::BadFormat(s) => write!(f, "не архив пользовательских данных: {s}"),
        }
    }
}

impl std::error::Error for UserError {}

impl From<rusqlite::Error> for UserError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Sqlite(e)
    }
}
impl From<std::io::Error> for UserError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<zip::result::ZipError> for UserError {
    fn from(e: zip::result::ZipError) -> Self {
        Self::Zip(e)
    }
}

type Result<T> = std::result::Result<T, UserError>;

/// Вид пользовательской записи.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// Заметка (`text` — текст).
    Note,
    /// Закладка (`text` — подпись, может быть пустой).
    Mark,
    /// Выделение (`text` — цвет, например `yellow`).
    Highlight,
    /// Теги стиха (`text` — имена через запятую; одна запись на стих).
    Tag,
    /// Элемент сквозной истории переходов/поиска/словаря (`text` — `hist*`).
    #[serde(rename = "hist")]
    History,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Note => "note",
            Self::Mark => "mark",
            Self::Highlight => "hl",
            Self::Tag => "tag",
            Self::History => "hist",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "note" => Some(Self::Note),
            "mark" => Some(Self::Mark),
            "hl" | "highlight" => Some(Self::Highlight),
            "tag" => Some(Self::Tag),
            "hist" | "history" => Some(Self::History),
            _ => None,
        }
    }
}

/// Якорь записи: id модуля + стиховая координата (ADR 0004).
#[derive(Copy, Clone, Debug)]
pub struct Anchor<'a> {
    /// `meta.id` модуля.
    pub module: &'a str,
    pub book: BookCode,
    pub chapter: u16,
    pub verse: u16,
}

/// Одна запись: якорь — стиховая координата + id модуля (ADR 0004).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// `meta.id` модуля.
    pub module: String,
    pub kind: Kind,
    pub book: String,
    pub chapter: u16,
    pub verse: u16,
    /// Текст заметки, подпись закладки или цвет выделения.
    pub text: String,
    /// Контрольный фрагмент текста стиха для перепривязки при обновлении модуля.
    #[serde(default)]
    pub context: String,
    /// Unix-миллисекунды.
    pub created: i64,
    pub updated: i64,
    /// Unix-миллисекунды удаления; 0 — живая. Надгробие нужно слиянию архивов.
    #[serde(default)]
    pub deleted: i64,
    /// Id устройства/базы, где запись правилась последний раз.
    #[serde(default)]
    pub device: String,
    /// Номер ревизии записи, растёт при каждой правке.
    #[serde(default)]
    pub rev: u32,
    /// Версификация модуля на момент записи (`rsc`, `org`…).
    /// Пусто у записей схемы 1 — перепривязка их пропускает проверку.
    #[serde(default)]
    pub vrs: String,
    /// `meta.content_hash` модуля (иначе `version`) на момент записи:
    /// смена значения = модуль обновился → запись надо перепроверить.
    #[serde(default)]
    pub module_ver: String,
    /// Канонический диапазон стиха в сетке org (этап А, схема 3):
    /// `canon_book`+`canon_c1`:`canon_v1` — `canon_c2`:`canon_v2`.
    /// Текстовый селектор куска стиха `{exact,pre,post}` в JSON
    /// (схема 4): частичное выделение/привязка к фразе.
    /// Пусто — запись относится ко всему стиху.
    #[serde(default)]
    pub frag: String,
    /// Пустой `canon_book` — координата не записана (старые записи).
    #[serde(default)]
    pub canon_book: String,
    #[serde(default)]
    pub canon_ch1: u16,
    #[serde(default)]
    pub canon_v1: u16,
    #[serde(default)]
    pub canon_ch2: u16,
    #[serde(default)]
    pub canon_v2: u16,
}

/// Мета привязки записи к модулю, пишется при создании (в.12).
#[derive(Debug, Default, Clone)]
pub struct Bind {
    /// `meta.versification` модуля.
    pub vrs: String,
    /// `meta.content_hash` (иначе `version`).
    pub module_ver: String,
    /// Канонический диапазон org стиха якоря (этап А).
    pub canon_from: Option<VerseKey>,
    pub canon_to: Option<VerseKey>,
}

/// Канонический диапазон org стиха `k` в версификации `vrs`:
/// крайние точки списка `to_org`. None — стиха в org нет.
pub fn canon_range(vrs: &Versification, k: VerseKey) -> Option<(VerseKey, VerseKey)> {
    let org = vrs.to_org(k);
    Some((*org.iter().min()?, *org.iter().max()?))
}

#[derive(Debug, Default)]
pub struct ImportStats {
    pub added: usize,
    pub updated: usize,
    pub skipped: usize,
}

pub struct UserData {
    conn: Connection,
    /// Уникальный id этой базы (устройства); живёт в `meta`.
    device: String,
}

static SEQ: AtomicU32 = AtomicU32::new(0);

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// `дд.мм.гггг` из unix-millis (алгоритм civil-from-days Хиннанта).
fn date_ymd(ms: i64) -> String {
    let z = ms.div_euclid(86_400_000) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{d:02}.{m:02}.{y}")
}

fn new_id() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    format!("{ms:013x}{:05x}", SEQ.fetch_add(1, Ordering::Relaxed))
}

impl UserData {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS entries(
                 id TEXT PRIMARY KEY,
                 module TEXT NOT NULL,
                 kind TEXT NOT NULL,
                 book TEXT NOT NULL,
                 chapter INTEGER NOT NULL,
                 verse INTEGER NOT NULL,
                 text TEXT NOT NULL DEFAULT '',
                 context TEXT NOT NULL DEFAULT '',
                 created INTEGER NOT NULL,
                 updated INTEGER NOT NULL,
                 deleted INTEGER NOT NULL DEFAULT 0,
                 device TEXT NOT NULL DEFAULT '',
                 rev INTEGER NOT NULL DEFAULT 1,
                 vrs TEXT NOT NULL DEFAULT '',
                 module_ver TEXT NOT NULL DEFAULT '',
                 canon_book TEXT NOT NULL DEFAULT '',
                 canon_c1 INTEGER NOT NULL DEFAULT 0,
                 canon_v1 INTEGER NOT NULL DEFAULT 0,
                 canon_c2 INTEGER NOT NULL DEFAULT 0,
                 canon_v2 INTEGER NOT NULL DEFAULT 0,
                 frag TEXT NOT NULL DEFAULT '');
             CREATE INDEX IF NOT EXISTS entries_anchor ON entries(module, book, chapter, verse);",
        )?;
        let v: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key='schema'", [], |r| {
                r.get(0)
            })
            .optional()?;
        match v.as_deref() {
            None => conn.execute(
                "INSERT INTO meta VALUES('schema', ?1)",
                params![SCHEMA_VERSION],
            )?,
            Some(SCHEMA_VERSION) => 0,
            // Миграция 1→3 / 2→3: поля перепривязки и канонического
            // диапазона добавляются пустыми, затем canon восполняется
            // по записанной `vrs` у всех живых записей.
            // Миграция 1→3: поля перепривязки и канонического
            // диапазона добавляются пустыми, затем canon восполняется
            // по записанной `vrs` у всех живых записей.
            Some("1") => {
                conn.execute_batch(
                    "ALTER TABLE entries ADD COLUMN vrs TEXT NOT NULL DEFAULT '';
                     ALTER TABLE entries ADD COLUMN module_ver TEXT NOT NULL DEFAULT '';
                     ALTER TABLE entries ADD COLUMN canon_book TEXT NOT NULL DEFAULT '';
                     ALTER TABLE entries ADD COLUMN canon_c1 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_v1 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_c2 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_v2 INTEGER NOT NULL DEFAULT 0;
                     UPDATE meta SET value='3' WHERE key='schema';",
                )?;
                backfill_canon(&conn)?;
                0
            }
            // Миграция 2→3: только канонический диапазон.
            Some("2") => {
                conn.execute_batch(
                    "ALTER TABLE entries ADD COLUMN canon_book TEXT NOT NULL DEFAULT '';
                     ALTER TABLE entries ADD COLUMN canon_c1 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_v1 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_c2 INTEGER NOT NULL DEFAULT 0;
                     ALTER TABLE entries ADD COLUMN canon_v2 INTEGER NOT NULL DEFAULT 0;
                     UPDATE meta SET value='3' WHERE key='schema';",
                )?;
                backfill_canon(&conn)?;
                0
            }
            Some(other) => {
                return Err(UserError::BadFormat(format!("схема {other}")));
            }
        };
        // Миграция 3→4: текстовый селектор куска стиха.
        let v2: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key='schema'", [], |r| {
                r.get(0)
            })
            .optional()?;
        if v2.as_deref() == Some("3") {
            conn.execute_batch(
                "ALTER TABLE entries ADD COLUMN frag TEXT NOT NULL DEFAULT '';
                 UPDATE meta SET value='4' WHERE key='schema';",
            )?;
        }
        let device: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key='device'", [], |r| {
                r.get(0)
            })
            .optional()?;
        let device = match device {
            Some(d) => d,
            None => {
                let d = new_id();
                conn.execute("INSERT INTO meta VALUES('device', ?1)", params![d])?;
                d
            }
        };
        // Автомиграция служебных записей (14.10.2026, Группа 1):
        // 1) старые записи истории kind='mark' с text LIKE 'hist%' → kind='hist';
        // 2) настройки из entries(module='settings', book='SET') → meta('settings');
        // 3) последняя позиция из entries(module='*', text='pos') → meta('last_position').
        conn.execute(
            "UPDATE entries SET kind='hist' WHERE kind='mark' AND text LIKE 'hist%'",
            [],
        )?;
        let legacy_settings: Option<String> = conn
            .query_row(
                "SELECT context FROM entries
                 WHERE kind='mark' AND module='settings' AND book='SET' AND deleted=0
                 ORDER BY updated DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(ctx) = legacy_settings {
            let has_meta: Option<String> = conn
                .query_row("SELECT value FROM meta WHERE key='settings'", [], |r| {
                    r.get(0)
                })
                .optional()?;
            if has_meta.is_none() && !ctx.is_empty() {
                conn.execute(
                    "INSERT OR REPLACE INTO meta VALUES('settings', ?1)",
                    params![ctx],
                )?;
            }
            conn.execute(
                "UPDATE entries SET deleted=?1 WHERE kind='mark' AND module='settings' AND book='SET' AND deleted=0",
                params![now()],
            )?;
        }
        let legacy_pos: Option<(String, u16)> = conn
            .query_row(
                "SELECT book, chapter FROM entries
                 WHERE kind='mark' AND module='*' AND text='pos' AND deleted=0
                 ORDER BY updated DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((b, ch)) = legacy_pos {
            let has_pos: Option<String> = conn
                .query_row(
                    "SELECT value FROM meta WHERE key='last_position'",
                    [],
                    |r| r.get(0),
                )
                .optional()?;
            if has_pos.is_none() {
                conn.execute(
                    "INSERT OR REPLACE INTO meta VALUES('last_position', ?1)",
                    params![format!("{b}:{ch}")],
                )?;
            }
            conn.execute(
                "UPDATE entries SET deleted=?1 WHERE kind='mark' AND module='*' AND text='pos' AND deleted=0",
                params![now()],
            )?;
        }
        Ok(Self { conn, device })
    }

    /// Прочитать значение из таблицы `meta` (`settings`, `last_position` и др.).
    pub fn meta_get(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM meta WHERE key=?1", params![key], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// Записать значение в таблицу `meta`.
    pub fn meta_set(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO meta VALUES(?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }

    /// Удалить ключ из таблицы `meta`.
    pub fn meta_remove(&self, key: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM meta WHERE key=?1", params![key])?;
        Ok(())
    }

    /// Добавить запись; возвращает её id. `text` — текст заметки, подпись или цвет;
    /// `context` — контрольный фрагмент стиха для перепривязки (может быть пустым).
    /// Происхождение модуля не пишется — см. [`Self::add_ex`].
    pub fn add(&self, kind: Kind, anchor: Anchor<'_>, text: &str, context: &str) -> Result<String> {
        self.add_ex(kind, anchor, text, context, &Bind::default())
    }

    /// `add` + мета модуля [`Bind`]: версификация, идентичность модуля
    /// и канонический диапазон org. Мост и CLI должны писать их
    /// всегда — иначе перепривязке и кросс-записям не на что
    /// опереться (вопрос №12).
    pub fn add_ex(
        &self,
        kind: Kind,
        anchor: Anchor<'_>,
        text: &str,
        context: &str,
        bind: &Bind,
    ) -> Result<String> {
        self.add_frag(kind, anchor, text, context, "", bind, None)
    }

    /// `add_ex` + селектор куска стиха и метка пачки:
    /// `frag` — `{exact,pre,post}` (JSON, пусто — весь стих);
    /// `created` — общее время группы записей одного действия
    /// (многостишное выделение), None = сейчас.
    #[allow(clippy::too_many_arguments)]
    pub fn add_frag(
        &self,
        kind: Kind,
        anchor: Anchor<'_>,
        text: &str,
        context: &str,
        frag: &str,
        bind: &Bind,
        created: Option<i64>,
    ) -> Result<String> {
        let id = new_id();
        let t = created.unwrap_or_else(now);
        let (cb, c1, v1, c2, v2) = match (bind.canon_from, bind.canon_to) {
            (Some(f), Some(to)) => (
                f.book.as_str().to_string(),
                f.chapter,
                f.verse,
                to.chapter,
                to.verse,
            ),
            _ => (String::new(), 0, 0, 0, 0),
        };
        self.conn.execute(
            "INSERT INTO entries VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,0,?11,1,?12,?13,?14,?15,?16,?17,?18,?19)",
            params![
                id,
                anchor.module,
                kind.as_str(),
                anchor.book.as_str(),
                anchor.chapter,
                anchor.verse,
                text,
                context,
                t,
                t,
                self.device,
                bind.vrs,
                bind.module_ver,
                cb,
                c1,
                v1,
                c2,
                v2,
                frag,
            ],
        )?;
        Ok(id)
    }

    /// Живые записи вида `kind`; `module` — фильтр по модулю.
    /// При `module: None` служебные псевдомодули (`*`, `settings`) исключаются.
    pub fn entries(&self, kind: Kind, module: Option<&str>) -> Result<Vec<Entry>> {
        let sql = "SELECT id, module, kind, book, chapter, verse, text, context,
                   created, updated, deleted, device, rev, vrs, module_ver,
                   canon_book, canon_c1, canon_v1, canon_c2, canon_v2, frag
                   FROM entries
                   WHERE kind=?1 AND deleted=0";
        let rows: Vec<Entry> = match module {
            Some(m) => self
                .conn
                .prepare(&format!(
                    "{sql} AND module=?2 ORDER BY book, chapter, verse"
                ))?
                .query_map(params![kind.as_str(), m], row_to_entry)?
                .collect::<rusqlite::Result<_>>()?,
            None => self
                .conn
                .prepare(&format!(
                    "{sql} AND module != '*' AND module != 'settings' ORDER BY module, book, chapter, verse"
                ))?
                .query_map(params![kind.as_str()], row_to_entry)?
                .collect::<rusqlite::Result<_>>()?,
        };
        Ok(rows)
    }

    /// Все живые пользовательские записи (`hl`, `note`, `mark`, `tag`) одной главы
    /// по индексу `entries_anchor(module, book, chapter, verse)`.
    pub fn entries_for_chapter(
        &self,
        module: &str,
        book: BookCode,
        chapter: u16,
    ) -> Result<Vec<Entry>> {
        self.conn
            .prepare(
                "SELECT id, module, kind, book, chapter, verse, text, context,
                 created, updated, deleted, device, rev, vrs, module_ver,
                 canon_book, canon_c1, canon_v1, canon_c2, canon_v2, frag
                 FROM entries
                 WHERE module=?1 AND book=?2 AND chapter=?3
                   AND deleted=0 AND kind IN ('hl','note','mark','tag')
                 ORDER BY verse, created",
            )?
            .query_map(params![module, book.as_str(), chapter], row_to_entry)?
            .collect::<rusqlite::Result<_>>()
            .map_err(Into::into)
    }

    /// Надгробие: запись помечается удалённой и остаётся в базе для слияния.
    pub fn remove(&self, id: &str) -> Result<bool> {
        let t = now();
        Ok(self.conn.execute(
            "UPDATE entries SET deleted=?1, updated=?1, rev=rev+1, device=?2 WHERE id=?3",
            params![t, self.device, id],
        )? > 0)
    }

    /// Обновить текст записи (заметки, подписи, цвета) — `updated` становится текущим.
    pub fn update(&self, id: &str, text: &str) -> Result<bool> {
        Ok(self.conn.execute(
            "UPDATE entries SET text=?1, updated=?2, rev=rev+1, device=?3 \
             WHERE id=?4 AND deleted=0",
            params![text, now(), self.device, id],
        )? > 0)
    }

    /// Все записи, включая надгробия — для экспорта и слияния.
    fn all(&self) -> Result<Vec<Entry>> {
        self.conn
            .prepare(
                "SELECT id, module, kind, book, chapter, verse, text, context,
                 created, updated, deleted, device, rev, vrs, module_ver,
                 canon_book, canon_c1, canon_v1, canon_c2, canon_v2, frag
                 FROM entries",
            )?
            .query_map([], row_to_entry)?
            .collect::<rusqlite::Result<_>>()
            .map_err(Into::into)
    }

    /// Экспорт в zip: один файл `userdata.json` (без сжатия — файлы и так мелкие).
    pub fn export_zip(&self, path: &Path) -> Result<usize> {
        let entries = self.all()?;
        let doc = serde_json::json!({
            "format": "studybible-userdata",
            "version": SCHEMA_VERSION,
            "entries": entries,
        });
        let f = std::fs::File::create(path)?;
        let mut zip = zip::ZipWriter::new(f);
        let opt = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file("userdata.json", opt)?;
        zip.write_all(serde_json::to_string_pretty(&doc).expect("json").as_bytes())?;
        zip.finish()?;
        Ok(entries.len())
    }

    /// Экспорт живых записей в Markdown (только экспорт, без импорта —
    /// spec/06). Группировка: модуль → вид записи; сироты/удалённые
    /// не выгружаются. Служебный псевдо-модуль `*` пропускается.
    pub fn export_markdown(&self, path: &Path) -> Result<usize> {
        let mut entries: Vec<Entry> = self
            .all()?
            .into_iter()
            .filter(|e| {
                e.deleted == 0
                    && e.module != "*"
                    && e.module != "settings"
                    && e.kind != Kind::History
            })
            .collect();
        entries.sort_by(|a, b| {
            (&a.module, a.kind.as_str(), &a.book, a.chapter, a.verse).cmp(&(
                &b.module,
                b.kind.as_str(),
                &b.book,
                b.chapter,
                b.verse,
            ))
        });
        const KIND_TITLE: [(&str, &str); 4] = [
            ("note", "Заметки"),
            ("mark", "Закладки"),
            ("hl", "Выделения"),
            ("tag", "Теги"),
        ];
        let mut out = String::from("# Записи StudyBible\n\n");
        let (mut module, mut kind) = (String::new(), String::new());
        for e in &entries {
            if e.module != module {
                module = e.module.clone();
                kind.clear();
                out.push_str(&format!("## {module}\n\n"));
            }
            if e.kind.as_str() != kind {
                kind = e.kind.as_str().to_string();
                let t = KIND_TITLE
                    .iter()
                    .find(|(k, _)| *k == kind)
                    .map(|(_, t)| *t)
                    .unwrap_or(kind.as_str());
                out.push_str(&format!("### {t}\n\n"));
            }
            let date = date_ymd(e.created);
            let text = if e.text.is_empty() {
                String::new()
            } else {
                format!(" — {}", e.text.replace('\n', " "))
            };
            out.push_str(&format!(
                "- **{} {}:{}**{text} *({date})*\n",
                e.book, e.chapter, e.verse
            ));
        }
        std::fs::write(path, out)?;
        Ok(entries.len())
    }

    /// Импорт zip: слияние «побеждает свежее updated»; надгробия применяются.
    pub fn import_zip(&self, path: &Path) -> Result<ImportStats> {
        let f = std::fs::File::open(path)?;
        let mut zip = zip::ZipArchive::new(f)?;
        let mut buf = String::new();
        zip.by_name("userdata.json")
            .map_err(|_| UserError::BadFormat("нет userdata.json".into()))?
            .read_to_string(&mut buf)?;
        let doc: serde_json::Value =
            serde_json::from_str(&buf).map_err(|e| UserError::BadFormat(e.to_string()))?;
        if doc.get("format").and_then(|v| v.as_str()) != Some("studybible-userdata") {
            return Err(UserError::BadFormat("format".into()));
        }
        // Принимаем выгрузки схем 1–3: новые поля имеют serde-default.
        match doc.get("version").and_then(|v| v.as_str()) {
            Some("1") | Some("2") | Some("3") | Some(SCHEMA_VERSION) => {}
            _ => return Err(UserError::BadFormat("version".into())),
        }
        let mut stats = ImportStats::default();
        let empty = Vec::new();
        let list = doc
            .get("entries")
            .and_then(|v| v.as_array())
            .unwrap_or(&empty);
        for v in list {
            let e: Entry = serde_json::from_value(v.clone())
                .map_err(|e| UserError::BadFormat(e.to_string()))?;
            match self.merge(&e)? {
                Merge::Added => stats.added += 1,
                Merge::Updated => stats.updated += 1,
                Merge::Skipped => stats.skipped += 1,
            }
        }
        Ok(stats)
    }

    /// Одна запись слияния: свежее `updated` побеждает.
    fn merge(&self, e: &Entry) -> Result<Merge> {
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT updated FROM entries WHERE id=?1",
                params![e.id],
                |r| r.get(0),
            )
            .optional()?;
        match existing {
            None => {
                self.conn.execute(
                    "INSERT INTO entries VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)",
                    params![
                        e.id,
                        e.module,
                        e.kind.as_str(),
                        e.book,
                        e.chapter,
                        e.verse,
                        e.text,
                        e.context,
                        e.created,
                        e.updated,
                        e.deleted,
                        e.device,
                        e.rev,
                        e.vrs,
                        e.module_ver,
                        e.canon_book,
                        e.canon_ch1,
                        e.canon_v1,
                        e.canon_ch2,
                        e.canon_v2,
                        e.frag,
                    ],
                )?;
                Ok(Merge::Added)
            }
            Some(u) if e.updated > u => {
                self.conn.execute(
                    "UPDATE entries SET module=?2,kind=?3,book=?4,chapter=?5,verse=?6,
                     text=?7,context=?8,created=?9,updated=?10,deleted=?11,
                     device=?12,rev=?13,vrs=?14,module_ver=?15,
                     canon_book=?16,canon_c1=?17,canon_v1=?18,
                     canon_c2=?19,canon_v2=?20,frag=?21 WHERE id=?1",
                    params![
                        e.id,
                        e.module,
                        e.kind.as_str(),
                        e.book,
                        e.chapter,
                        e.verse,
                        e.text,
                        e.context,
                        e.created,
                        e.updated,
                        e.deleted,
                        e.device,
                        e.rev,
                        e.vrs,
                        e.module_ver,
                        e.canon_book,
                        e.canon_ch1,
                        e.canon_v1,
                        e.canon_ch2,
                        e.canon_v2,
                        e.frag,
                    ],
                )?;
                Ok(Merge::Updated)
            }
            _ => Ok(Merge::Skipped),
        }
    }
}

enum Merge {
    Added,
    Updated,
    Skipped,
}

/// Итог перепривязки записей к модулям (`user relink`, вопрос №12).
#[derive(Debug, Default)]
pub struct RelinkStats {
    /// Записей проверено (модуль установлен).
    pub checked: usize,
    /// `vrs`/`module_ver` совпали и якорь на месте.
    pub fresh: usize,
    /// Метаполя обновлены (модуль сменился, якорь подтверждён
    /// контекстом — или контекст отсутствовал и был восполнен из
    /// текущего текста стиха).
    pub stamped: usize,
    /// Якорь переехал по контексту в соседний стих (±2).
    pub moved: usize,
    /// Контекст не нашёлся нигде — запись не тронута, id в списке.
    pub orphaned: Vec<String>,
    /// Модуль записи не установлен — запись пропущена.
    pub skipped: usize,
}

impl UserData {
    /// Проверка и перепривязка живых записей к установленным модулям.
    ///
    /// `resolve(id)` открывает модуль по `meta.id` (None — модуля нет,
    /// запись пропускается). Логика (вопрос №12, этап Б):
    /// мета записи совпадает с модулем — свежая; модуль сменился —
    /// ищем `context` в якорном стихе, затем в ±2 стихах (нашли —
    /// переезжаем, не нашли — сирота). Записи без контекста получают
    /// фрагмент текущего стиха: перепривязать их нечем, а опора для
    /// будущих проверок появляется.
    pub fn relink(
        &self,
        mut resolve: impl FnMut(&str) -> Option<crate::module::Module>,
    ) -> Result<RelinkStats> {
        let mut stats = RelinkStats::default();
        let mut mods: std::collections::HashMap<String, Option<crate::module::Module>> =
            std::collections::HashMap::new();
        for e in self.all()? {
            if e.deleted != 0
                || e.module == "*"
                || e.module == "settings"
                || e.kind == Kind::History
            {
                continue;
            }
            let m = match mods.entry(e.module.clone()) {
                std::collections::hash_map::Entry::Occupied(en) => en.into_mut(),
                std::collections::hash_map::Entry::Vacant(en) => en.insert(resolve(&e.module)),
            };
            let Some(m) = m.as_ref() else {
                stats.skipped += 1;
                continue;
            };
            stats.checked += 1;
            let meta = m.meta();
            let cur_vrs = meta.versification.as_str();
            let cur_ver = if meta.content_hash.is_empty() {
                meta.version.as_str()
            } else {
                meta.content_hash.as_str()
            };
            // «Свежая» — мета совпала и все поля на месте; пустой канон
            // (проштамповано до этапа А или без конверсии) доукомплектовываем.
            if e.vrs == cur_vrs
                && e.module_ver == cur_ver
                && !e.context.is_empty()
                && !e.canon_book.is_empty()
            {
                stats.fresh += 1;
                continue;
            }
            let Some(book) = BookCode::new(&e.book) else {
                stats.orphaned.push(e.id.clone());
                continue;
            };
            let verse_text = |v: u16| {
                m.verse_text(book, e.chapter, v)
                    .ok()
                    .flatten()
                    .unwrap_or_default()
            };
            // Канонический диапазон считаем от якоря в сетке модуля.
            let canon = |verse: u16| {
                Versification::builtin(cur_vrs)
                    .and_then(|v| canon_range(v, VerseKey::new(book, e.chapter, verse)))
            };
            let stamp = |ctx: &str| {
                let (cb, c1, v1, c2, v2) = canon(e.verse)
                    .map(|(f, t)| {
                        (
                            f.book.as_str().to_string(),
                            f.chapter,
                            f.verse,
                            t.chapter,
                            t.verse,
                        )
                    })
                    .unwrap_or((String::new(), 0, 0, 0, 0));
                self.conn.execute(
                    "UPDATE entries SET vrs=?2, module_ver=?3, context=?4, \
                     canon_book=?5,canon_c1=?6,canon_v1=?7,canon_c2=?8,canon_v2=?9, \
                     updated=?10, device=?11 WHERE id=?1",
                    params![
                        e.id,
                        cur_vrs,
                        cur_ver,
                        ctx,
                        cb,
                        c1,
                        v1,
                        c2,
                        v2,
                        now(),
                        self.device
                    ],
                )
            };
            let t = now();
            if e.context.is_empty() {
                // Контекста нет — записать фрагмент текущего стиха.
                let frag: String = verse_text(e.verse).chars().take(40).collect();
                stamp(&frag)?;
                stats.stamped += 1;
                continue;
            }
            if verse_text(e.verse).contains(&e.context) {
                stamp(&e.context)?;
                stats.stamped += 1;
                continue;
            }
            // Поиск в соседних стихах той же главы.
            let mut hit = None;
            for dv in -2i32..=2 {
                if dv == 0 {
                    continue;
                }
                let nv = e.verse as i32 + dv;
                if nv < 1 {
                    continue;
                }
                if verse_text(nv as u16).contains(&e.context) {
                    hit = Some(nv as u16);
                    break;
                }
            }
            match hit {
                Some(nv) => {
                    let (cb, c1, v1, c2, v2) = canon(nv)
                        .map(|(f, t)| {
                            (
                                f.book.as_str().to_string(),
                                f.chapter,
                                f.verse,
                                t.chapter,
                                t.verse,
                            )
                        })
                        .unwrap_or((String::new(), 0, 0, 0, 0));
                    self.conn.execute(
                        "UPDATE entries SET verse=?2, vrs=?3, module_ver=?4, \
                         canon_book=?5,canon_c1=?6,canon_v1=?7,canon_c2=?8,canon_v2=?9, \
                         updated=?10, rev=rev+1, device=?11 WHERE id=?1",
                        params![
                            e.id,
                            nv,
                            cur_vrs,
                            cur_ver,
                            cb,
                            c1,
                            v1,
                            c2,
                            v2,
                            t,
                            self.device
                        ],
                    )?;
                    stats.moved += 1;
                }
                None => stats.orphaned.push(e.id.clone()),
            }
        }
        // Сироты прогона — в meta (секция «Потерянные» в UI);
        // каждый прогон перезаписывает список.
        self.conn.execute(
            "INSERT OR REPLACE INTO meta VALUES('orphans', ?1)",
            params![serde_json::to_string(&stats.orphaned).expect("json")],
        )?;
        Ok(stats)
    }

    /// Id записей-сирот из последнего прогона `relink` (модуль
    /// существует, но якорного стиха/контекста в нём больше нет).
    pub fn orphan_ids(&self) -> Result<Vec<String>> {
        let s: Option<String> = self
            .conn
            .query_row("SELECT value FROM meta WHERE key='orphans'", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(s.and_then(|j| serde_json::from_str(&j).ok())
            .unwrap_or_default())
    }

    /// Живые записи **других** модулей, чей канонический диапазон org
    /// содержит хотя бы один из `org_keys` (ключи стиха текущего
    /// модуля в сетке org — `vrs.to_org`). `installed(meta.id)`
    /// отсекает записи к неустановленным модулям — по решению они
    /// видны только во вкладке «Записи» (в.12, этап А).
    pub fn entries_foreign(
        &self,
        module: &str,
        org_keys: &[VerseKey],
        mut installed: impl FnMut(&str) -> bool,
    ) -> Result<Vec<Entry>> {
        if org_keys.is_empty() {
            return Ok(vec![]);
        }
        let mut out = Vec::new();
        for e in self.all()? {
            if e.deleted != 0
                || e.module == module
                || e.module == "*"
                || e.module == "settings"
                || e.kind == Kind::History
                || e.canon_book.is_empty()
            {
                continue;
            }
            if !installed(&e.module) {
                continue;
            }
            let hit = org_keys.iter().any(|k| {
                k.book.as_str() == e.canon_book
                    && (e.canon_ch1, e.canon_v1) <= (k.chapter, k.verse)
                    && (k.chapter, k.verse) <= (e.canon_ch2, e.canon_v2)
            });
            if hit {
                out.push(e);
            }
        }
        Ok(out)
    }
}

fn row_to_entry(r: &rusqlite::Row) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: r.get(0)?,
        module: r.get(1)?,
        kind: Kind::parse(&r.get::<_, String>(2)?).unwrap_or(Kind::Note),
        book: r.get(3)?,
        chapter: r.get(4)?,
        verse: r.get(5)?,
        text: r.get(6)?,
        context: r.get(7)?,
        created: r.get(8)?,
        updated: r.get(9)?,
        deleted: r.get(10)?,
        device: r.get(11)?,
        rev: r.get(12)?,
        vrs: r.get(13)?,
        module_ver: r.get(14)?,
        canon_book: r.get(15)?,
        canon_ch1: r.get(16)?,
        canon_v1: r.get(17)?,
        canon_ch2: r.get(18)?,
        canon_v2: r.get(19)?,
        frag: r.get(20)?,
    })
}

/// Восполнить канонический диапазон у живых записей с известной `vrs`
/// (миграция на схему 3; записи без `vrs` получают диапазон позже
/// через relink).
fn backfill_canon(conn: &Connection) -> Result<()> {
    let mut st = conn
        .prepare("SELECT id, book, chapter, verse, vrs FROM entries WHERE deleted=0 AND vrs<>''")?;
    let rows: Vec<(String, String, u16, u16, String)> = st
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<std::result::Result<_, _>>()?;
    for (id, book, ch, v, vrs) in rows {
        let (Some(book), Some(vrs)) = (BookCode::new(&book), Versification::builtin(&vrs)) else {
            continue;
        };
        let Some((f, t)) = canon_range(vrs, VerseKey::new(book, ch, v)) else {
            continue;
        };
        conn.execute(
            "UPDATE entries SET canon_book=?2,canon_c1=?3,canon_v1=?4,canon_c2=?5,canon_v2=?6 WHERE id=?1",
            params![id, f.book.as_str(), f.chapter, f.verse, t.chapter, t.verse],
        )?;
    }
    Ok(())
}
