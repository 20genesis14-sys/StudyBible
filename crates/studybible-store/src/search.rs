//! Кэш-индекс поиска FTS5 (ADR 0003). Ключ кэша — хэш модуля + версия токенизатора;
//! при несовпадении индекс перестраивается. Индекс локальный, в модуль не входит.

use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use studybible_core::BookCode;
use studybible_core::normalize::for_search;

use crate::module::{Module, ModuleError};

/// Меняется при смене нормализации или схемы индекса — старый кэш тогда строится заново.
const TOKENIZER_VERSION: &str = "1";

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
    book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm,
    tokenize='unicode61');
";

/// Найденный стих. `snippet` — нормализованный текст с метками `[` `]` вокруг совпадений.
#[derive(Clone, Debug)]
pub struct Hit {
    pub book: BookCode,
    pub chapter: u16,
    pub verse: u16,
    pub snippet: String,
}

/// Построенный или переиспользованный индекс модуля.
pub struct SearchIndex {
    conn: Connection,
}

impl SearchIndex {
    /// Открыть индекс модуля: у модуля со встроенной таблицей `fts`
    /// (ADR 0016 п. 11) поиск идёт прямо по файлу модуля, иначе —
    /// кэш `.idx` по пути `path`; при несовпадении ключа перестроить.
    pub fn open(path: &Path, module: &Module) -> Result<Self, ModuleError> {
        if module.has_search_index() {
            let conn =
                Connection::open_with_flags(module.path(), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            conn.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF")?;
            return Ok(Self { conn });
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        conn.execute_batch("PRAGMA trusted_schema=OFF")?;

        let key = format!("{}:{TOKENIZER_VERSION}", module.meta().content_hash);
        let stored: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key='module'", [], |r| {
                r.get(0)
            })
            .optional()?;
        if stored.as_deref() != Some(key.as_str()) {
            Self::rebuild(&conn, module)?;
            conn.execute(
                "INSERT OR REPLACE INTO meta VALUES('module', ?1)",
                params![key],
            )?;
        }
        Ok(Self { conn })
    }

    fn rebuild(conn: &Connection, module: &Module) -> Result<(), ModuleError> {
        conn.execute_batch(
            "BEGIN; DROP TABLE IF EXISTS fts;
             CREATE VIRTUAL TABLE fts USING fts5(
                 book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm,
                 tokenize='unicode61');",
        )?;
        {
            let mut rd = module
                .conn()
                .prepare("SELECT book, chapter, verse, text FROM verses")?;
            let mut ins = conn.prepare("INSERT INTO fts VALUES(?1, ?2, ?3, ?4)")?;
            let rows = rd.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, u16>(1)?,
                    r.get::<_, u16>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?;
            for row in rows {
                let (book, ch, v, text) = row?;
                ins.execute(params![book, ch, v, for_search(&text)])?;
            }
        }
        conn.execute_batch("COMMIT")?;
        Ok(())
    }

    /// Поиск: слова запроса нормализуются и соединяются через AND. Порядок — bm25.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<Hit>, ModuleError> {
        let terms: Vec<String> = for_search(query)
            .split_whitespace()
            .map(|w| format!("\"{}\"", w.replace('"', "\"\"")))
            .collect();
        if terms.is_empty() {
            return Ok(vec![]);
        }
        let q = terms.join(" AND ");
        let mut st = self.conn.prepare(
            "SELECT book, chapter, verse, snippet(fts, 3, '[', ']', '…', 8)
             FROM fts WHERE fts MATCH ?1 ORDER BY rank LIMIT ?2",
        )?;
        st.query_map(params![q, limit as i64], |r| {
            Ok(Hit {
                book: BookCode::new(&r.get::<_, String>(0)?)
                    .unwrap_or_else(|| BookCode::new("XXX").expect("код")),
                chapter: r.get(1)?,
                verse: r.get(2)?,
                snippet: r.get(3)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()
        .map_err(Into::into)
    }
}
