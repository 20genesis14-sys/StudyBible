//! Формат модуля v1: запись и защищённое чтение SQLite.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, params};
use sha2::Digest as _;
use studybible_core::text::{Block, BlockKind, Chapter, Span};
use studybible_core::{BookCode, VerseKey};

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

pub(crate) type Result<T> = std::result::Result<T, ModuleError>;

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
    /// Профиль названий (`syn`, `en`).
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
CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                   ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book_id, marker));
CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book_id, chapter, seq));
-- t: text='', текст — срез verses.text по (verse,start,len);
-- заголовочные спаны: verse IS NULL, текст в text;
-- f/x: привязка (verse,start), тело в text; v — только пустые стихи.
CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   verse INTEGER, start INTEGER, len INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, block, seq));
CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book_id, chapter, verse));
-- ADR 0016 (необязательная): слова уровня токена. У простого модуля
-- таблица остаётся пустой; у старых .sb может отсутствовать вовсе.
CREATE TABLE tokens(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    seq INTEGER NOT NULL, surface TEXT NOT NULL DEFAULT '',
                    lemma TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                    morph TEXT NOT NULL DEFAULT '', gloss TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(book_id, chapter, verse, seq));
-- ADR 0016 (необязательная): токен → его спан в потоке чтения
-- (block = blocks.seq, span = spans.seq). Позиция слова в тексте.
CREATE TABLE alignment(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                       token_seq INTEGER NOT NULL, block INTEGER NOT NULL, span INTEGER NOT NULL,
                       PRIMARY KEY(book_id, chapter, verse, token_seq));
-- ADR 0016 (необязательные): критический аппарат. Вариант — место
-- (стих + диапазон токенов); у каждого варианта — чтения, у чтения —
-- свидетели (рукописи/версии по сиглам).
CREATE TABLE variants(id INTEGER PRIMARY KEY,
                      book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                      token_from INTEGER NOT NULL, token_to INTEGER NOT NULL);
CREATE TABLE readings(id INTEGER PRIMARY KEY, variant_id INTEGER NOT NULL,
                      seq INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
                      is_base INTEGER NOT NULL DEFAULT 0);
CREATE TABLE witnesses(reading_id INTEGER NOT NULL, siglum TEXT NOT NULL,
                       PRIMARY KEY(reading_id, siglum));
-- ADR 0016 (необязательная): словарные статьи для kind=dictionary.
-- ord — порядок в словаре; norm — строчная форма для поиска.
CREATE TABLE entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
                     norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '');
CREATE INDEX entries_norm ON entries(norm);
-- ADR 0016 (необязательная): метки времени — синхронизация аудио и
-- пословная подсветка TTS. offset_ms — от начала аудиодорожки главы;
-- dur_ms NULL = до следующей метки; text — слово для подсветки.
CREATE TABLE marks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                   seq INTEGER NOT NULL, offset_ms INTEGER NOT NULL,
                   dur_ms INTEGER, text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, seq));
-- ADR 0022 (необязательные): блоб-упаковка. `t`-спаны блока,
-- токены и alignment стиха — varint-массивы в одном BLOB.
-- Построчные spans/tokens/alignment при этом остаются пустыми.
CREATE TABLE span_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                       block INTEGER NOT NULL, blob BLOB NOT NULL,
                       PRIMARY KEY(book_id, chapter, block));
CREATE TABLE token_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE align_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
-- ADR 0023/0022 (необязательная): структурные цели перекрёстных ссылок
-- слоя, varint-блоб на стих (pack.rs::PackedXref). Цель — каноническая
-- координата (BookCode текстом, глава, стих, сегмент); отображаемая
-- строка — в spans.x, здесь — машинные цели.
CREATE TABLE xrefs_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
-- ADR 0025 (необязательная): слой разметки перевода — номера Стронга
-- на словах целевого текста (kind='layer', features='strongs').
-- word — индекс слова в стихе по токенизатору `w1` (с нуля);
-- ref — адрес слова оригинала в базовом слое ('Gen.1.1#03', пусто —
-- привязка только номером); strong — dStrong-ключ(и) через пробел;
-- conf 0–10; flags — причины/пометки; source — происхождение
-- (таблица, выравнивание, модель+версия, правило).
CREATE TABLE links(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                   verse INTEGER NOT NULL, word INTEGER NOT NULL,
                   ref TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                   conf INTEGER NOT NULL DEFAULT 0,
                   flags TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, word));
";

/// Разметка слова перевода (таблица `links`, ADR 0025): слово стиха
/// цели (индекс токенизатора `w1`, с нуля) → номер(а) Стронга и адрес
/// слова оригинала в базовом слое.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Link {
    /// Стих (глава известна из запроса).
    pub verse: u16,
    /// Порядковый номер слова в стихе (`text::words`, с нуля).
    pub word: u16,
    /// Адрес слова в базовом слое ('Gen.1.1#03'); пусто — без адреса.
    pub r#ref: String,
    /// dStrong-ключ(и) через пробел.
    pub strong: String,
    /// Уверенность 0–10 (шкала ADR 0025 п. 6).
    pub conf: u8,
    /// Причины/пометки через запятую.
    pub flags: String,
    /// Происхождение записи (таблица, выравнивание, модель+версия, правило).
    pub source: String,
}

/// Структурная цель перекрёстной ссылки (таблица `xrefs`, ADR 0023):
/// `verse` — стих источника (глава известна из запроса), `to` — цель
/// в канонических координатах версификации модуля, `end` — конец
/// диапазона (`None` = одиночный стих), `votes` — вес из источника.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XrefTarget {
    pub verse: u16,
    pub to: VerseKey,
    pub end: Option<VerseKey>,
    pub votes: i64,
}

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

/// Метка времени (таблица `marks`, ADR 0016): позиция в аудиодорожке
/// главы для синхронизации аудио и пословной подсветки TTS.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Mark {
    pub verse: u16,
    /// Порядок внутри стиха.
    pub seq: u16,
    /// Смещение от начала дорожки главы, мс.
    pub offset_ms: u32,
    /// Длительность, мс; None — звучит до следующей метки.
    pub dur_ms: Option<u32>,
    /// Слово/фраза метки (контроль и подсветка).
    pub text: String,
}

/// Достать `key="значение"` из строки атрибутов спана.
fn attr<'a>(attrs: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("{key}=\"");
    let i = attrs.find(&pat)? + pat.len();
    let rest = &attrs[i..];
    let j = rest.find('"')?;
    Some(&rest[..j])
}

/// Все значения `key="…"` в строке атрибутов, через пробел.
/// Спан может нести несколько номеров Стронга/кодов морфологии
/// (`strong="H1254" strong="H853" morph="TH8804" morph="TH8799"`) —
/// позиционная связь i-го strong с i-м morph сохраняется.
fn attr_all(attrs: &str, key: &str) -> String {
    let pat = format!("{key}=\"");
    let mut out = String::new();
    let mut rest = attrs;
    while let Some(i) = rest.find(&pat) {
        let v = &rest[i + pat.len()..];
        let Some(j) = v.find('"') else { break };
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(&v[..j]);
        rest = &v[j + 1..];
    }
    out
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
        strong: attr_all(attrs, "strong"),
        morph: attr_all(attrs, "morph"),
        gloss,
    })
}

/// Запись нового модуля. Хэш содержимого накапливается в `add_chapter`, в `finish` пишется в `meta`.
pub struct ModuleWriter {
    conn: Connection,
    hash: sha2::Sha256,
    tokens: usize,
    /// Код книги → book_id (заполняется в `add_book`).
    book_ids: std::collections::HashMap<BookCode, i64>,
    /// Уже выставлен `meta.required="pack"` (ADR 0022).
    pack_marked: std::cell::Cell<bool>,
}

impl ModuleWriter {
    pub fn create(path: &Path, meta: &Meta) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(&format!("PRAGMA application_id = {APP_ID};{SCHEMA}"))?;
        let w = Self {
            conn,
            hash: crate::hash::new(),
            tokens: 0,
            book_ids: std::collections::HashMap::new(),
            pack_marked: std::cell::Cell::new(false),
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
        &mut self,
        code: BookCode,
        order: u16,
        title: &str,
        header: &BTreeMap<String, String>,
    ) -> Result<()> {
        let book_id = i64::from(order);
        self.conn.execute(
            "INSERT INTO books VALUES(?1, ?2, ?3, ?4)",
            params![book_id, code.as_str(), order, title],
        )?;
        self.book_ids.insert(code, book_id);
        let mut st = self
            .conn
            .prepare_cached("INSERT INTO book_headers VALUES(?1, ?2, ?3)")?;
        for (marker, text) in header {
            if marker != "id" {
                st.execute(params![book_id, marker, text])?;
            }
        }
        Ok(())
    }

    /// Промежуточная строка спана до записи (см. SCHEMA: book_id, verse, start, len).
    #[allow(clippy::too_many_arguments)]
    fn span_row<'a>(
        book_id: i64,
        ch: u16,
        block: usize,
        seq: usize,
        kind: &'a str,
        num: Option<u16>,
        verse: Option<u16>,
        start: Option<usize>,
        len: Option<usize>,
        style: &'a str,
        attrs: &'a str,
        caller: &'a str,
        text: &'a str,
    ) -> impl rusqlite::Params + 'a {
        (
            book_id,
            ch,
            block as i64,
            seq as i64,
            kind,
            num,
            verse,
            start.map(|x| x as i64),
            len.map(|x| x as i64),
            style,
            attrs,
            caller,
            text,
        )
    }

    pub fn add_chapter(&mut self, book: BookCode, ch: &Chapter) -> Result<()> {
        let book_id = *self
            .book_ids
            .get(&book)
            .ok_or_else(|| ModuleError::BadFormat(format!("книга {book} без add_book")))?;
        // Первый проход — в памяти: сырой текст стиха (для срезов) и
        // строки спанов; пустые стихи получают маркер 'v' постфактум.
        struct Row {
            block: usize,
            i: usize,
            kind: String,
            num: Option<u16>,
            verse: Option<u16>,
            start: Option<usize>,
            len: Option<usize>,
            style: String,
            attrs: String,
            caller: String,
            text: String,
        }
        let mut rows: Vec<Row> = Vec::new();
        let mut vbuf: BTreeMap<u16, String> = BTreeMap::new();
        let mut has_t: std::collections::HashSet<u16> = std::collections::HashSet::new();
        let mut vmarks: Vec<(usize, usize, u16)> = Vec::new();
        let mut cur: Option<u16> = None;
        let mut toks: Vec<(Token, usize, usize)> = Vec::new();
        let mut tok_seq: u16 = 0;
        for (seq, b) in ch.blocks.iter().enumerate() {
            let kind = b.kind();
            let heading = kind == BlockKind::Heading;
            if kind == BlockKind::Superscription && cur.is_none() {
                cur = Some(0);
                vbuf.entry(0).or_default();
            }
            for (i, s) in b.spans.iter().enumerate() {
                match s {
                    // Маркер внутри заголовка — строка 'v' сохраняется
                    // (раньше так и было), но cur/текст не трогает:
                    // verse_texts() пропускает заголовки целиком.
                    Span::Verse(n) if heading => rows.push(Row {
                        block: seq,
                        i,
                        kind: "v".into(),
                        num: Some(*n),
                        verse: None,
                        start: None,
                        len: None,
                        style: String::new(),
                        attrs: String::new(),
                        caller: String::new(),
                        text: String::new(),
                    }),
                    Span::Verse(n) => {
                        cur = Some(*n);
                        vbuf.entry(*n).or_default();
                        vmarks.push((seq, i, *n));
                        tok_seq = 0;
                    }
                    Span::Text { text, style, attrs } => {
                        if heading || cur.is_none() {
                            // Заголовочный/вводный текст — собственный,
                            // без привязки к стиху.
                            rows.push(Row {
                                block: seq,
                                i,
                                kind: "t".into(),
                                num: None,
                                verse: None,
                                start: None,
                                len: None,
                                style: style.clone(),
                                attrs: attrs.clone(),
                                caller: String::new(),
                                text: text.clone(),
                            });
                        } else if let Some(v) = cur {
                            // Канонический текст = отображаемый: разделитель
                            // морфем '/' в w-спанах (источники вроде OSHB)
                            // убираем при записи — до этого его резал
                            // рендерер, и в verses.text он не попадал.
                            // Спаны с '<' (остатки тегов источника) не трогаем:
                            // там '/' — часть разметки (</S>).
                            let clean;
                            let text = if style == "w" && text.contains('/') && !text.contains('<')
                            {
                                clean = text.replace('/', "");
                                clean.as_str()
                            } else {
                                text.as_str()
                            };
                            let buf = vbuf.get_mut(&v).unwrap();
                            if !buf.is_empty()
                                && !buf.ends_with(' ')
                                && !text.starts_with([' ', ',', '.', ';', ':', '!', '?'])
                            {
                                buf.push(' ');
                            }
                            let start = buf.len();
                            buf.push_str(text);
                            has_t.insert(v);
                            rows.push(Row {
                                block: seq,
                                i,
                                kind: "t".into(),
                                num: None,
                                verse: Some(v),
                                start: Some(start),
                                len: Some(text.len()),
                                style: style.clone(),
                                attrs: attrs.clone(),
                                caller: String::new(),
                                text: String::new(),
                            });
                            if let Some(t) = token_of(v, tok_seq, text, style, attrs) {
                                toks.push((t, seq, i));
                                tok_seq += 1;
                            }
                        }
                    }
                    Span::Note {
                        kind,
                        caller,
                        text,
                        attrs,
                    } => rows.push(Row {
                        block: seq,
                        i,
                        kind: kind.to_string(),
                        num: None,
                        // В заголовке привязки к стиху нет — иначе
                        // читатель синтезирует лишний маркер.
                        verse: if heading { None } else { cur },
                        start: if heading {
                            None
                        } else {
                            cur.map(|v| vbuf.get(&v).map_or(0, |b| b.len()))
                        },
                        len: None,
                        style: String::new(),
                        attrs: attrs.clone(),
                        caller: caller.clone(),
                        text: text.clone(),
                    }),
                }
            }
            // Хвостовой пробел в конце незаголовочного блока — как verse_texts().
            if !heading && let Some(v) = cur {
                let buf = vbuf.get_mut(&v).unwrap();
                if !buf.is_empty() && !buf.ends_with(' ') {
                    buf.push(' ');
                }
            }
        }
        // Маркеры 'v' только для стихов без текстовых спанов.
        for (seq, i, n) in vmarks {
            if !has_t.contains(&n) {
                rows.push(Row {
                    block: seq,
                    i,
                    kind: "v".into(),
                    num: Some(n),
                    // verse=None: иначе читатель синтезирует маркер дважды.
                    verse: None,
                    start: None,
                    len: None,
                    style: String::new(),
                    attrs: String::new(),
                    caller: String::new(),
                    text: String::new(),
                });
            }
        }
        {
            let mut bs = self
                .conn
                .prepare_cached("INSERT INTO blocks VALUES(?1, ?2, ?3, ?4)")?;
            let mut ss = self.conn.prepare_cached(
                "INSERT INTO spans VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            )?;
            let mut sp = self
                .conn
                .prepare_cached("INSERT INTO span_pack VALUES(?1, ?2, ?3, ?4)")?;
            let mut tp = self
                .conn
                .prepare_cached("INSERT INTO token_pack VALUES(?1, ?2, ?3, ?4)")?;
            let mut ap = self
                .conn
                .prepare_cached("INSERT INTO align_pack VALUES(?1, ?2, ?3, ?4)")?;
            for (seq, b) in ch.blocks.iter().enumerate() {
                bs.execute(params![book_id, ch.number, seq, b.marker])?;
            }
            // ADR 0022: `t`-спаны уходят в блоб блока, прочие — построчно.
            let mut packs: BTreeMap<usize, Vec<crate::pack::PackedSpan>> = BTreeMap::new();
            for r in &rows {
                if r.kind == "t" {
                    packs
                        .entry(r.block)
                        .or_default()
                        .push(crate::pack::PackedSpan {
                            seq: r.i as u16,
                            verse: r.verse,
                            start: r.start.map(|v| v as u32),
                            len: r.len.map(|v| v as u32),
                            style: r.style.clone(),
                            attrs: r.attrs.clone(),
                            text: r.text.clone(),
                        });
                } else {
                    ss.execute(Self::span_row(
                        book_id, ch.number, r.block, r.i, &r.kind, r.num, r.verse, r.start, r.len,
                        &r.style, &r.attrs, &r.caller, &r.text,
                    ))?;
                }
            }
            let mut wrote_pack = false;
            for (block, entries) in packs {
                sp.execute(params![
                    book_id,
                    ch.number,
                    block,
                    crate::pack::encode_spans(&entries)
                ])?;
                wrote_pack = true;
            }
            // Токены и alignment — блобами по стиху.
            let mut tok_by_v: BTreeMap<u16, Vec<crate::pack::PackedToken>> = BTreeMap::new();
            let mut al_by_v: BTreeMap<u16, Vec<crate::pack::PackedAlign>> = BTreeMap::new();
            for (t, block, i) in &toks {
                tok_by_v
                    .entry(t.verse)
                    .or_default()
                    .push(crate::pack::PackedToken {
                        seq: t.seq,
                        surface: t.surface.clone(),
                        lemma: t.lemma.clone(),
                        strong: t.strong.clone(),
                        morph: t.morph.clone(),
                        gloss: t.gloss.clone(),
                    });
                al_by_v
                    .entry(t.verse)
                    .or_default()
                    .push(crate::pack::PackedAlign {
                        token_seq: t.seq,
                        block: *block as u16,
                        span: *i as u16,
                    });
                self.tokens += 1;
            }
            wrote_pack |= !tok_by_v.is_empty() || !al_by_v.is_empty();
            for (verse, entries) in tok_by_v {
                tp.execute(params![
                    book_id,
                    ch.number,
                    verse,
                    crate::pack::encode_tokens(&entries)
                ])?;
            }
            for (verse, entries) in al_by_v {
                ap.execute(params![
                    book_id,
                    ch.number,
                    verse,
                    crate::pack::encode_align(&entries)
                ])?;
            }
            if wrote_pack {
                self.mark_packed()?;
            }
        }
        let mut vs = self
            .conn
            .prepare_cached("INSERT INTO verses VALUES(?1, ?2, ?3, ?4)")?;
        for (n, text) in &vbuf {
            // Стих 0 без текста не пишется (надписание-пустышка).
            if *n == 0 && text.is_empty() {
                continue;
            }
            vs.execute(params![book_id, ch.number, n, text])?;
        }
        crate::hash::feed(&mut self.hash, book, ch.number, ch);
        Ok(())
    }

    /// Добавить вариант критического аппарата (таблицы
    /// `variants`/`readings`/`witnesses`, ADR 0016). `readings` — все
    /// чтения варианта по порядку; `is_base` помечает чтение основного
    /// текста.
    /// book_id кода по карте `add_book`.
    fn book_id(&self, book: BookCode) -> Result<i64> {
        self.book_ids
            .get(&book)
            .copied()
            .ok_or_else(|| ModuleError::BadFormat(format!("книга {book} без add_book")))
    }

    pub fn add_variant(
        &self,
        book: BookCode,
        chapter: u16,
        verse: u16,
        token_from: u16,
        token_to: u16,
        readings: &[Reading],
    ) -> Result<()> {
        let book_id = self.book_id(book)?;
        let vid: i64 = {
            let mut st = self.conn.prepare_cached(
                "INSERT INTO variants(book_id, chapter, verse, token_from, token_to)
                 VALUES(?1, ?2, ?3, ?4, ?5) RETURNING id",
            )?;
            st.query_row(
                params![book_id, chapter, verse, token_from, token_to],
                |r| r.get(0),
            )?
        };
        let mut rs = self.conn.prepare_cached(
            "INSERT INTO readings(variant_id, seq, text, is_base) VALUES(?1, ?2, ?3, ?4)
             RETURNING id",
        )?;
        let mut ws = self
            .conn
            .prepare_cached("INSERT INTO witnesses VALUES(?1, ?2)")?;
        for (seq, rd) in readings.iter().enumerate() {
            let rid: i64 = rs.query_row(params![vid, seq, rd.text, rd.is_base], |r| r.get(0))?;
            for sig in &rd.witnesses {
                ws.execute(params![rid, sig])?;
            }
        }
        Ok(())
    }

    /// Добавить словарную статью (таблица `entries`, ADR 0016).
    /// `ord` — порядок в словаре (обычно номер строки входа).
    /// `norm` — строчная форма заголовка для поиска; пусто — берётся
    /// сам заголовок в нижнем регистре.
    pub fn add_entry(&self, ord: u32, headword: &str, norm: &str, text: &str) -> Result<()> {
        let norm = if norm.is_empty() {
            headword.to_lowercase()
        } else {
            norm.to_string()
        };
        self.conn.execute(
            "INSERT INTO entries(ord, headword, norm, text) VALUES(?1, ?2, ?3, ?4)",
            params![ord, headword, norm, text],
        )?;
        Ok(())
    }

    /// Добавить метку времени (таблица `marks`, ADR 0016).
    pub fn add_mark(&self, book: BookCode, chapter: u16, mark: &Mark) -> Result<()> {
        let book_id = self.book_id(book)?;
        self.conn.execute(
            "INSERT INTO marks VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                book_id,
                chapter,
                mark.verse,
                mark.seq,
                mark.offset_ms,
                mark.dur_ms,
                mark.text
            ],
        )?;
        Ok(())
    }

    /// Перекрёстная ссылка слоя (ADR 0023): строка `spans` kind='x'
    /// вне блоков (`block=0`), `verse` — стих привязки. У слоя нет
    /// глав и текста — ссылки адресуются напрямую.
    pub fn add_xref(
        &self,
        book: BookCode,
        chapter: u16,
        verse: u16,
        seq: u16,
        text: &str,
    ) -> Result<()> {
        let book_id = self.book_id(book)?;
        self.conn.execute(
            "INSERT INTO spans (book_id,chapter,block,seq,kind,num,verse,start,len,style,attrs,caller,text) \
             VALUES(?1,?2,0,?3,'x',NULL,?4,NULL,NULL,'','','+',?5)",
            params![book_id, chapter, seq, verse, text],
        )?;
        Ok(())
    }

    /// Структурные цели ссылок стиха (`xrefs_pack`, ADR 0023):
    /// `(начало, конец диапазона или начало, votes)` в канонических
    /// координатах `(BookCode, chapter, verse, segment)` версификации
    /// модуля. Порядок целей — порядок в срезе.
    pub fn add_xref_targets(
        &self,
        book: BookCode,
        chapter: u16,
        verse: u16,
        targets: &[(VerseKey, VerseKey, i64)],
    ) -> Result<()> {
        let book_id = self.book_id(book)?;
        let entries: Vec<crate::pack::PackedXref> = targets
            .iter()
            .map(|(a, b, votes)| crate::pack::PackedXref {
                to_book: a.book.as_str().into(),
                to_chapter: a.chapter,
                to_verse: a.verse,
                to_seg: a.segment,
                end_book: (a != b).then(|| b.book.as_str().into()),
                end_chapter: (a != b).then_some(b.chapter),
                end_verse: (a != b).then_some(b.verse),
                end_seg: (a != b).then_some(b.segment),
                votes: *votes,
            })
            .collect();
        let blob = crate::pack::encode_xrefs(&entries);
        self.conn.execute(
            "INSERT INTO xrefs_pack VALUES(?1, ?2, ?3, ?4)",
            params![book_id, chapter, verse, blob],
        )?;
        Ok(())
    }

    /// Запись разметки слоя Стронга (таблица `links`, ADR 0025):
    /// слово стиха цели → dStrong. У слоя нет глав и текста — слова
    /// адресуются (книга, глава, стих, индекс w1) напрямую.
    pub fn add_link(&self, book: BookCode, chapter: u16, link: &Link) -> Result<()> {
        let book_id = self.book_id(book)?;
        self.conn.execute(
            "INSERT INTO links VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                book_id,
                chapter,
                link.verse,
                link.word,
                link.r#ref,
                link.strong,
                link.conf,
                link.flags,
                link.source
            ],
        )?;
        Ok(())
    }

    /// Встроить поисковый индекс FTS5 в модуль (таблица `fts`,
    /// ADR 0016 п. 11). Та же схема и нормализация, что у кэш-индекса
    /// `SearchIndex`; читатель без `fts` строит кэш как раньше.
    /// В `meta.norm_version` пишется версия правил нормализации —
    /// читатель с другой версией откатится на кэш `.idx`.
    pub fn build_search_index(&self) -> Result<()> {
        self.conn.execute_batch(
            "CREATE VIRTUAL TABLE fts USING fts5(
                 book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm,
                 tokenize='unicode61');",
        )?;
        {
            let mut rd = self.conn.prepare(
                "SELECT b.code, v.chapter, v.verse, v.text FROM verses v
                 JOIN books b ON b.book_id = v.book_id",
            )?;
            let mut ins = self
                .conn
                .prepare_cached("INSERT INTO fts VALUES(?1, ?2, ?3, ?4)")?;
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
                    studybible_core::normalize::for_search(
                        &studybible_core::text::collapse_spaces(&text)
                    )
                ])?;
            }
        }
        self.set_meta("norm_version", crate::search::TOKENIZER_VERSION)?;
        Ok(())
    }

    /// Сколько токенов записано (для `meta.features = tokens`).
    pub fn tokens_written(&self) -> usize {
        self.tokens
    }

    /// Пометить модуль упакованным (ADR 0022): `meta.required` получает
    /// `pack`, старые читатели отказывают явно.
    fn mark_packed(&self) -> Result<()> {
        if self.pack_marked.get() {
            return Ok(());
        }
        let cur: String = self
            .conn
            .query_row("SELECT value FROM meta WHERE key='required'", [], |r| {
                r.get(0)
            })
            .unwrap_or_default();
        if cur.split(',').any(|s| s == "pack") {
            self.pack_marked.set(true);
            return Ok(());
        }
        let v = if cur.is_empty() {
            "pack".to_string()
        } else {
            format!("{cur},pack")
        };
        self.conn
            .execute("UPDATE meta SET value=?1 WHERE key='required'", params![v])?;
        self.pack_marked.set(true);
        Ok(())
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
    /// Путь к файлу — нужен SearchIndex для встроенного `fts`.
    path: std::path::PathBuf,
    /// Необязательные таблицы ADR 0016, которые есть в файле.
    has_tokens: bool,
    has_alignment: bool,
    /// ADR 0022: блоб-упаковка (при наличии строк — источник данных).
    has_span_pack: bool,
    has_token_pack: bool,
    has_align_pack: bool,
    /// Есть ли у модуля собственные `x`-спаны (ADR 0023).
    has_xrefs: bool,
    /// Таблица `xrefs_pack` со структурными целями ссылок (ADR 0023).
    has_xref_targets: bool,
    has_variants: bool,
    has_entries: bool,
    has_marks: bool,
    /// Таблица `links` — слой разметки Стронга (ADR 0025).
    has_links: bool,
    /// Виртуальная таблица `fts` (FTS5) — готовый поисковый индекс.
    has_fts: bool,
    /// Код книги → book_id (таблица `books`).
    book_ids: std::collections::HashMap<BookCode, i64>,
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

/// Чтение варианта (таблица `readings` + `witnesses`, ADR 0016).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reading {
    pub text: String,
    /// true — чтение основного текста (базисное).
    pub is_base: bool,
    /// Сиглы свидетелей: рукописи, версии (`MT`, `LXX`, `01`…).
    pub witnesses: Vec<String>,
}

/// Место разночтения со всеми чтениями (таблица `variants`, ADR 0016).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Variant {
    pub book: String,
    pub chapter: u16,
    pub verse: u16,
    /// Диапазон токенов стиха [token_from ..= token_to].
    pub token_from: u16,
    pub token_to: u16,
    pub readings: Vec<Reading>,
}

impl Module {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        Self::finish(conn, path.to_path_buf())
    }

    /// Открыть модуль из байтов в памяти (`sqlite3_deserialize`, read-only).
    /// Нужен для `.sbz`: сжатый файл распаковывается в ОЗУ, распакованной
    /// копии на диске нет. `path` — логический путь источника (для отображения).
    pub fn open_bytes(path: &Path, bytes: &[u8]) -> Result<Self> {
        if bytes.is_empty() {
            return Err(ModuleError::BadFormat("пустой модуль".into()));
        }
        let sz = bytes.len();
        // sqlite3_malloc принимает int: больший размер не выделить,
        // а усечение дало бы буфер меньше копируемых байт.
        let alloc: i32 = match i32::try_from(sz) {
            Ok(n) if sz <= crate::sbz::MAX_UNPACKED => n,
            _ => {
                return Err(ModuleError::BadFormat(format!(
                    "модуль больше {} МиБ",
                    crate::sbz::MAX_UNPACKED >> 20
                )));
            }
        };
        let mut conn = Connection::open_in_memory()?;
        // SAFETY: sqlite3_malloc выделяет буфер ровно на sz байт
        // (sz > 0 и помещается в i32 — проверено выше); копируем в него
        // байты модуля и передаём владение в OwnedData — с флагом
        // FREEONCLOSE SQLite освободит буфер через sqlite3_free при
        // закрытии соединения. Указатели не пересекаются (новый буфер).
        let data = unsafe {
            let ptr = rusqlite::ffi::sqlite3_malloc(alloc);
            if ptr.is_null() {
                return Err(ModuleError::BadFormat("deserialize: нет памяти".into()));
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.cast::<u8>(), sz);
            rusqlite::serialize::OwnedData::from_raw_nonnull(
                std::ptr::NonNull::new_unchecked(ptr.cast::<u8>()),
                sz,
            )
        };
        conn.deserialize(rusqlite::MAIN_DB, data, true)?;
        Self::finish(conn, path.to_path_buf())
    }

    /// Общий хвост `open`/`open_bytes`: защитные pragma, проверка схемы, meta.
    fn finish(conn: Connection, path: PathBuf) -> Result<Self> {
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
        for table in ["meta", "books", "book_headers", "blocks", "spans", "verses"] {
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
            "SELECT book_id, code, ord, title FROM books LIMIT 0",
            "SELECT book_id, marker, text FROM book_headers LIMIT 0",
            "SELECT book_id, chapter, seq, marker FROM blocks LIMIT 0",
            "SELECT book_id, chapter, block, seq, kind, num, verse, start, len, style, attrs, caller, text FROM spans LIMIT 0",
            "SELECT book_id, chapter, verse, text FROM verses LIMIT 0",
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
        // ADR 0022: `pack` поддерживается этим читателем; прочие
        // обязательные возможности — отказ.
        if let Some(req) = meta.required.iter().find(|r| r.as_str() != "pack") {
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
        // FTS5-таблица — виртуальная: у её записи в sqlite_schema
        // есть sql с CREATE VIRTUAL TABLE.
        let has_fts = conn.query_row(
            "SELECT count(*) FROM sqlite_schema
             WHERE name='fts' AND sql LIKE '%VIRTUAL TABLE%'",
            [],
            |r| r.get::<_, i64>(0),
        )? > 0;
        // ADR 0022: pack-таблицы могут существовать пустыми (схема их
        // создаёт всегда) — смотрим на наличие строк.
        let has_pack = |name: &str| -> Result<bool> {
            if !has(name)? {
                return Ok(false);
            }
            Ok(conn.query_row(
                &format!("SELECT count(*) FROM (SELECT 1 FROM {name} LIMIT 1)"),
                [],
                |r| r.get::<_, i64>(0),
            )? > 0)
        };
        let has_span_pack = has_pack("span_pack")?;
        let has_token_pack = has_pack("token_pack")?;
        let has_align_pack = has_pack("align_pack")?;
        // ADR 0023: собственные перекрёстные ссылки — в любом виде
        // (x-спаны всегда построчные, pack их не трогает).
        let has_xrefs = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM spans WHERE kind='x')",
            [],
            |r| r.get(0),
        )?;
        let book_ids = {
            let mut st = conn.prepare("SELECT code, book_id FROM books")?;
            st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
                .collect::<rusqlite::Result<Vec<(String, i64)>>>()?
                .into_iter()
                .filter_map(|(c, id)| BookCode::new(&c).map(|bc| (bc, id)))
                .collect::<std::collections::HashMap<_, _>>()
        };
        Ok(Self {
            path,
            has_tokens: has("tokens")? || has_token_pack,
            has_alignment: has("alignment")? || has_align_pack,
            has_span_pack,
            has_token_pack,
            has_align_pack,
            has_xrefs,
            has_xref_targets: has_pack("xrefs_pack")?,
            has_variants: has("variants")?,
            has_entries: has("entries")?,
            has_marks: has("marks")?,
            has_links: has("links")?,
            has_fts,
            book_ids,
            conn,
            meta,
        })
    }

    /// book_id кода книги; None — книги нет в модуле.
    fn bid(&self, book: BookCode) -> Option<i64> {
        self.book_ids.get(&book).copied()
    }

    pub fn meta(&self) -> &Meta {
        &self.meta
    }

    /// Для тестов и кода, которому нужен прямой доступ к соединению (только чтение).
    #[doc(hidden)]
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Путь к файлу модуля.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Есть ли в модуле встроенный индекс FTS5 (таблица `fts`).
    pub fn has_search_index(&self) -> bool {
        self.has_fts
    }

    /// Метки времени главы (таблица `marks`, ADR 0016). Пусто —
    /// у модулей без таблицы.
    pub fn marks(&self, book: BookCode, chapter: u16) -> Result<Vec<Mark>> {
        if !self.has_marks {
            return Ok(vec![]);
        }
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        let mut st = self.conn.prepare(
            "SELECT verse, seq, offset_ms, dur_ms, text FROM marks
             WHERE book_id=?1 AND chapter=?2 ORDER BY verse, seq",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok(Mark {
                verse: r.get::<_, u16>(0)?,
                seq: r.get::<_, u16>(1)?,
                offset_ms: r.get::<_, u32>(2)?,
                dur_ms: r.get::<_, Option<u32>>(3)?,
                text: r.get(4)?,
            })
        })?;
        let mut out = Vec::new();
        for m in rows {
            out.push(m?);
        }
        Ok(out)
    }

    /// Книги в порядке модуля: код и заголовок.
    /// Есть ли в модуле собственные `x`-спаны. Если нет — мост может
    /// подмешать ссылки общего слоя (ADR 0023).
    pub fn has_xrefs(&self) -> bool {
        self.has_xrefs
    }

    /// Перекрёстные ссылки главы как (стих, текст): строки `spans`
    /// kind='x' с заданным `verse`. Используется и модулем-слоем
    /// (`block=0`), и для чтения чужих x-строк вне потока.
    pub fn xrefs(&self, book: BookCode, chapter: u16) -> Result<Vec<(u16, String)>> {
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        let mut st = self.conn.prepare(
            "SELECT verse, text FROM spans
             WHERE book_id=?1 AND chapter=?2 AND kind='x' AND verse IS NOT NULL
             ORDER BY block, seq",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok((r.get::<_, u16>(0)?, r.get::<_, String>(1)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Разметка Стронга главы (таблица `links`, ADR 0025): записи
    /// слоя `kind='layer'`/`features='strongs'` в координатах целевого
    /// текста. Применяется вызывающим только при совпадении
    /// `target_id`+`target_hash`+`tokenizer` из meta слоя с модулем.
    pub fn links(&self, book: BookCode, chapter: u16) -> Result<Vec<Link>> {
        if !self.has_links {
            return Ok(vec![]);
        }
        let Some(bid) = self.bid(book).or_else(|| {
            studybible_core::BookCatalog::builtin()
                .by_code(book)
                .and_then(|b| b.order_list)
                .map(i64::from)
        }) else {
            return Ok(vec![]);
        };
        let mut st = self.conn.prepare(
            "SELECT verse, word, ref, strong, conf, flags, source FROM links
             WHERE book_id=?1 AND chapter=?2 ORDER BY verse, word",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok(Link {
                verse: r.get(0)?,
                word: r.get(1)?,
                r#ref: r.get(2)?,
                strong: r.get(3)?,
                conf: r.get(4)?,
                flags: r.get(5)?,
                source: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Есть ли таблица `links` (ADR 0025).
    pub fn has_links(&self) -> bool {
        self.has_links
    }

    /// Структурные цели перекрёстных ссылок главы (таблица `xrefs`,
    /// ADR 0023): цели в канонических координатах версификации модуля.
    /// Для модулей без таблицы (старые `.sb`) — пусто.
    pub fn xref_targets(&self, book: BookCode, chapter: u16) -> Result<Vec<XrefTarget>> {
        if !self.has_xref_targets {
            return Ok(vec![]);
        }
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        let mut st = self.conn.prepare(
            "SELECT verse, blob FROM xrefs_pack
             WHERE book_id=?1 AND chapter=?2 ORDER BY verse",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok((r.get::<_, u16>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let point = |b: &str, c: u16, v: u16, s: u8| -> Option<VerseKey> {
            Some(VerseKey::with_segment(BookCode::new(b)?, c, v, s))
        };
        let mut out = Vec::new();
        for r in rows {
            let (verse, blob) = r?;
            for e in crate::pack::decode_xrefs(&blob)? {
                out.push(XrefTarget {
                    verse,
                    to: point(&e.to_book, e.to_chapter, e.to_verse, e.to_seg).ok_or(
                        ModuleError::BadFormat("xrefs_pack: невалидный код книги".into()),
                    )?,
                    end: match (e.end_book, e.end_chapter, e.end_verse, e.end_seg) {
                        (Some(b), Some(c), Some(v), Some(s)) => point(&b, c, v, s),
                        _ => None,
                    },
                    votes: e.votes,
                });
            }
        }
        Ok(out)
    }

    /// Таблица `xrefs_pack` со структурными целями ссылок есть в файле.
    pub fn has_xref_targets(&self) -> bool {
        self.has_xref_targets
    }

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
        let Some(bid) = self.bid(book) else {
            return Ok(None);
        };
        self.conn
            .query_row(
                "SELECT text FROM book_headers WHERE book_id=?1 AND marker=?2",
                params![bid, marker],
                |r| r.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    /// Пересчёт `meta.content_hash` по читаемому потоку (spec/05 С-12).
    /// Нужен инструментам, правящим уже собранный модуль (inject_xrefs):
    /// хэш обязан покрывать их правки. Совпадает с тем, что пишет
    /// `ModuleWriter`, если поток после чтения идентичен исходному.
    pub fn compute_content_hash(&self) -> Result<String> {
        let mut h = crate::hash::new();
        for (code, _) in self.books()? {
            let bid = self
                .bid(code)
                .ok_or_else(|| ModuleError::BadFormat(format!("{code}: нет book_id")))?;
            let mut st = self
                .conn
                .prepare("SELECT DISTINCT chapter FROM blocks WHERE book_id=?1 ORDER BY chapter")?;
            let chapters: Vec<u16> = st
                .query_map(params![bid], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            for n in chapters {
                if let Some(ch) = self.chapter(code, n)? {
                    crate::hash::feed(&mut h, code, n, &ch);
                }
            }
        }
        Ok(crate::hash::hex(h.finalize()))
    }

    /// Поток чтения главы.
    ///
    /// `v`-маркеров у обычных стихов в файле нет (компактная схема,
    /// ADR 0016 п. 15): граница синтезируется по смене `verse` у спанов —
    /// маркер ставится перед первым спаном стиха, как в исходном потоке.
    /// Стих 0 (надписание) маркер не получает, как и раньше.
    pub fn chapter(&self, book: BookCode, chapter: u16) -> Result<Option<Chapter>> {
        let Some(bid) = self.bid(book) else {
            return Ok(None);
        };
        // Сырой текст стихов для нарезки спанов (версия до collapse_spaces).
        let vtexts: std::collections::HashMap<u16, String> = {
            let mut vt = self
                .conn
                .prepare("SELECT verse, text FROM verses WHERE book_id=?1 AND chapter=?2")?;
            vt.query_map(params![bid, chapter], |r| {
                Ok((r.get::<_, u16>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<_>>()?
        };
        let mut bs = self.conn.prepare(
            "SELECT seq, marker FROM blocks WHERE book_id=?1 AND chapter=?2 ORDER BY seq",
        )?;
        let mut ss = self.conn.prepare(
            "SELECT seq, kind, num, verse, start, len, style, attrs, caller, text FROM spans
             WHERE book_id=?1 AND chapter=?2 AND block=?3 ORDER BY seq",
        )?;
        let mut ps = if self.has_span_pack {
            Some(self.conn.prepare(
                "SELECT blob FROM span_pack WHERE book_id=?1 AND chapter=?2 AND block=?3",
            )?)
        } else {
            None
        };
        let mut ch = Chapter {
            number: chapter,
            blocks: vec![],
        };
        let mut empty = true;
        let mut cur: Option<u16> = None;
        let blocks = bs.query_map(params![bid, chapter], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?;
        for b in blocks {
            let (seq, marker) = b?;
            empty = false;
            let mut block = Block {
                marker,
                spans: vec![],
            };
            // Сливаем построчные спаны (f/x/v) и распакованные `t`
            // по позиции seq внутри блока (ADR 0022).
            type SpanRow = (
                u16,
                String,
                Option<u16>,
                Option<u16>,
                Option<i64>,
                Option<i64>,
                String,
                String,
                String,
                String,
            );
            let mut merged: Vec<SpanRow> = Vec::new();
            let spans = ss.query_map(params![bid, chapter, seq], |r| {
                Ok((
                    r.get::<_, u16>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<u16>>(2)?,
                    r.get::<_, Option<u16>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                    r.get::<_, Option<i64>>(5)?,
                    r.get::<_, String>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                    r.get::<_, String>(9)?,
                ))
            })?;
            for s in spans {
                merged.push(s?);
            }
            if let Some(ps) = &mut ps {
                let blob: Option<Vec<u8>> =
                    ps.query_row(params![bid, chapter, seq], |r| r.get(0)).ok();
                if let Some(blob) = blob {
                    for e in crate::pack::decode_spans(&blob)? {
                        merged.push((
                            e.seq,
                            "t".to_string(),
                            None,
                            e.verse,
                            e.start.map(|v| v as i64),
                            e.len.map(|v| v as i64),
                            e.style,
                            e.attrs,
                            String::new(),
                            e.text,
                        ));
                    }
                    merged.sort_by_key(|s| s.0);
                }
            }
            for s in merged {
                let (_seq, kind, num, verse, start, len, style, attrs, caller, text) = s;
                // Маркер границы: спан принадлежит новому ненулевому стиху.
                if let Some(v) = verse
                    && v != 0
                    && cur != Some(v)
                {
                    block.spans.push(Span::Verse(v));
                    cur = Some(v);
                } else if let Some(v) = verse {
                    cur = Some(v);
                }
                match kind.as_str() {
                    "v" => block.spans.push(Span::Verse(num.unwrap_or_default())),
                    "t" => {
                        let text = match (verse, start, len) {
                            (Some(v), Some(st), Some(ln)) => slice_of(&vtexts, v, st, ln)
                                .ok_or_else(|| {
                                    ModuleError::BadFormat(format!(
                                        "{book} {chapter}:{v}: срез ({st},{ln}) вне текста стиха"
                                    ))
                                })?
                                .to_string(),
                            _ => text,
                        };
                        block.spans.push(Span::Text { text, style, attrs });
                    }
                    "f" | "x" => block.spans.push(Span::Note {
                        kind: kind.chars().next().unwrap_or('f'),
                        caller,
                        text,
                        attrs,
                    }),
                    _ => {}
                }
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
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        if self.has_token_pack {
            let mut st = self.conn.prepare(
                "SELECT verse, blob FROM token_pack
                 WHERE book_id=?1 AND chapter=?2 ORDER BY verse",
            )?;
            let rows = st.query_map(params![bid, chapter], |r| {
                Ok((r.get::<_, u16>(0)?, r.get::<_, Vec<u8>>(1)?))
            })?;
            let mut out = Vec::new();
            for r in rows {
                let (verse, blob) = r?;
                for e in crate::pack::decode_tokens(&blob)? {
                    out.push(Token {
                        verse,
                        seq: e.seq,
                        surface: e.surface,
                        lemma: e.lemma,
                        strong: e.strong,
                        morph: e.morph,
                        gloss: e.gloss,
                    });
                }
            }
            return Ok(out);
        }
        let mut st = self.conn.prepare(
            "SELECT verse, seq, surface, lemma, strong, morph, gloss
             FROM tokens WHERE book_id=?1 AND chapter=?2 ORDER BY verse, seq",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok(Token {
                verse: r.get::<_, u16>(0)?,
                seq: r.get::<_, u16>(1)?,
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
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        if self.has_align_pack {
            let mut st = self.conn.prepare(
                "SELECT verse, blob FROM align_pack
                 WHERE book_id=?1 AND chapter=?2 ORDER BY verse",
            )?;
            let rows = st.query_map(params![bid, chapter], |r| {
                Ok((r.get::<_, u16>(0)?, r.get::<_, Vec<u8>>(1)?))
            })?;
            let mut out = Vec::new();
            for r in rows {
                let (verse, blob) = r?;
                for e in crate::pack::decode_align(&blob)? {
                    out.push(Alignment {
                        verse,
                        token_seq: e.token_seq,
                        block: e.block,
                        span: e.span,
                    });
                }
            }
            return Ok(out);
        }
        let mut st = self.conn.prepare(
            "SELECT verse, token_seq, block, span FROM alignment
             WHERE book_id=?1 AND chapter=?2 ORDER BY verse, token_seq",
        )?;
        let rows = st.query_map(params![bid, chapter], |r| {
            Ok(Alignment {
                verse: r.get::<_, u16>(0)?,
                token_seq: r.get::<_, u16>(1)?,
                block: r.get::<_, u16>(2)?,
                span: r.get::<_, u16>(3)?,
            })
        })?;
        let mut out = Vec::new();
        for a in rows {
            out.push(a?);
        }
        Ok(out)
    }

    /// Варианты аппарата главы с чтениями и свидетелями.
    /// Пусто — у модулей без таблицы `variants`.
    pub fn variants(&self, book: BookCode, chapter: u16) -> Result<Vec<Variant>> {
        if !self.has_variants {
            return Ok(vec![]);
        }
        let Some(bid) = self.bid(book) else {
            return Ok(vec![]);
        };
        let mut vs = self.conn.prepare(
            "SELECT id, verse, token_from, token_to FROM variants
             WHERE book_id=?1 AND chapter=?2 ORDER BY verse, token_from",
        )?;
        let mut rs = self.conn.prepare(
            "SELECT id, seq, text, is_base FROM readings
             WHERE variant_id=?1 ORDER BY seq",
        )?;
        let mut ws = self
            .conn
            .prepare("SELECT siglum FROM witnesses WHERE reading_id=?1 ORDER BY siglum")?;
        let variants = vs.query_map(params![bid, chapter], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, u16>(1)?,
                r.get::<_, u16>(2)?,
                r.get::<_, u16>(3)?,
            ))
        })?;
        let mut out = Vec::new();
        for v in variants {
            let (_id, verse, tf, tt) = v?;
            let readings = rs.query_map(params![_id], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, bool>(3)?,
                ))
            })?;
            let mut rd_list = Vec::new();
            for rd in readings {
                let (rid, text, is_base) = rd?;
                let sigs = ws.query_map(params![rid], |r| r.get::<_, String>(0))?;
                let mut witnesses = Vec::new();
                for s in sigs {
                    witnesses.push(s?);
                }
                rd_list.push(Reading {
                    text,
                    is_base,
                    witnesses,
                });
            }
            out.push(Variant {
                book: book.as_str().to_string(),
                chapter,
                verse,
                token_from: tf,
                token_to: tt,
                readings: rd_list,
            });
        }
        Ok(out)
    }

    /// Число словарных статей (таблица `entries`, ADR 0016).
    /// 0 у модулей без словаря.
    pub fn entries_count(&self) -> Result<u64> {
        if !self.has_entries {
            return Ok(0);
        }
        Ok(self
            .conn
            .query_row("SELECT count(*) FROM entries", [], |r| r.get::<_, i64>(0))?
            as u64)
    }

    /// Страница словаря: (ord, заголовок) от `offset`, не больше `limit`.
    /// `prefix` — фильтр по началу `norm` (строчная форма).
    pub fn entries(&self, offset: u64, limit: u64, prefix: &str) -> Result<Vec<(u32, String)>> {
        if !self.has_entries {
            return Ok(vec![]);
        }
        let mut st = self.conn.prepare(
            "SELECT ord, headword FROM entries
             WHERE norm LIKE ?1 || '%' ESCAPE '\\' ORDER BY ord LIMIT ?2 OFFSET ?3",
        )?;
        // `%`/`_`/`\` в префиксе — буквально, не шаблон LIKE.
        let pat = prefix
            .to_lowercase()
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_");
        let rows = st.query_map(params![pat, limit, offset], |r| {
            Ok((r.get::<_, u32>(0)?, r.get::<_, String>(1)?))
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Статья словаря по `ord`: (заголовок, текст). None — нет такой.
    pub fn entry(&self, ord: u32) -> Result<Option<(String, String)>> {
        if !self.has_entries {
            return Ok(None);
        }
        let mut st = self
            .conn
            .prepare("SELECT headword, text FROM entries WHERE ord=?1")?;
        let mut rows = st.query(params![ord])?;
        match rows.next()? {
            Some(r) => Ok(Some((r.get::<_, String>(0)?, r.get::<_, String>(1)?))),
            None => Ok(None),
        }
    }

    /// Плоский текст стиха. В `verses` хранится сырой канонический текст
    /// (источник `start`/`len` спанов), снаружи — свёрнутый, как раньше.
    pub fn verse_text(&self, book: BookCode, chapter: u16, verse: u16) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT text FROM verses WHERE book_id=?1 AND chapter=?2 AND verse=?3",
                params![self.bid(book).unwrap_or(-1), chapter, verse],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map(|o| o.map(|t| studybible_core::text::collapse_spaces(&t)))
            .map_err(Into::into)
    }
}

/// Байтовый срез `(start, len)` текста стиха `v`; None — стиха нет,
/// смещения отрицательные, переполняются или режут символ UTF-8.
fn slice_of(
    vtexts: &std::collections::HashMap<u16, String>,
    v: u16,
    start: i64,
    len: i64,
) -> Option<&str> {
    let st = usize::try_from(start).ok()?;
    let end = st.checked_add(usize::try_from(len).ok()?)?;
    vtexts.get(&v)?.get(st..end)
}

use rusqlite::OptionalExtension;
