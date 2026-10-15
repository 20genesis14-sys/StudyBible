//! Кэш-индекс поиска FTS5 (ADR 0003). Ключ кэша — хэш модуля + версия токенизатора;
//! при несовпадении индекс перестраивается. Индекс локальный, в модуль не входит.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use studybible_core::BookCode;
use studybible_core::normalize::for_search;
use studybible_core::text::collapse_spaces;

use crate::module::{Module, ModuleError, attr_all};

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
    /// У сносок к заголовкам (`verse IS NULL`) возвращается стих 1,
    /// чтобы переход открывал начало главы.
    pub fn search_notes(&self, query: &str, limit: usize) -> Result<Vec<Hit>, ModuleError> {
        self.search_notes_with_layer(query, limit, None, "")
    }

    /// Поиск по сноскам модуля и (если у модуля нет собственных
    /// `x`-спанов) подключённому внешнему слою параллельных мест
    /// (`openbible-xrefs`, ADR 0023) с конверсией стихов из `eng`
    /// в `target_vrs`.
    pub fn search_notes_with_layer(
        &self,
        query: &str,
        limit: usize,
        layer: Option<&Module>,
        target_vrs: &str,
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
                    verse: v.unwrap_or(1).max(1),
                    snippet,
                });
                if hits.len() >= limit {
                    return Ok(hits);
                }
            }
        }
        // Если у модуля нет собственных `x`-спанов и передан внешний слой —
        // сканируем также ссылки слоя (координаты eng → target_vrs).
        let has_own_x: i64 = conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM spans WHERE kind='x')",
                [],
                |r| r.get(0),
            )
            .unwrap_or(1);
        if has_own_x == 0
            && let Some(layer_mod) = layer
        {
            let eng = studybible_core::Versification::builtin("eng");
            let dst = studybible_core::Versification::builtin(target_vrs);
            let mut lst = layer_mod.conn().prepare(
                "SELECT b.code, s.chapter, s.verse, s.text
                 FROM spans s JOIN books b ON b.book_id = s.book_id
                 WHERE s.kind = 'x' AND s.text != ''
                 ORDER BY b.ord, s.chapter, s.verse, s.seq",
            )?;
            let lrows = lst.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, u16>(1)?,
                    r.get::<_, Option<u16>>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?;
            for lrow in lrows {
                let (book, ch, v, text) = lrow?;
                let norm = for_search(&collapse_spaces(&text));
                if let Some(snippet) = scan_match(&norm, &terms) {
                    let bcode =
                        BookCode::new(&book).unwrap_or_else(|| BookCode::new("XXX").expect("код"));
                    let v_raw = v.unwrap_or(1).max(1);
                    let (out_book, out_ch, out_v) = match (eng, dst) {
                        (Some(e), Some(d)) if target_vrs != "eng" && !target_vrs.is_empty() => e
                            .convert(d, studybible_core::VerseKey::new(bcode, ch, v_raw))
                            .first()
                            .map(|k| (k.book, k.chapter, k.verse.max(1)))
                            .unwrap_or((bcode, ch, v_raw)),
                        _ => (bcode, ch, v_raw),
                    };
                    hits.push(Hit {
                        book: out_book,
                        chapter: out_ch,
                        verse: out_v,
                        snippet,
                    });
                    if hits.len() >= limit {
                        break;
                    }
                }
            }
        }
        Ok(hits)
    }

    /// Поиск стихов по номеру Стронга (обратная сторона омнибокса).
    /// При переданном валидном слое `{id}-strongs` ищем по его `links`
    /// (смета атрибутов при чтении — по слою, поэтому и поиск по нему;
    /// слова с номером помечаются `[` `]` по индексу `links.word`
    /// токенизатора `w1`). Иначе — по собственной разметке модуля:
    /// `token_pack`/`tokens`, а при их отсутствии — `strong=` в
    /// `attrs` спанов `span_pack`/`spans`. Сниппет — нормализованный
    /// текст стиха целиком. Фолбэки при пустом ответе: uW-добивка
    /// `G15100`→`G1510`, затем суффиксный ключ → базовый номер
    /// (`H2300G` → `H2300`, находит и `H2300A`).
    pub fn search_strong(
        &self,
        code: &str,
        limit: usize,
        layer: Option<&Module>,
        module: &Module,
    ) -> Result<Vec<Hit>, ModuleError> {
        let keys = strong_keys(code);
        if keys.is_empty() {
            return Ok(vec![]);
        }
        let hits = self.strong_scan(&keys, limit, layer, module)?;
        if !hits.is_empty() {
            return Ok(hits);
        }
        // uW-добивка: пятизначный номер с нулём на конце мог означать
        // классический номер + `0` (`G15100` → `G1510`) — пробуем этот
        // вариант, только когда точный ключ ничего не дал (подлинный
        // dStrong вида `G21370` сначала ищется как есть).
        let alt: Vec<_> = keys
            .iter()
            .filter(|(_, n, _)| *n >= 10000 && *n % 10 == 0)
            .map(|&(p, n, s)| (p, n / 10, s))
            .collect();
        if !alt.is_empty() {
            let hits = self.strong_scan(&alt, limit, layer, module)?;
            if !hits.is_empty() {
                return Ok(hits);
            }
        }
        // Суффиксный запрос без совпадений: разметка могла проставить
        // другую букву того же номера (`H2300G` в запросе, а в слое
        // только `H2300A`) — показываем, что есть по самому числу.
        let plain: Vec<_> = keys
            .iter()
            .filter(|(_, _, s)| *s != ' ')
            .map(|&(p, n, _)| (p, n, ' '))
            .collect();
        if plain.is_empty() {
            return Ok(hits);
        }
        self.strong_scan(&plain, limit, layer, module)
    }

    /// Один проход сканирования по ключам запроса (см. `search_strong`).
    /// Таблицы модуля читаются через `module.conn()` — прямое открытие
    /// `module_path` ломалось бы на `.sbz` (сжатый файл).
    fn strong_scan(
        &self,
        keys: &[(char, u32, char)],
        limit: usize,
        layer: Option<&Module>,
        module: &Module,
    ) -> Result<Vec<Hit>, ModuleError> {
        let conn = module.conn();

        // Координаты стихов уже идут из запросов в каноническом порядке;
        // дедупликация по (книга, глава, стих) + индексы слов w1 (слой).
        let mut seen: HashSet<(String, u16, u16)> = HashSet::new();
        let mut coords: Vec<(String, u16, u16)> = Vec::new();
        let mut word_marks: HashMap<(String, u16, u16), Vec<u16>> = HashMap::new();

        if let Some(lm) = layer.filter(|l| l.has_links()) {
            // У слоя нет своей таблицы books: links.book_id — нумерация
            // целевого модуля (book_id = ord при сборке), поэтому коды
            // книг резолвим по books модуля, а канонический порядок даёт
            // сам ORDER BY book_id.
            let mut bid2code: HashMap<i64, String> = HashMap::new();
            {
                let mut bs = conn.prepare("SELECT book_id, code FROM books")?;
                let brows = bs.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                for r in brows {
                    let (bid, code): (i64, String) = r?;
                    bid2code.insert(bid, code);
                }
            }
            let mut st = lm.conn().prepare(
                "SELECT book_id, chapter, verse, word, strong FROM links
                 WHERE strong != ''
                 ORDER BY book_id, chapter, verse, word",
            )?;
            let rows = st.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, u16>(1)?,
                    r.get::<_, u16>(2)?,
                    r.get::<_, u16>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })?;
            for row in rows {
                let (bid, ch, v, w, list) = row?;
                // verse=0 — надписания/заголовки (в verses их нет,
                // а выдача строится по стихам).
                let Some(book) = bid2code.get(&bid).filter(|_| v > 0) else {
                    continue;
                };
                if strong_list_hit(&list, keys)
                    && push_hit(
                        &mut seen,
                        &mut coords,
                        &mut word_marks,
                        book.clone(),
                        ch,
                        v,
                        Some(w),
                        limit,
                    )
                {
                    break;
                }
            }
        } else {
            // Собственная разметка модуля: токены (построчно или блобами),
            // иначе `strong=` в атрибутах `t`-спанов. Источники — вид
            // одних и тех же данных (токены выводятся из спанов),
            // поэтому останавливаемся после первого найденного
            // непустого источника, даже если совпадений в нём нет.
            let mut scanned = false;
            for src in ["token_pack", "tokens", "span_pack", "spans"] {
                if scanned {
                    break;
                }
                match src {
                    "token_pack" if table_filled(conn, "token_pack") => {
                        scanned = true;
                        let mut st = conn.prepare(
                            "SELECT b.code, p.chapter, p.verse, p.blob FROM token_pack p
                             JOIN books b ON b.book_id = p.book_id
                             ORDER BY b.ord, p.chapter, p.verse",
                        )?;
                        let rows = st.query_map([], |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, u16>(1)?,
                                r.get::<_, u16>(2)?,
                                r.get::<_, Vec<u8>>(3)?,
                            ))
                        })?;
                        for row in rows {
                            let (book, ch, v, blob) = row?;
                            for t in crate::pack::decode_tokens(&blob)? {
                                if strong_list_hit(&t.strong, keys)
                                    && push_hit(
                                        &mut seen,
                                        &mut coords,
                                        &mut word_marks,
                                        book.clone(),
                                        ch,
                                        v,
                                        None,
                                        limit,
                                    )
                                {
                                    break;
                                }
                            }
                            if coords.len() >= limit {
                                break;
                            }
                        }
                    }
                    "tokens" if table_filled(conn, "tokens") => {
                        scanned = true;
                        let mut st = conn.prepare(
                            "SELECT b.code, t.chapter, t.verse, t.strong FROM tokens t
                             JOIN books b ON b.book_id = t.book_id WHERE t.strong != ''
                             ORDER BY b.ord, t.chapter, t.verse",
                        )?;
                        let rows = st.query_map([], |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, u16>(1)?,
                                r.get::<_, u16>(2)?,
                                r.get::<_, String>(3)?,
                            ))
                        })?;
                        for row in rows {
                            let (book, ch, v, list) = row?;
                            if strong_list_hit(&list, keys)
                                && push_hit(
                                    &mut seen,
                                    &mut coords,
                                    &mut word_marks,
                                    book,
                                    ch,
                                    v,
                                    None,
                                    limit,
                                )
                            {
                                break;
                            }
                        }
                    }
                    "span_pack" if table_filled(conn, "span_pack") => {
                        scanned = true;
                        let mut st = conn.prepare(
                            "SELECT b.code, p.chapter, p.blob FROM span_pack p
                             JOIN books b ON b.book_id = p.book_id
                             ORDER BY b.ord, p.chapter, p.block",
                        )?;
                        let rows = st.query_map([], |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, u16>(1)?,
                                r.get::<_, Vec<u8>>(2)?,
                            ))
                        })?;
                        for row in rows {
                            let (book, ch, blob) = row?;
                            for s in crate::pack::decode_spans(&blob)? {
                                if let Some(v) = s.verse
                                    && strong_list_hit(&attr_all(&s.attrs, "strong"), keys)
                                    && push_hit(
                                        &mut seen,
                                        &mut coords,
                                        &mut word_marks,
                                        book.clone(),
                                        ch,
                                        v,
                                        None,
                                        limit,
                                    )
                                {
                                    break;
                                }
                            }
                            if coords.len() >= limit {
                                break;
                            }
                        }
                    }
                    "spans" if table_filled(conn, "spans") => {
                        scanned = true;
                        let mut st = conn.prepare(
                            "SELECT b.code, s.chapter, s.verse, s.attrs FROM spans s
                             JOIN books b ON b.book_id = s.book_id
                             WHERE s.kind = 't' AND s.verse IS NOT NULL
                               AND s.attrs LIKE '%strong=%'
                             ORDER BY b.ord, s.chapter, s.verse",
                        )?;
                        let rows = st.query_map([], |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, u16>(1)?,
                                r.get::<_, u16>(2)?,
                                r.get::<_, String>(3)?,
                            ))
                        })?;
                        for row in rows {
                            let (book, ch, v, attrs) = row?;
                            if strong_list_hit(&attr_all(&attrs, "strong"), keys)
                                && push_hit(
                                    &mut seen,
                                    &mut coords,
                                    &mut word_marks,
                                    book,
                                    ch,
                                    v,
                                    None,
                                    limit,
                                )
                            {
                                break;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        // Текст стихов для сниппетов — из целевого модуля (координаты
        // слоя и так в сетке модуля).
        let mut vt = conn.prepare(
            "SELECT v.text FROM verses v JOIN books b ON b.book_id = v.book_id
             WHERE b.code = ?1 AND v.chapter = ?2 AND v.verse = ?3",
        )?;
        let mut hits = Vec::with_capacity(coords.len());
        for (book, ch, v) in coords {
            let text: String = vt
                .query_row(params![book, ch, v], |r| r.get(0))
                .optional()?
                .unwrap_or_default();
            let norm = for_search(&collapse_spaces(&text));
            let snippet = match word_marks.get(&(book.clone(), ch, v)) {
                Some(idxs) => {
                    let ws = studybible_core::text::words(&norm);
                    let mut s = String::with_capacity(norm.len() + 8);
                    for (i, w) in ws.iter().enumerate() {
                        if !s.is_empty() {
                            s.push(' ');
                        }
                        if idxs.contains(&(i as u16)) {
                            s.push('[');
                            s.push_str(w);
                            s.push(']');
                        } else {
                            s.push_str(w);
                        }
                    }
                    s
                }
                None => norm,
            };
            hits.push(Hit {
                book: BookCode::new(&book).unwrap_or_else(|| BookCode::new("XXX").expect("код")),
                chapter: ch,
                verse: v,
                snippet,
            });
        }
        Ok(hits)
    }
}

/// Добавить стих в выдачу поиска Стронга: дедупликация по координате,
/// `w` — индекс слова `w1` для пометки в сниппете (слой `links`).
/// Возвращает true, когда набран лимит — дальше можно не читать.
#[allow(clippy::too_many_arguments)]
fn push_hit(
    seen: &mut HashSet<(String, u16, u16)>,
    coords: &mut Vec<(String, u16, u16)>,
    word_marks: &mut HashMap<(String, u16, u16), Vec<u16>>,
    book: String,
    ch: u16,
    v: u16,
    w: Option<u16>,
    limit: usize,
) -> bool {
    let k = (book, ch, v);
    if seen.insert(k.clone()) {
        coords.push(k.clone());
    }
    if let Some(w) = w {
        word_marks.entry(k).or_default().push(w);
    }
    coords.len() >= limit
}

/// Таблица есть и не пуста.
fn table_filled(conn: &Connection, name: &str) -> bool {
    let exists = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?1)",
            [name],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0)
        != 0;
    exists
        && conn
            .query_row(
                &format!("SELECT EXISTS(SELECT 1 FROM {name} LIMIT 1)"),
                [],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0)
            != 0
}

/// Номер Стронга как ключ сравнения `(H|G, число, суффикс)`: добивка
/// нулями и регистр не влияют (`H29` ≡ `H0029`, `h29g` ≡ `H0029G`).
/// Строчные `v..z` у 4-значных кодов — dStrong-тёзки №22+ и не сливаются
/// с заглавными (как в `normalizeStrong`). Пятизначная uW-добивка
/// `G15100` даёт второй ключ `G1510`.
fn strong_key(code: &str) -> Option<(char, u32, char)> {
    let s = code.trim();
    let b = s.as_bytes();
    if b.len() < 2 {
        return None;
    }
    let prefix = (b[0] as char).to_ascii_uppercase();
    if prefix != 'H' && prefix != 'G' {
        return None;
    }
    let rest = &s[1..];
    let dlen = rest.bytes().take_while(|c| c.is_ascii_digit()).count();
    if dlen == 0 || dlen > 5 {
        return None;
    }
    let num: u32 = rest[..dlen].parse().ok()?;
    let suffix = match rest[dlen..].chars().collect::<Vec<_>>().as_slice() {
        [] => ' ',
        // Тёзки №22+ — только строчные и только при 4 знаках.
        [c] if dlen == 4 && c.is_ascii_lowercase() && ('v'..='z').contains(c) => *c,
        [c] => c.to_ascii_uppercase(),
        _ => return None,
    };
    Some((prefix, num, suffix))
}

/// Ключи сравнения запроса (список номеров через пробел тоже годится —
/// `_directStrong` на такие не срабатывает, но прямой вызов умеет).
fn strong_keys(query: &str) -> Vec<(char, u32, char)> {
    let mut out = Vec::new();
    for c in query.split_whitespace() {
        if let Some(k) = strong_key(c)
            && !out.contains(&k)
        {
            out.push(k);
        }
    }
    out
}

/// Список номеров через пробел (`strong` в links/tokens/attrs)
/// содержит хотя бы один из ключей запроса.
fn strong_list_hit(list: &str, keys: &[(char, u32, char)]) -> bool {
    list.split_whitespace()
        .any(|c| strong_key(c).is_some_and(|k| keys.iter().any(|&q| strong_eq(q, k))))
}

/// Совпадение ключа запроса с номером из разметки: запрос без
/// суффикса покрывает любые dStrong-варианты классического номера
/// (`H1254` находит и `H1254A`), запрос с суффиксом — строгий.
fn strong_eq(query: (char, u32, char), stored: (char, u32, char)) -> bool {
    query.0 == stored.0 && query.1 == stored.1 && (query.2 == ' ' || query.2 == stored.2)
}
