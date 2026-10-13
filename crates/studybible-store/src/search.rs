//! Кэш-индекс поиска FTS5 (ADR 0003). Ключ кэша — хэш модуля + версия токенизатора;
//! при несовпадении индекс перестраивается. Индекс локальный, в модуль не входит.

use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use studybible_core::BookCode;
use studybible_core::normalize::for_search;
use studybible_core::text::collapse_spaces;

use crate::module::{Module, ModuleError};

/// Меняется при смене нормализации или схемы индекса — старый кэш тогда
/// строится заново, а встроенная `fts` модуля с другой версией
/// (`meta.norm_version`) игнорируется в пользу кэша (ADR 0016 п. 11).
/// «2» — конечные буквы иврита, маккеф и конечная сигма (вопрос № 14).
/// Публично: `module index` встраивает индекс в готовый .sb и пишет
/// эту же версию в `meta.norm_version`.
pub const TOKENIZER_VERSION: &str = "2";

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

/// Лексема запроса после нормализации (операторы 1.1.2).
enum Term {
    /// Обычное слово — FTS5 `"w"`.
    Word(String),
    /// `w*` — префикс FTS5; только завершающая `*` честная,
    /// `*`/`?` внутри слова уходят в `Glob`.
    Prefix(String),
    /// `"a b"` — фраза FTS5.
    Phrase(String),
    /// Паттерн с `?` или внутренней `*` — glob по словам
    /// нормализованного текста (FTS5 односимвольный wildcard
    /// не умеет — скан модулем).
    Glob(String),
}

/// Разбор запроса: `"…"` — фраза; завершающая `*` — префикс;
/// `?` или внутренняя `*` — glob-лексема. Токены нормализуются
/// `for_search` (`*` и `?` нормализация пропускает как есть).
fn parse_query(query: &str) -> Vec<Term> {
    let mut terms = Vec::new();
    let mut chars = query.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
            continue;
        }
        if c == '"' {
            chars.next();
            let mut buf = String::new();
            for c in chars.by_ref() {
                if c == '"' {
                    break;
                }
                buf.push(c);
            }
            let norm = tokens(&for_search(&buf)).join(" ");
            if !norm.is_empty() {
                terms.push(Term::Phrase(norm));
            }
            continue;
        }
        let mut tok = String::new();
        while let Some(&c) = chars.peek() {
            if c.is_whitespace() || c == '"' {
                break;
            }
            tok.push(c);
            chars.next();
        }
        let norm = for_search(tok.trim());
        let norm = norm.trim();
        if norm.is_empty() {
            continue;
        }
        let stem = norm.trim_end_matches('*');
        if norm.ends_with('*') && !stem.is_empty() && !stem.contains(['*', '?']) {
            terms.push(Term::Prefix(stem.to_string()));
        } else if norm.contains(['*', '?']) {
            terms.push(Term::Glob(norm.to_string()));
        } else {
            terms.push(Term::Word(norm.to_string()));
        }
    }
    terms
}

/// Glob `*`/`?` по одному слову — двухуказательный матчер
/// с откатом к последней `*`.
fn glob_word(pat: &str, word: &str) -> bool {
    let p: Vec<char> = pat.chars().collect();
    let w: Vec<char> = word.chars().collect();
    let (mut i, mut j, mut star, mut mark) = (0usize, 0usize, usize::MAX, 0usize);
    while j < w.len() {
        if i < p.len() && (p[i] == '?' || p[i] == w[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == '*' {
            star = i;
            mark = j;
            i += 1;
        } else if star != usize::MAX {
            i = star + 1;
            mark += 1;
            j = mark;
        } else {
            return false;
        }
    }
    while i < p.len() && p[i] == '*' {
        i += 1;
    }
    i == p.len()
}

/// Совпадение слова [w] с нефразовой лексемой.
fn word_matches(t: &Term, w: &str) -> bool {
    match t {
        Term::Word(x) => w == x,
        Term::Prefix(x) => w.starts_with(x.as_str()),
        Term::Glob(g) => glob_word(g, w),
        Term::Phrase(_) => false,
    }
}

/// Буквенно-цифровые раны нормализованного текста — как токены
/// `unicode61`: знаки препинания в слово не входят («свет.» → «свет»).
fn tokens(norm: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, c) in norm.char_indices() {
        if c.is_alphanumeric() {
            if start.is_none() {
                start = Some(i);
            }
        } else if let Some(s) = start.take() {
            out.push(&norm[s..i]);
        }
    }
    if let Some(s) = start {
        out.push(&norm[s..]);
    }
    out
}

/// Проверка нормализованного текста стиха по всем лексемам (AND);
/// при совпадении — сниппет: текст с `[` `]` вокруг совпавших слов.
fn scan_match(norm: &str, terms: &[Term]) -> Option<String> {
    let words = tokens(norm);
    let mut mark = vec![false; words.len()];
    for t in terms {
        match t {
            Term::Phrase(p) => {
                let ph: Vec<&str> = p.split_whitespace().collect();
                let mut found = false;
                if ph.len() <= words.len() {
                    for i in 0..=words.len() - ph.len() {
                        if words[i..i + ph.len()] == ph[..] {
                            mark[i..i + ph.len()].iter_mut().for_each(|m| *m = true);
                            found = true;
                        }
                    }
                }
                if !found {
                    return None;
                }
            }
            t => {
                let mut found = false;
                for (i, w) in words.iter().enumerate() {
                    if word_matches(t, w) {
                        mark[i] = true;
                        found = true;
                    }
                }
                if !found {
                    return None;
                }
            }
        }
    }
    let mut s = String::with_capacity(norm.len() + 8);
    for (i, w) in words.iter().enumerate() {
        if !s.is_empty() {
            s.push(' ');
        }
        if mark[i] {
            s.push('[');
        }
        s.push_str(w);
        if mark[i] {
            s.push(']');
        }
    }
    Some(s)
}

/// Построенный или переиспользованный индекс модуля.
pub struct SearchIndex {
    conn: Connection,
    /// Путь к файлу модуля — нужен glob-скану (`?`/внутренняя `*`)
    /// при закэшированном индексе: там `conn` — отдельная `.idx`.
    module_path: std::path::PathBuf,
}

/// Версия нормализации встроенного `fts` (`meta.norm_version`);
/// отсутствие ключа — индекс построен правилами версии «1».
fn module_norm_version(module: &Module) -> Result<String, ModuleError> {
    Ok(module
        .conn()
        .query_row("SELECT value FROM meta WHERE key='norm_version'", [], |r| {
            r.get::<_, String>(0)
        })
        .optional()?
        .unwrap_or_else(|| "1".into()))
}

impl SearchIndex {
    /// Открыть индекс модуля: у модуля со встроенной таблицей `fts`
    /// (ADR 0016 п. 11) поиск идёт прямо по файлу модуля, иначе —
    /// кэш `.idx` по пути `path`; при несовпадении ключа перестроить.
    pub fn open(path: &Path, module: &Module) -> Result<Self, ModuleError> {
        // Встроенная `fts` действительна только при совпадающей версии
        // нормализации; старый индекс (без `meta.norm_version` = «1»)
        // пропускаем — дальше строится/открывается кэш `.idx`.
        if module.has_search_index() && module_norm_version(module)? == TOKENIZER_VERSION {
            let conn =
                Connection::open_with_flags(module.path(), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            conn.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF")?;
            return Ok(Self {
                conn,
                module_path: module.path().to_path_buf(),
            });
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
        Ok(Self {
            conn,
            module_path: module.path().to_path_buf(),
        })
    }

    fn rebuild(conn: &Connection, module: &Module) -> Result<(), ModuleError> {
        conn.execute_batch(
            "BEGIN; DROP TABLE IF EXISTS fts;
             CREATE VIRTUAL TABLE fts USING fts5(
                 book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm,
                 tokenize='unicode61');",
        )?;
        {
            let mut rd = module.conn().prepare(
                "SELECT b.code, v.chapter, v.verse, v.text
                 FROM verses v JOIN books b ON b.book_id = v.book_id",
            )?;
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
                ins.execute(params![
                    book,
                    ch,
                    v,
                    for_search(&studybible_core::text::collapse_spaces(&text))
                ])?;
            }
        }
        conn.execute_batch("COMMIT")?;
        Ok(())
    }

    /// Поиск: слова запроса нормализуются и соединяются через AND. Порядок — bm25.
    /// Операторы: `"…"` — фраза; `w*` — префикс; `?` или `*` внутри
    /// слова — glob-скан по модулю (FTS5 их не умеет) в каноническом
    /// порядке, со сниппетом `[` `]` вокруг совпавших слов.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<Hit>, ModuleError> {
        let terms = parse_query(query);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        if terms.iter().any(|t| matches!(t, Term::Glob(_))) {
            return self.scan(&terms, limit);
        }
        let q = terms
            .iter()
            .map(|t| match t {
                Term::Word(w) | Term::Phrase(w) => {
                    format!("\"{}\"", w.replace('"', "\"\""))
                }
                Term::Prefix(w) => format!("\"{}\"*", w.replace('"', "\"\"")),
                Term::Glob(_) => unreachable!(),
            })
            .collect::<Vec<_>>()
            .join(" AND ");
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

    /// Glob-скан: лексемы проверяются по словам нормализованного
    /// текста (фраза — подпоследовательность слов). Читает `verses`
    /// модуля отдельным read-only соединением — `self.conn` может
    /// указывать на кэш `.idx`, где стихов нет.
    fn scan(&self, terms: &[Term], limit: usize) -> Result<Vec<Hit>, ModuleError> {
        let conn =
            Connection::open_with_flags(&self.module_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        conn.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF")?;
        let mut st = conn.prepare(
            "SELECT b.code, v.chapter, v.verse, v.text
             FROM verses v JOIN books b ON b.book_id = v.book_id
             ORDER BY b.ord, v.chapter, v.verse",
        )?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, u16>(1)?,
                r.get::<_, u16>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?;
        let mut hits = Vec::new();
        for row in rows {
            let (book, ch, v, text) = row?;
            let norm = for_search(&collapse_spaces(&text));
            if let Some(snippet) = scan_match(&norm, terms) {
                hits.push(Hit {
                    book: BookCode::new(&book)
                        .unwrap_or_else(|| BookCode::new("XXX").expect("код")),
                    chapter: ch,
                    verse: v,
                    snippet,
                });
                if hits.len() >= limit {
                    break;
                }
            }
        }
        Ok(hits)
    }

    /// Поиск по сноскам и параллельным местам (`spans` kind
    /// 'f'/'n'/'x' с текстом) — теми же лексемами/операторами, что
    /// и по стихам. Таблица мала, поэтому всегда скан в каноническом
    /// порядке; сниппет — `[` `]` вокруг совпавших слов.
    pub fn search_notes(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<Hit>, ModuleError> {
        let terms = parse_query(query);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        let conn =
            Connection::open_with_flags(&self.module_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        conn.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF")?;
        let mut st = conn.prepare(
            "SELECT b.code, s.chapter, s.verse, s.text
             FROM spans s JOIN books b ON b.book_id = s.book_id
             WHERE s.kind IN ('f','n','x') AND s.text != ''
             ORDER BY b.ord, s.chapter, s.verse",
        )?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, u16>(1)?,
                r.get::<_, Option<u16>>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?;
        let mut hits = Vec::new();
        for row in rows {
            let (book, ch, v, text) = row?;
            let norm = for_search(&collapse_spaces(&text));
            if let Some(snippet) = scan_match(&norm, &terms) {
                hits.push(Hit {
                    book: BookCode::new(&book)
                        .unwrap_or_else(|| BookCode::new("XXX").expect("код")),
                    chapter: ch,
                    verse: v.unwrap_or(0),
                    snippet,
                });
                if hits.len() >= limit {
                    break;
                }
            }
        }
        Ok(hits)
    }
}
