//! Конвертер TSV → поток чтения (ADR 0016): простой вход для авторов
//! подстрочников и слоёв без SQL и без разметки.
//!
//! Строка таблицы (поля через табуляцию, `#` в начале — комментарий):
//!
//! ```text
//! КОД_КНИГИ ГЛАВА:СТИХ <TAB> слово-оригинала <TAB> глосса [<TAB> лемма <TAB> стронг <TAB> морф]
//! ```
//!
//! Повторная ссылка добавляет ещё одну пару в тот же стих.
//! Каждый стих — блок `p`: маркер стиха, затем спаны `w` с
//! `attrs gr="оригинал" lemma/strong/morph`; текст спана — глосса.
//! Таблицы `tokens` и `alignment` заполняет записыватель сам.

use std::collections::BTreeMap;

use studybible_core::BookCode;
use studybible_core::text::{Block, Chapter, Span};

use crate::usfm;

/// Одна строка TSV.
struct Row {
    book: BookCode,
    chapter: u16,
    verse: u16,
    orig: String,
    gloss: String,
    lemma: String,
    strong: String,
    morph: String,
}

fn parse_ref(s: &str) -> Result<(BookCode, u16, u16), usfm::Error> {
    // «GEN 1:1» / «GEN 1:1a» — букву части пока отбрасываем
    // (части стиха — позиция в потоке, не координата токена).
    let (code_s, rest) = s
        .trim()
        .split_once(' ')
        .ok_or_else(|| usfm::Error(format!("TSV: нет пробела в ссылке «{s}»")))?;
    let code = BookCode::new(code_s.trim())
        .ok_or_else(|| usfm::Error(format!("TSV: код книги «{code_s}»")))?;
    let (ch_s, v_s) = rest
        .trim()
        .split_once(':')
        .ok_or_else(|| usfm::Error(format!("TSV: ссылка без «гл:ст» — «{s}»")))?;
    let ch: u16 = ch_s
        .trim()
        .parse()
        .map_err(|_| usfm::Error(format!("TSV: глава «{ch_s}»")))?;
    let v_s = v_s
        .trim()
        .trim_end_matches(|c: char| c.is_ascii_lowercase());
    let v: u16 = v_s
        .parse()
        .map_err(|_| usfm::Error(format!("TSV: стих «{v_s}»")))?;
    Ok((code, ch, v))
}

fn quote_attr(k: &str, v: &str) -> String {
    if v.is_empty() {
        String::new()
    } else {
        format!(" {k}=\"{}\"", v.replace('"', "'"))
    }
}

/// Разобрать TSV-таблицу в список книг (в порядке первого появления).
pub fn parse(src: &str) -> Result<Vec<usfm::Book>, usfm::Error> {
    // (код книги, глава, стих) → пары для сохранения порядка строк.
    let mut rows: Vec<Row> = Vec::new();
    for (ln, line) in src.lines().enumerate() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            return Err(usfm::Error(format!(
                "TSV строка {}: меньше 3 полей: «{line}»",
                ln + 1
            )));
        }
        let (book, chapter, verse) =
            parse_ref(f[0]).map_err(|e| usfm::Error(format!("TSV строка {}: {}", ln + 1, e.0)))?;
        rows.push(Row {
            book,
            chapter,
            verse,
            orig: f[1].trim().to_string(),
            gloss: f[2].trim().to_string(),
            lemma: f.get(3).map(|s| s.trim().to_string()).unwrap_or_default(),
            strong: f.get(4).map(|s| s.trim().to_string()).unwrap_or_default(),
            morph: f.get(5).map(|s| s.trim().to_string()).unwrap_or_default(),
        });
    }
    if rows.is_empty() {
        return Err(usfm::Error("TSV: нет строк данных".into()));
    }

    // Группировка: книга → глава → стих → пары. Порядок книг — по первому
    // появлению в файле; главы и стихи — по номерам.
    let mut order: Vec<BookCode> = Vec::new();
    let mut books: BTreeMap<String, BTreeMap<u16, BTreeMap<u16, Vec<&Row>>>> = BTreeMap::new();
    for r in &rows {
        let key = r.book.as_str().to_string();
        if !books.contains_key(&key) {
            order.push(r.book);
        }
        books
            .entry(key)
            .or_default()
            .entry(r.chapter)
            .or_default()
            .entry(r.verse)
            .or_default()
            .push(r);
    }

    let mut out = Vec::new();
    for code in order {
        let mut book = usfm::Book {
            code,
            ..usfm::Book::default()
        };
        book.header.insert("id".into(), code.as_str().to_string());
        book.header.insert("h".into(), code.as_str().to_string());
        let chs = &books[code.as_str()];
        for (ch_n, verses) in chs {
            let mut ch = Chapter {
                number: *ch_n,
                blocks: vec![],
            };
            for (v_n, pairs) in verses {
                let mut spans = vec![Span::Verse(*v_n)];
                for r in pairs {
                    let attrs = format!(
                        "gr=\"{}\"{}{}{}",
                        r.orig.replace('"', "'"),
                        quote_attr("lemma", &r.lemma),
                        quote_attr("strong", &r.strong),
                        quote_attr("morph", &r.morph),
                    );
                    spans.push(Span::Text {
                        text: format!("{} ", r.gloss),
                        style: "w".into(),
                        attrs,
                    });
                }
                ch.blocks.push(Block {
                    marker: "p".into(),
                    spans,
                });
            }
            book.chapters.push(ch);
        }
        out.push(book);
    }
    Ok(out)
}

// ---------- критический аппарат (variants.tsv) ----------

/// Чтение варианта: текст и сиглы свидетелей (ADR 0016).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReadingInput {
    pub text: String,
    /// true — чтение основного текста.
    pub is_base: bool,
    pub witnesses: Vec<String>,
}

/// Вариант для записи: место (стих + диапазон токенов) и чтения.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VariantInput {
    pub book: BookCode,
    pub chapter: u16,
    pub verse: u16,
    pub token_from: u16,
    pub token_to: u16,
    pub readings: Vec<ReadingInput>,
}

/// Разобрать TSV аппарата: `REF <TAB> от-до <TAB> чтение <TAB> 0|1
/// <TAB> свидетели-через-пробел`. Строки с одной ссылкой и диапазоном —
/// чтения одного варианта.
pub fn parse_variants(src: &str) -> Result<Vec<VariantInput>, usfm::Error> {
    let mut out: Vec<VariantInput> = Vec::new();
    for (ln, line) in src.lines().enumerate() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            return Err(usfm::Error(format!(
                "TSV аппарата, строка {}: меньше 3 полей: «{line}»",
                ln + 1
            )));
        }
        let (book, chapter, verse) =
            parse_ref(f[0]).map_err(|e| usfm::Error(format!("TSV строка {}: {}", ln + 1, e.0)))?;
        let (from_s, to_s) = f[1].trim().split_once('-').unwrap_or((f[1], f[1]));
        let token_from: u16 = from_s
            .trim()
            .parse()
            .map_err(|_| usfm::Error(format!("TSV строка {}: токен «{from_s}»", ln + 1)))?;
        let token_to: u16 = to_s
            .trim()
            .parse()
            .map_err(|_| usfm::Error(format!("TSV строка {}: токен «{to_s}»", ln + 1)))?;
        let reading = ReadingInput {
            text: f[2].trim().to_string(),
            is_base: matches!(f.get(3).map(|s| s.trim()), Some("1") | Some("base")),
            witnesses: f
                .get(4)
                .map(|s| s.split_whitespace().map(String::from).collect::<Vec<_>>())
                .unwrap_or_default(),
        };
        // То же место и диапазон — чтение того же варианта.
        if let Some(v) = out.iter_mut().find(|v| {
            v.book == book
                && v.chapter == chapter
                && v.verse == verse
                && v.token_from == token_from
                && v.token_to == token_to
        }) {
            v.readings.push(reading);
        } else {
            out.push(VariantInput {
                book,
                chapter,
                verse,
                token_from,
                token_to,
                readings: vec![reading],
            });
        }
    }
    Ok(out)
}

// ---------- словарь (entries TSV) ----------

/// Словарная статья из TSV (ADR 0016).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EntryInput {
    /// Заголовок статьи (как показывать).
    pub headword: String,
    /// Строчная форма для поиска; пусто — выводится из заголовка.
    pub norm: String,
    /// Текст статьи (может содержать `\n` — абзацы).
    pub text: String,
}

/// Разобрать TSV словаря: `заголовок <TAB> текст [<TAB> норм-форма]`.
/// Порядок строк = порядок в словаре (`ord`). Пустые строки и `#` —
/// комментарии.
pub fn parse_entries(src: &str) -> Result<Vec<EntryInput>, usfm::Error> {
    let mut out = Vec::new();
    for (ln, line) in src.lines().enumerate() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 2 {
            return Err(usfm::Error(format!(
                "TSV словаря, строка {}: меньше 2 полей: «{line}»",
                ln + 1
            )));
        }
        let headword = f[0].trim();
        if headword.is_empty() {
            return Err(usfm::Error(format!(
                "TSV словаря, строка {}: пустой заголовок",
                ln + 1
            )));
        }
        out.push(EntryInput {
            headword: headword.to_string(),
            text: f[1].trim().to_string(),
            norm: f.get(2).map(|s| s.trim().to_string()).unwrap_or_default(),
        });
    }
    if out.is_empty() {
        return Err(usfm::Error("TSV словаря: нет статей".into()));
    }
    Ok(out)
}

// ---------- метки времени (marks TSV) ----------

/// Метка времени из TSV (ADR 0016): позиция в аудиодорожке главы.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MarkInput {
    pub book: BookCode,
    pub chapter: u16,
    pub verse: u16,
    /// Порядок внутри стиха (порядок строки для этого стиха).
    pub seq: u16,
    /// Смещение от начала дорожки главы, мс.
    pub offset_ms: u32,
    /// Длительность, мс; None — звучит до следующей метки.
    pub dur_ms: Option<u32>,
    /// Слово/фраза метки (может быть пустым).
    pub text: String,
}

/// Разобрать TSV меток: `REF <TAB> смещение_мс [<TAB> длит_мс]
/// [<TAB> слово]`. Пустая длительность — «до следующей метки».
/// `seq` — счётчик строк внутри стиха.
pub fn parse_marks(src: &str) -> Result<Vec<MarkInput>, usfm::Error> {
    let mut out: Vec<MarkInput> = Vec::new();
    for (ln, line) in src.lines().enumerate() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 2 {
            return Err(usfm::Error(format!(
                "TSV меток, строка {}: меньше 2 полей: «{line}»",
                ln + 1
            )));
        }
        let (book, chapter, verse) =
            parse_ref(f[0]).map_err(|e| usfm::Error(format!("TSV строка {}: {}", ln + 1, e.0)))?;
        let offset_ms: u32 = f[1].trim().parse().map_err(|_| {
            usfm::Error(format!("TSV строка {}: смещение «{}»", ln + 1, f[1].trim()))
        })?;
        let dur_ms = f
            .get(2)
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| {
                s.parse::<u32>()
                    .map_err(|_| usfm::Error(format!("TSV строка {}: длительность «{s}»", ln + 1)))
            })
            .transpose()?;
        let seq = out
            .iter()
            .filter(|m| m.book == book && m.chapter == chapter && m.verse == verse)
            .count() as u16;
        out.push(MarkInput {
            book,
            chapter,
            verse,
            seq,
            offset_ms,
            dur_ms,
            text: f.get(3).map(|s| s.trim().to_string()).unwrap_or_default(),
        });
    }
    Ok(out)
}
