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

const SCHEMA_VERSION: &str = "1";

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
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Note => "note",
            Self::Mark => "mark",
            Self::Highlight => "hl",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "note" => Some(Self::Note),
            "mark" => Some(Self::Mark),
            "hl" | "highlight" => Some(Self::Highlight),
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
                 rev INTEGER NOT NULL DEFAULT 1);
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
            Some(other) => {
                return Err(UserError::BadFormat(format!("схема {other}")));
            }
        };
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
        Ok(Self { conn, device })
    }

    /// Добавить запись; возвращает её id. `text` — текст заметки, подпись или цвет;
    /// `context` — контрольный фрагмент стиха для перепривязки (может быть пустым).
    pub fn add(&self, kind: Kind, anchor: Anchor<'_>, text: &str, context: &str) -> Result<String> {
        let id = new_id();
        let t = now();
        self.conn.execute(
            "INSERT INTO entries VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,0,?11,1)",
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
                self.device
            ],
        )?;
        Ok(id)
    }

    /// Живые записи вида `kind`; `module` — фильтр по модулю.
    pub fn entries(&self, kind: Kind, module: Option<&str>) -> Result<Vec<Entry>> {
        let sql = "SELECT id, module, kind, book, chapter, verse, text, context,
                   created, updated, deleted, device, rev FROM entries
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
                .prepare(&format!("{sql} ORDER BY module, book, chapter, verse"))?
                .query_map(params![kind.as_str()], row_to_entry)?
                .collect::<rusqlite::Result<_>>()?,
        };
        Ok(rows)
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
                 created, updated, deleted, device, rev FROM entries",
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
        if doc.get("version").and_then(|v| v.as_str()) != Some(SCHEMA_VERSION) {
            return Err(UserError::BadFormat("version".into()));
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
                    "INSERT INTO entries VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
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
                        e.rev
                    ],
                )?;
                Ok(Merge::Added)
            }
            Some(u) if e.updated > u => {
                self.conn.execute(
                    "UPDATE entries SET module=?2,kind=?3,book=?4,chapter=?5,verse=?6,
                     text=?7,context=?8,created=?9,updated=?10,deleted=?11,
                     device=?12,rev=?13 WHERE id=?1",
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
                        e.rev
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
    })
}
