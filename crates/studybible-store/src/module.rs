//! Формат модуля v1: запись и защищённое чтение SQLite.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use rusqlite::{Connection, OpenFlags, params};
use sha2::Digest as _;
use studybible_core::BookCode;
use studybible_core::text::{Block, Chapter, Span};

/// `SBM1` — подпись файла модуля в `PRAGMA application_id`.
pub const APP_ID: i64 = 0x5342_4D31;
pub const FORMAT_VERSION: &str = "1";

#[derive(Debug)]
pub enum ModuleError {
    Sqlite(rusqlite::Error),
    Io(std::io::Error),
    BadFormat(String),
    UnsupportedFeature(String),
}

impl fmt::Display for ModuleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(e) => write!(f, "SQLite: {e}"),
            Self::Io(e) => write!(f, "ввод-вывод: {e}"),
            Self::BadFormat(s) => write!(f, "не модуль v1: {s}"),
            Self::UnsupportedFeature(s) => write!(f, "нужна возможность: {s}"),
        }
    }
}

impl std::error::Error for ModuleError {}

impl From<rusqlite::Error> for ModuleError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Sqlite(e)
    }
}

impl From<std::io::Error> for ModuleError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

type Result<T> = std::result::Result<T, ModuleError>;

/// Метаданные модуля (таблица `meta`). Дополнительные ключи — в `extra`.
#[derive(Clone, Debug, Default)]
pub struct Meta {
    pub id: String,
    pub title: String,
    /// BCP 47 (`ru`, `en`, `he`, `grc`).
    pub language: String,
    /// `ltr` или `rtl`.
    pub direction: String,
    /// Имя версификации (`rsc`, `org`…).
    pub versification: String,
    /// Профиль названий (`syn`, `alt`, `en`).
    pub name_profile: String,
    /// Порядок книг (`list`, `syn`).
    pub book_order: String,
    /// Версия модуля (упрощённый SemVer).
    pub version: String,
    pub license: String,
    pub attribution: String,
    pub source: String,
    /// Заполняется записывателем.
    pub content_hash: String,
    /// Обязательные возможности; неизвестная — модуль не открывается.
    pub required: Vec<String>,
    pub extra: BTreeMap<String, String>,
}

const META_KEYS: [&str; 11] = [
    "id",
    "title",
    "language",
    "direction",
    "versification",
    "name_profile",
    "book_order",
    "version",
    "license",
    "attribution",
    "source",
];

impl Meta {
    fn pairs(&self) -> Vec<(String, String)> {
        let mut v: Vec<(String, String)> = [
            ("format_version", FORMAT_VERSION.to_string()),
            ("id", self.id.clone()),
            ("title", self.title.clone()),
            ("language", self.language.clone()),
            ("direction", self.direction.clone()),
            ("versification", self.versification.clone()),
            ("name_profile", self.name_profile.clone()),
            ("book_order", self.book_order.clone()),
            ("version", self.version.clone()),
            ("license", self.license.clone()),
            ("attribution", self.attribution.clone()),
            ("source", self.source.clone()),
            ("content_hash", self.content_hash.clone()),
            ("required", self.required.join(",")),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        v.extend(self.extra.iter().map(|(k, v)| (k.clone(), v.clone())));
        v
    }

    fn from_map(m: BTreeMap<String, String>) -> Result<Self> {
        if m.get("format_version").map(String::as_str) != Some(FORMAT_VERSION) {
            return Err(ModuleError::BadFormat(format!(
                "format_version={:?}",
                m.get("format_version")
            )));
        }
        let mut meta = Meta {
            id: m.get("id").cloned().unwrap_or_default(),
            title: m.get("title").cloned().unwrap_or_default(),
            language: m.get("language").cloned().unwrap_or_default(),
            direction: m.get("direction").cloned().unwrap_or_default(),
            versification: m.get("versification").cloned().unwrap_or_default(),
            name_profile: m.get("name_profile").cloned().unwrap_or_default(),
            book_order: m.get("book_order").cloned().unwrap_or_default(),
            version: m.get("version").cloned().unwrap_or_default(),
            license: m.get("license").cloned().unwrap_or_default(),
            attribution: m.get("attribution").cloned().unwrap_or_default(),
            source: m.get("source").cloned().unwrap_or_default(),
            content_hash: m.get("content_hash").cloned().unwrap_or_default(),
            required: m
                .get("required")
                .map(|s| {
                    s.split(',')
                        .filter(|x| !x.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default(),
            extra: m
                .into_iter()
                .filter(|(k, _)| !META_KEYS.contains(&k.as_str()))
                .collect(),
        };
        meta.extra.remove("format_version");
        meta.extra.remove("content_hash");
        meta.extra.remove("required");
        if meta.id.is_empty() {
            return Err(ModuleError::BadFormat("пустой id".into()));
        }
        Ok(meta)
    }
}

const SCHEMA: &str = "
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(code TEXT PRIMARY KEY, ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book TEXT NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book, marker));
CREATE TABLE blocks(book TEXT NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book, chapter, seq));
CREATE TABLE spans(book TEXT NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book, chapter, block, seq));
CREATE TABLE verses(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book, chapter, verse));
";

/// Запись нового модуля. Хэш содержимого накапливается в `add_chapter`, в `finish` пишется в `meta`.
pub struct ModuleWriter {
    conn: Connection,
    hash: sha2::Sha256,
}

impl ModuleWriter {
    pub fn create(path: &Path, meta: &Meta) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(&format!("PRAGMA application_id = {APP_ID};{SCHEMA}"))?;
        let w = Self {
            conn,
            hash: crate::hash::new(),
        };
        w.conn.execute_batch("BEGIN")?;
        {
            let mut st = w.conn.prepare_cached("INSERT INTO meta VALUES(?1, ?2)")?;
            for (k, v) in meta.pairs() {
                st.execute(params![k, v])?;
            }
        }
        Ok(w)
    }

    pub fn add_book(
        &self,
        code: BookCode,
        order: u16,
        title: &str,
        header: &BTreeMap<String, String>,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO books VALUES(?1, ?2, ?3)",
            params![code.as_str(), order, title],
        )?;
        let mut st = self
            .conn
            .prepare_cached("INSERT INTO book_headers VALUES(?1, ?2, ?3)")?;
        for (marker, text) in header {
            if marker != "id" {
                st.execute(params![code.as_str(), marker, text])?;
            }
        }
        Ok(())
    }

    pub fn add_chapter(&mut self, book: BookCode, ch: &Chapter) -> Result<()> {
        {
            let mut bs = self
                .conn
                .prepare_cached("INSERT INTO blocks VALUES(?1, ?2, ?3, ?4)")?;
            let mut ss = self.conn.prepare_cached(
                "INSERT INTO spans VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )?;
            for (seq, b) in ch.blocks.iter().enumerate() {
                bs.execute(params![book.as_str(), ch.number, seq, b.marker])?;
                for (i, s) in b.spans.iter().enumerate() {
                    match s {
                        Span::Verse(n) => ss.execute(params![
                            book.as_str(),
                            ch.number,
                            seq,
                            i,
                            "v",
                            *n,
                            "",
                            "",
                            "",
                            ""
                        ])?,
                        Span::Text { text, style, attrs } => ss.execute(params![
                            book.as_str(),
                            ch.number,
                            seq,
                            i,
                            "t",
                            rusqlite::types::Null,
                            style,
                            attrs,
                            "",
                            text
                        ])?,
                        Span::Note { kind, caller, text } => ss.execute(params![
                            book.as_str(),
                            ch.number,
                            seq,
                            i,
                            kind.to_string(),
                            rusqlite::types::Null,
                            "",
                            "",
                            caller,
                            text
                        ])?,
                    };
                }
            }
        }
        let mut vs = self
            .conn
            .prepare_cached("INSERT INTO verses VALUES(?1, ?2, ?3, ?4)")?;
        for (n, text) in ch.verse_texts() {
            vs.execute(params![book.as_str(), ch.number, n, text])?;
        }
        crate::hash::feed(&mut self.hash, book, ch.number, ch);
        Ok(())
    }

    pub fn finish(self) -> Result<()> {
        self.conn.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'content_hash'",
            params![crate::hash::hex(self.hash.finalize())],
        )?;
        self.conn.execute_batch("COMMIT; PRAGMA optimize;")?;
        Ok(())
    }
}

/// Модуль, открытый только на чтение, в защищённом режиме (ADR 0003).
pub struct Module {
    conn: Connection,
    meta: Meta,
}

impl Module {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        conn.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF")?;
        conn.set_db_config(rusqlite::config::DbConfig::SQLITE_DBCONFIG_DEFENSIVE, true)?;
        conn.set_db_config(rusqlite::config::DbConfig::SQLITE_DBCONFIG_DQS_DML, false)?;
        conn.set_db_config(rusqlite::config::DbConfig::SQLITE_DBCONFIG_DQS_DDL, false)?;

        let app_id: i64 = conn.query_row("PRAGMA application_id", [], |r| r.get(0))?;
        if app_id != APP_ID {
            return Err(ModuleError::BadFormat(format!(
                "application_id={app_id:#x}"
            )));
        }
        for table in ["meta", "books", "blocks", "spans", "verses"] {
            let n: i64 = conn.query_row(
                "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name=?1",
                params![table],
                |r| r.get(0),
            )?;
            if n == 0 {
                return Err(ModuleError::BadFormat(format!("нет таблицы {table}")));
            }
        }
        // Проверка ожидаемых столбцов дешёвыми запросами.
        for q in [
            "SELECT key, value FROM meta LIMIT 0",
            "SELECT code, ord, title FROM books LIMIT 0",
            "SELECT book, marker, text FROM book_headers LIMIT 0",
            "SELECT book, chapter, seq, marker FROM blocks LIMIT 0",
            "SELECT book, chapter, block, seq, kind, num, style, attrs, caller, text FROM spans LIMIT 0",
            "SELECT book, chapter, verse, text FROM verses LIMIT 0",
        ] {
            conn.prepare(q)
                .map(|_| ())
                .map_err(|_| ModuleError::BadFormat(q.into()))?;
        }

        let map: BTreeMap<String, String> = {
            let mut st = conn.prepare("SELECT key, value FROM meta")?;
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        let meta = Meta::from_map(map)?;
        if let Some(req) = meta.required.first() {
            return Err(ModuleError::UnsupportedFeature(req.clone()));
        }
        Ok(Self { conn, meta })
    }

    pub fn meta(&self) -> &Meta {
        &self.meta
    }

    /// Для тестов и кода, которому нужен прямой доступ к соединению (только чтение).
    #[doc(hidden)]
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Книги в порядке модуля: код и заголовок.
    pub fn books(&self) -> Result<Vec<(BookCode, String)>> {
        let mut st = self
            .conn
            .prepare("SELECT code, title FROM books ORDER BY ord")?;
        st.query_map([], |r| {
            Ok((
                BookCode::new(&r.get::<_, String>(0)?)
                    .unwrap_or_else(|| BookCode::new("XXX").expect("код")),
                r.get(1)?,
            ))
        })?
        .collect::<rusqlite::Result<_>>()
        .map_err(Into::into)
    }

    pub fn book_header(&self, book: BookCode, marker: &str) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT text FROM book_headers WHERE book=?1 AND marker=?2",
                params![book.as_str(), marker],
                |r| r.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    /// Поток чтения главы.
    pub fn chapter(&self, book: BookCode, chapter: u16) -> Result<Option<Chapter>> {
        let mut bs = self
            .conn
            .prepare("SELECT seq, marker FROM blocks WHERE book=?1 AND chapter=?2 ORDER BY seq")?;
        let mut ss = self.conn.prepare(
            "SELECT kind, num, style, attrs, caller, text FROM spans
             WHERE book=?1 AND chapter=?2 AND block=?3 ORDER BY seq",
        )?;
        let mut ch = Chapter {
            number: chapter,
            blocks: vec![],
        };
        let mut empty = true;
        let blocks = bs.query_map(params![book.as_str(), chapter], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?;
        for b in blocks {
            let (seq, marker) = b?;
            empty = false;
            let mut block = Block {
                marker,
                spans: vec![],
            };
            let spans = ss.query_map(params![book.as_str(), chapter, seq], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<u16>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                ))
            })?;
            for s in spans {
                let (kind, num, style, attrs, caller, text) = s?;
                block.spans.push(match kind.as_str() {
                    "v" => Span::Verse(num.unwrap_or_default()),
                    "t" => Span::Text { text, style, attrs },
                    "f" | "x" => Span::Note {
                        kind: kind.chars().next().unwrap_or('f'),
                        caller,
                        text,
                    },
                    _ => continue,
                });
            }
            ch.blocks.push(block);
        }
        Ok((!empty).then_some(ch))
    }

    /// Плоский текст стиха (из кэшированной таблицы `verses`).
    pub fn verse_text(&self, book: BookCode, chapter: u16, verse: u16) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT text FROM verses WHERE book=?1 AND chapter=?2 AND verse=?3",
                params![book.as_str(), chapter, verse],
                |r| r.get(0),
            )
            .optional()
            .map_err(Into::into)
    }
}

use rusqlite::OptionalExtension;
