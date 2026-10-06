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
    /// Тип модуля (ADR 0016): bible | interlinear | commentary |
    /// dictionary | layer | critical. Пусто у старых модулей — читается
    /// как `bible`.
    pub kind: String,
    /// Необязательные возможности (ADR 0016): strongs, morph, tokens,
    /// alignment, variants.
    pub features: Vec<String>,
    /// Флаги прав (ADR 0016, вопрос 15): no-distribute, no-net, no-ai,
    /// no-plugins. Пусто = всё разрешено.
    pub rights: Vec<String>,
    pub extra: BTreeMap<String, String>,
}

const META_KEYS: [&str; 14] = [
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
    "kind",
    "features",
    "rights",
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
        // Необязательные ключи пишем только непустыми — простой модуль
        // не несёт лишних записей (ADR 0016).
        if !self.kind.is_empty() {
            v.push(("kind".into(), self.kind.clone()));
        }
        if !self.features.is_empty() {
            v.push(("features".into(), self.features.join(",")));
        }
        if !self.rights.is_empty() {
            v.push(("rights".into(), self.rights.join(",")));
        }
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
            kind: m.get("kind").cloned().unwrap_or_default(),
            features: m
                .get("features")
                .map(|s| {
                    s.split(',')
                        .filter(|x| !x.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default(),
            rights: m
                .get("rights")
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
-- ADR 0016 (необязательная): слова уровня токена. У простого модуля
-- таблица остаётся пустой; у старых .sb может отсутствовать вовсе.
CREATE TABLE tokens(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    seq INTEGER NOT NULL, surface TEXT NOT NULL DEFAULT '',
                    lemma TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                    morph TEXT NOT NULL DEFAULT '', gloss TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(book, chapter, verse, seq));
-- ADR 0016 (необязательная): токен → его спан в потоке чтения
-- (block = blocks.seq, span = spans.seq). Позиция слова в тексте.
CREATE TABLE alignment(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                       token_seq INTEGER NOT NULL, block INTEGER NOT NULL, span INTEGER NOT NULL,
                       PRIMARY KEY(book, chapter, verse, token_seq));
";

/// Слово уровня токена (таблица `tokens`, ADR 0016).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Token {
    pub verse: u16,
    /// Порядок внутри стиха.
    pub seq: u16,
    /// Форма слова: для пар подстрочника (`gr="…"`) — слово оригинала,
    /// иначе текст спана.
    pub surface: String,
    pub lemma: String,
    pub strong: String,
    pub morph: String,
    /// Переводная глосса (для пар подстрочника — текст спана).
    pub gloss: String,
}

/// Достать `key="значение"` из строки атрибутов спана.
fn attr<'a>(attrs: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("{key}=\"");
    let i = attrs.find(&pat)? + pat.len();
    let rest = &attrs[i..];
    let j = rest.find('"')?;
    Some(&rest[..j])
}

/// Токен из спана текста: слово несёт attrs (`strong`, `lemma`, `morph`)
/// или помечено стилем `w`. Возвращает None для обычного текста.
fn token_of(verse: u16, seq: u16, text: &str, style: &str, attrs: &str) -> Option<Token> {
    if style != "w" && attrs.is_empty() {
        return None;
    }
    // Пара подстрочника: attrs.gr — слово оригинала, текст — глосса.
    // Текст спана может нести хвостовой пробел — токен хранит слово чистым.
    let (surface, gloss) = match attr(attrs, "gr") {
        Some(gr) => (gr.trim().to_string(), text.trim().to_string()),
        None => (
            text.trim().to_string(),
            attr(attrs, "gloss").unwrap_or("").trim().to_string(),
        ),
    };
    Some(Token {
        verse,
        seq,
        surface,
        lemma: attr(attrs, "lemma").unwrap_or("").to_string(),
        strong: attr(attrs, "strong").unwrap_or("").to_string(),
        morph: attr(attrs, "morph").unwrap_or("").to_string(),
        gloss,
    })
}

/// Запись нового модуля. Хэш содержимого накапливается в `add_chapter`, в `finish` пишется в `meta`.
pub struct ModuleWriter {
    conn: Connection,
    hash: sha2::Sha256,
    tokens: usize,
}

impl ModuleWriter {
    pub fn create(path: &Path, meta: &Meta) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(&format!("PRAGMA application_id = {APP_ID};{SCHEMA}"))?;
        let w = Self {
            conn,
            hash: crate::hash::new(),
            tokens: 0,
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
            let mut ts = self.conn.prepare_cached(
                "INSERT INTO tokens VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;
            let mut al = self.conn.prepare_cached(
                "INSERT INTO alignment VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            let mut cur_verse: u16 = 0;
            let mut tok_seq: u16 = 0;
            for (seq, b) in ch.blocks.iter().enumerate() {
                bs.execute(params![book.as_str(), ch.number, seq, b.marker])?;
                for (i, s) in b.spans.iter().enumerate() {
                    if let Span::Verse(n) = s {
                        cur_verse = *n;
                        tok_seq = 0;
                    } else if let Span::Text { text, style, attrs } = s
                        && let Some(t) = token_of(cur_verse, tok_seq, text, style, attrs)
                    {
                        ts.execute(params![
                            book.as_str(),
                            ch.number,
                            t.verse,
                            t.seq,
                            t.surface,
                            t.lemma,
                            t.strong,
                            t.morph,
                            t.gloss
                        ])?;
                        al.execute(params![
                            book.as_str(),
                            ch.number,
                            t.verse,
                            t.seq,
                            seq,
                            i
                        ])?;
                        self.tokens += 1;
                        tok_seq += 1;
                    }
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

    /// Сколько токенов записано (для `meta.features = tokens`).
    pub fn tokens_written(&self) -> usize {
        self.tokens
    }

    /// Дописать или заменить ключ `meta` после `create`
    /// (автоматически определённые возможности — ADR 0016).
    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO meta VALUES(?1, ?2)",
            params![key, value],
        )?;
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
    /// Необязательные таблицы ADR 0016, которые есть в файле.
    has_tokens: bool,
    has_alignment: bool,
}

/// Связь токена со спаном потока чтения (таблица `alignment`, ADR 0016).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Alignment {
    pub verse: u16,
    pub token_seq: u16,
    /// `blocks.seq` и `spans.seq` спана, из которого выведен токен.
    pub block: u16,
    pub span: u16,
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
        // Необязательные таблицы могут отсутствовать у старых модулей.
        let has = |name: &str| -> Result<bool> {
            Ok(conn.query_row(
                "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name=?1",
                params![name],
                |r| r.get::<_, i64>(0),
            )? > 0)
        };
        Ok(Self {
            has_tokens: has("tokens")?,
            has_alignment: has("alignment")?,
            conn,
            meta,
        })
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

    /// Токены главы (слова с attrs / стилем `w`). Пустой список —
    /// у модулей без таблицы `tokens`.
    pub fn tokens(&self, book: BookCode, chapter: u16) -> Result<Vec<Token>> {
        if !self.has_tokens {
            return Ok(vec![]);
        }
        let mut st = self.conn.prepare(
            "SELECT verse, seq, surface, lemma, strong, morph, gloss
             FROM tokens WHERE book=?1 AND chapter=?2 ORDER BY verse, seq",
        )?;
        let rows = st.query_map(params![book.as_str(), chapter], |r| {
            Ok(Token {
                verse: r.get::<_, i64>(0)? as u16,
                seq: r.get::<_, i64>(1)? as u16,
                surface: r.get(2)?,
                lemma: r.get(3)?,
                strong: r.get(4)?,
                morph: r.get(5)?,
                gloss: r.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for t in rows {
            out.push(t?);
        }
        Ok(out)
    }

    /// Карта «токен → спан» главы (таблица `alignment`). Пусто —
    /// у модулей без таблицы.
    pub fn alignment(&self, book: BookCode, chapter: u16) -> Result<Vec<Alignment>> {
        if !self.has_alignment {
            return Ok(vec![]);
        }
        let mut st = self.conn.prepare(
            "SELECT verse, token_seq, block, span FROM alignment
             WHERE book=?1 AND chapter=?2 ORDER BY verse, token_seq",
        )?;
        let rows = st.query_map(params![book.as_str(), chapter], |r| {
            Ok(Alignment {
                verse: r.get::<_, i64>(0)? as u16,
                token_seq: r.get::<_, i64>(1)? as u16,
                block: r.get::<_, i64>(2)? as u16,
                span: r.get::<_, i64>(3)? as u16,
            })
        })?;
        let mut out = Vec::new();
        for a in rows {
            out.push(a?);
        }
        Ok(out)
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
