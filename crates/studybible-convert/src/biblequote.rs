//! Источник BibleQuote (модули «Цитаты из Библии»): каталог (или .zip)
//! с `bibleqt.ini` и htm-файлами книг.
//!
//! `bibleqt.ini` — INI: глобальные ключи (`BibleName`, `Bible` = Y/N,
//! `ChapterSign`, `VerseSign`, `StrongNumbers`, `DefaultEncoding`,
//! `BookQty`), далее секции книг с `PathName`, `FullName`,
//! `ShortName`, `ChapterQty`. Кодировка файлов: UTF-8 (с BOM или
//! валидный), иначе windows-1251.
//!
//! Файл книги (`PathName`): главы отделяются строкой с `ChapterSign`,
//! стихи — `VerseSign`; номер стиха — число в начале текста стиха
//! (или подряд, если числа нет). `StrongNumbers=Y` — `<S>N</S>` после
//! слов → strong (H по ВЗ, G по НЗ). `Bible=N` — комментарий: секции
//! «Стихи a-b» / «Стих a» привязываются к первому стиху диапазона.
//!
//! Книга → код каталога по `ShortName`/`FullName` во всех профилях
//! названий (как у zefania); несопоставленная книга — ошибка.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use studybible_core::BookCode;
use studybible_core::book::{BookCatalog, NameProfile};
use studybible_core::text::{Block, Chapter, Span};

use crate::mybible;
use crate::usfm;

fn err(e: impl std::fmt::Display) -> usfm::Error {
    usfm::Error(format!("BibleQuote: {e}"))
}

/// Файлы модуля: из каталога или zip-архива (ключ — имя в unix-виде).
enum Source {
    Dir(PathBuf),
    Zip(zip::ZipArchive<std::fs::File>),
}

impl Source {
    fn open(path: &Path) -> Result<Self, usfm::Error> {
        if path.is_dir() {
            return Ok(Self::Dir(path.to_path_buf()));
        }
        let f = std::fs::File::open(path).map_err(err)?;
        Ok(Self::Zip(zip::ZipArchive::new(f).map_err(err)?))
    }

    /// Байты файла по относительному имени (без учёта регистра и слэшей).
    fn bytes(&mut self, name: &str) -> Result<Vec<u8>, usfm::Error> {
        let norm = name.replace('\\', "/").to_lowercase();
        match self {
            Self::Dir(d) => {
                let p = d.join(name);
                if p.is_file() {
                    return std::fs::read(&p).map_err(err);
                }
                // Регистр/разделители могут отличаться — ищем сами.
                if let Ok(entries) = std::fs::read_dir(d) {
                    for e in entries.flatten() {
                        if e.file_name().to_string_lossy().to_lowercase()
                            == norm.rsplit('/').next().unwrap_or(&norm)
                        {
                            return std::fs::read(e.path()).map_err(err);
                        }
                    }
                }
                Err(err(format!("нет файла {name}")))
            }
            Self::Zip(z) => {
                for i in 0..z.len() {
                    let mut f = z.by_index(i).map_err(err)?;
                    if f.name().replace('\\', "/").to_lowercase().ends_with(&norm) {
                        let mut buf = Vec::new();
                        f.read_to_end(&mut buf).map_err(err)?;
                        return Ok(buf);
                    }
                }
                Err(err(format!("в архиве нет {name}")))
            }
        }
    }

    /// Имена файлов в подкаталоге (когда PathName книги — папка глав).
    fn list(&mut self, dir: &str) -> Vec<(String, Vec<u8>)> {
        let mut out = Vec::new();
        let norm = dir.replace('\\', "/").trim_matches('/').to_lowercase();
        match self {
            Self::Dir(d) => {
                let p = d.join(dir);
                if p.is_dir()
                    && let Ok(entries) = std::fs::read_dir(&p)
                {
                    for e in entries.flatten() {
                        if e.path().is_file()
                            && let Ok(b) = std::fs::read(e.path())
                        {
                            out.push((e.file_name().to_string_lossy().to_string(), b));
                        }
                    }
                }
            }
            Self::Zip(z) => {
                for i in 0..z.len() {
                    let Ok(mut f) = z.by_index(i) else { continue };
                    let n = f.name().replace('\\', "/").to_lowercase();
                    if n.starts_with(&format!("{norm}/")) && !n.ends_with('/') {
                        let mut buf = Vec::new();
                        if f.read_to_end(&mut buf).is_ok() {
                            out.push((f.name().to_string(), buf));
                        }
                    }
                }
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }
}

/// Декодирование файла модуля: UTF-8 (BOM или валидный), иначе cp1251.
fn decode(bytes: &[u8]) -> String {
    let no_bom = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    if let Ok(s) = std::str::from_utf8(no_bom) {
        return s.to_string();
    }
    let (s, _, _) = encoding_rs::WINDOWS_1251.decode(bytes);
    s.into_owned()
}

/// Простой разбор bibleqt.ini: `[секция]`, `ключ=значение`.
struct Ini {
    global: BTreeMap<String, String>,
    /// Пары ключ=значение верхнего уровня в порядке следования
    /// (BibleQuote 7 описывает книги повторяющимися группами ключей
    /// без `[секций]`: новая книга начинается с `PathName`).
    order: Vec<(String, String)>,
    /// Секции книг `[Имя]` (старый формат ini).
    books: Vec<BTreeMap<String, String>>,
}

impl Ini {
    fn parse(text: &str) -> Self {
        let mut ini = Ini {
            global: BTreeMap::new(),
            order: vec![],
            books: vec![],
        };
        let mut cur: Option<&mut BTreeMap<String, String>> = None;
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty()
                || line.starts_with(';')
                || line.starts_with('#')
                || line.starts_with("//")
            {
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                ini.books.push(BTreeMap::new());
                cur = ini.books.last_mut();
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let (k, v) = (k.trim().to_lowercase(), v.trim().to_string());
                match cur.as_deref_mut() {
                    Some(sec) => {
                        sec.insert(k, v);
                    }
                    None => {
                        ini.order.push((k.clone(), v.clone()));
                        ini.global.entry(k).or_insert(v);
                    }
                }
            }
        }
        ini
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.global.get(key).map(String::as_str)
    }

    /// Секции книг: `[Имя]`-секции, либо повторяющиеся группы ключей
    /// верхнего уровня (новая книга — от каждого `PathName`).
    fn book_sections(&self) -> Vec<BTreeMap<String, String>> {
        if !self.books.is_empty() {
            return self.books.clone();
        }
        let mut out: Vec<BTreeMap<String, String>> = Vec::new();
        for (k, v) in &self.order {
            if k == "pathname" {
                out.push(BTreeMap::new());
            }
            if let Some(sec) = out.last_mut() {
                sec.entry(k.clone()).or_insert_with(|| v.clone());
            }
        }
        out
    }
}

/// Варианты имени книги: исходное + с порядковым числительным
/// словом в цифру («Первая книга Царств» → «1 книга Царств»,
/// «1 Царств»; «1-е Послание Петра» → «1 Послание Петра») —
/// в синодальной нумерации 1–4 Царств = 1–2 Цар + 3–4 Цар.
fn name_variants(name: &str) -> Vec<String> {
    let mut out = vec![name.to_string()];
    let low = name.to_lowercase();
    for (word, digit) in [
        ("первая", "1"),
        ("первое", "1"),
        ("перваго", "1"),
        ("1-я", "1"),
        ("1-е", "1"),
        ("вторая", "2"),
        ("второе", "2"),
        ("втораго", "2"),
        ("2-я", "2"),
        ("2-е", "2"),
        ("третья", "3"),
        ("третье", "3"),
        ("3-я", "3"),
        ("3-е", "3"),
        ("четвёртая", "4"),
        ("четвертая", "4"),
        ("четвёртое", "4"),
        ("четвертое", "4"),
        ("4-я", "4"),
        ("4-е", "4"),
    ] {
        if let Some(rest) = low.strip_prefix(word) {
            let rest = rest.trim_start_matches([' ', '.']);
            for r in [rest, rest.trim_start_matches("книга ").trim_start()] {
                if !r.is_empty() {
                    out.push(format!("{digit} {r}"));
                }
            }
        }
    }
    out
}

/// Книга по ShortName/FullName через каталог имён (все профили).
/// ShortName в модулях BibleQuote — список псевдонимов через пробел
/// («Быт. Быт Бт. … Genesis»): пробуем целиком и по токенам.
/// Строгое сопоставление — имя целиком (включая варианты с цифрами).
fn book_by_name_strict(cat: &BookCatalog, name: &str) -> Option<BookCode> {
    for p in NameProfile::ALL {
        for v in name_variants(name) {
            if let Some(b) = cat.lookup(p, &v) {
                return Some(b.code);
            }
        }
    }
    None
}

/// Свободное — по токенам списка псевдонимов.
fn book_by_name_tokens(cat: &BookCatalog, name: &str) -> Option<BookCode> {
    for p in NameProfile::ALL {
        for tok in name.split_whitespace() {
            if let Some(b) = cat.lookup(p, tok) {
                return Some(b.code);
            }
        }
    }
    None
}

/// Книга по именам секции: строго FullName → строго ShortName →
/// токены ShortName → токены FullName. Строгий FullName важен:
/// «Первая книга Царств» — 1-я Самуила (синод.), а не 3-я Царств.
fn book_by_name(cat: &BookCatalog, short: &str, full: &str) -> Option<BookCode> {
    book_by_name_strict(cat, full)
        .or_else(|| book_by_name_strict(cat, short))
        .or_else(|| book_by_name_tokens(cat, short))
        .or_else(|| book_by_name_tokens(cat, full))
}

/// Номер стиха в начале текста: «12 текст…» или `<sup>12</sup>текст`.
/// Возвращает номер и остаток текста стиха.
fn verse_number(text: &str, fallback: u16) -> (u16, &str) {
    let mut t = text.trim_start();
    // `<sup>N</sup>` — частый вид номера стиха в модулях BibleQuote.
    if let Some(rest) = t.strip_prefix("<sup>").or_else(|| t.strip_prefix("<SUP>"))
        && let Some((n, r)) = rest
            .split_once("</sup>")
            .or_else(|| rest.split_once("</SUP>"))
        && let Ok(v) = n.trim().parse::<u16>()
    {
        t = r;
        return (v, t);
    }
    let d: String = t.chars().take_while(|c| c.is_ascii_digit()).collect();
    if d.is_empty() {
        (fallback, t)
    } else {
        // VerseSign «<sup>» оставляет «N</sup>текст» — закрывающий
        // тег после цифр снимаем.
        let rest = &t[d.len()..];
        let rest = rest
            .strip_prefix("</sup>")
            .or_else(|| rest.strip_prefix("</SUP>"))
            .unwrap_or(rest);
        (d.parse().unwrap_or(fallback), rest)
    }
}

/// Глава из html-стихов: знак стиха разбивает текст, номер в начале
/// стиха. `strong` — принимать `<S>N</S>` (StrongNumbers=Y).
fn chapter_verses(text: &str, verse_sign: &str, strong: bool, ot: bool) -> Vec<Block> {
    let chunks: Vec<&str> = if verse_sign.is_empty() {
        // Без знака — стих на строку.
        text.lines().collect()
    } else {
        text.split(verse_sign).skip(1).collect()
    };
    let mut out: Vec<Block> = Vec::new();
    let mut seq = 0u16;
    for chunk in chunks {
        let (n, body) = verse_number(chunk, seq + 1);
        seq = n.max(seq + 1);
        let mut blocks = mybible::verse_html_blocks(
            body,
            if strong {
                if ot { "H" } else { "G" }
            } else {
                ""
            },
        );
        if blocks.is_empty() {
            blocks.push(Block {
                marker: "p".into(),
                spans: vec![],
            });
        }
        blocks[0].spans.insert(0, Span::Verse(n));
        out.extend(blocks);
    }
    out
}

/// Разобрать модуль BibleQuote (каталог или .zip) в книги ядра.
/// Для Библии (`Bible=Y`) — текст с главами/стихами; для комментария
/// (`Bible=N`) см. `parse_commentary_dir`.
pub fn parse_dir(path: &Path) -> Result<Vec<usfm::Book>, usfm::Error> {
    let mut src = Source::open(path)?;
    let ini_bytes = src.bytes("bibleqt.ini")?;
    let ini = Ini::parse(&decode(&ini_bytes));

    if ini
        .get("bible")
        .is_some_and(|v| v.eq_ignore_ascii_case("n"))
    {
        return parse_commentary_dir(path);
    }

    let chapter_sign = ini.get("chaptersign").unwrap_or("<p>").to_string();
    let verse_sign = ini.get("versesign").unwrap_or("").to_string();
    let strong = ini
        .get("strongnumbers")
        .is_some_and(|v| v.eq_ignore_ascii_case("y") || v == "1");
    let cat = BookCatalog::builtin();

    let mut books: Vec<usfm::Book> = Vec::new();
    for (i, sec) in ini.book_sections().iter().enumerate() {
        let path_name = sec
            .get("pathname")
            .ok_or_else(|| err(format!("книга {}: нет PathName", i + 1)))?;
        let full = sec.get("fullname").cloned().unwrap_or_default();
        let short = sec.get("shortname").cloned().unwrap_or_default();
        let code = book_by_name(cat, &short, &full).ok_or_else(|| {
            err(format!(
                "неизвестная книга «{full}»/{short} (PathName {path_name})"
            ))
        })?;
        let chapter_qty: u16 = sec
            .get("chapterqty")
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);

        // Текст книги: один файл или каталог файлов глав.
        let mut parts: Vec<String> = Vec::new();
        let dir = path_name.trim_end_matches(['/', '\\']);
        let listed = src.list(dir);
        if !listed.is_empty() && src.bytes(dir).is_err() {
            for (_, b) in listed {
                parts.push(decode(&b));
            }
        } else {
            parts.push(decode(&src.bytes(dir)?));
        }

        // Главы: знак главы разбивает текст книги; если знака нет —
        // файл/часть книги это одна глава (главы по файлам каталога).
        let mut chs: Vec<Chapter> = Vec::new();
        for part in &parts {
            if chapter_sign.is_empty() || !part.contains(&chapter_sign) {
                chs.push(Chapter {
                    number: (chs.len() + 1) as u16,
                    blocks: chapter_verses(part, &verse_sign, strong, code_ot(code)),
                });
            } else {
                for piece in part.split(&chapter_sign).skip(1) {
                    chs.push(Chapter {
                        number: (chs.len() + 1) as u16,
                        blocks: chapter_verses(piece, &verse_sign, strong, code_ot(code)),
                    });
                }
            }
        }
        if chapter_qty > 0 {
            chs.truncate(chapter_qty as usize);
        }
        let mut book = usfm::Book {
            code,
            ..usfm::Book::default()
        };
        book.header.insert("id".into(), code.as_str().to_string());
        if !full.is_empty() {
            book.header.insert("h".into(), full.clone());
            book.header.insert("toc1".into(), full);
        }
        if !short.is_empty() {
            book.header.insert("toc3".into(), short);
        }
        book.chapters = chs;
        books.push(book);
    }
    if books.is_empty() {
        return Err(err("в bibleqt.ini нет секций книг"));
    }
    Ok(books)
}

/// Книга ≤ MAL (<= 460 по MyBible / по канону < MAT) — Ветхий Завет.
fn code_ot(code: BookCode) -> bool {
    BookCatalog::builtin()
        .by_code(code)
        .is_some_and(|b| b.order(studybible_core::book::BookOrder::List).unwrap_or(0) < 40)
}

/// Начало секции комментария после тега/перевода строки:
/// «Стихи 1-5», «Стих 3», «Verses 1-5» → первый стих диапазона.
fn marker_number(t: &str) -> Option<u16> {
    let t = t.trim_start();
    let low = t.to_lowercase();
    for pat in ["стихи", "стих", "verses", "verse"] {
        if low.starts_with(pat) {
            let rest = &t[pat.len()..];
            let d: String = rest
                .trim_start_matches([' ', '.', ':', '\t'])
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if let Ok(n) = d.parse::<u16>() {
                return Some(n);
            }
        }
    }
    None
}

/// Маркеры секций комментария в тексте главы: позиции заголовков
/// «Стихи a-b» / «Стих a» — после тега `<h*>` или начала строки.
fn commentary_markers(text: &str) -> Vec<(u16, usize)> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'<' => {
                let mut end = text[i..]
                    .find('>')
                    .map(|e| i + e + 1)
                    .unwrap_or(bytes.len());
                // Маркер может быть вложен: «<p><b>Стихи 1-2</b>» —
                // пропускаем подряд идущие теги и пробелы.
                loop {
                    let rest = &text[end..];
                    let rest = rest.trim_start();
                    let off = text.len() - rest.len();
                    if rest.starts_with('<') {
                        match rest.find('>') {
                            Some(e) => end = off + e + 1,
                            None => break,
                        }
                    } else {
                        end = off;
                        break;
                    }
                }
                let rest = &text[end..];
                if let Some(n) = marker_number(rest) {
                    out.push((n, i));
                }
                i = end;
            }
            b'\n' => {
                if let Some(n) = marker_number(&text[i + 1..]) {
                    out.push((n, i));
                }
                i += 1;
            }
            _ => i += 1,
        }
    }
    out
}

/// Комментарий BibleQuote (`Bible=N`): текст главы режется на секции
/// по маркерам «Стихи a-b», каждая привязывается к первому стиху.
pub fn parse_commentary_dir(path: &Path) -> Result<Vec<usfm::Book>, usfm::Error> {
    let mut src = Source::open(path)?;
    let ini_bytes = src.bytes("bibleqt.ini")?;
    let ini = Ini::parse(&decode(&ini_bytes));
    let chapter_sign = ini.get("chaptersign").unwrap_or("<h4>").to_string();
    let chapter_zero = ini
        .get("chapterzero")
        .is_some_and(|v| v.eq_ignore_ascii_case("y"));
    let cat = BookCatalog::builtin();

    let mut books: Vec<usfm::Book> = Vec::new();
    for (i, sec) in ini.book_sections().iter().enumerate() {
        let Some(path_name) = sec.get("pathname") else {
            continue;
        };
        let full = sec.get("fullname").cloned().unwrap_or_default();
        let short = sec.get("shortname").cloned().unwrap_or_default();
        let Some(code) = book_by_name(cat, &short, &full) else {
            return Err(err(format!("неизвестная книга «{full}»/{short}")));
        };
        let dir = path_name.trim_end_matches(['/', '\\']);
        let mut parts: Vec<String> = Vec::new();
        let listed = src.list(dir);
        if !listed.is_empty() && src.bytes(dir).is_err() {
            for (_, b) in listed {
                parts.push(decode(&b));
            }
        } else {
            parts.push(decode(&src.bytes(dir)?));
        }

        // (глава, стих) → абзацы комментария; две секции на один
        // стих (встречается в источнике) склеиваются в одну запись.
        let mut by_ch: BTreeMap<u16, BTreeMap<u16, Vec<String>>> = BTreeMap::new();
        // Предисловие книги (ChapterZero) → первую секцию первой главы.
        let mut pending_intro: Option<String> = None;
        for part in &parts {
            // Разбиение на части по ChapterSign. Кусок, начинающийся
            // маркером секции («Стихи a-b»), — не глава, а продолжение
            // предыдущей (случай общего тега для глав и секций, «<h4>»).
            let raw: Vec<String> = if chapter_sign.is_empty() || !part.contains(&chapter_sign) {
                vec![part.clone()]
            } else {
                part.split(&chapter_sign)
                    .skip(1)
                    .map(|s| format!("{chapter_sign}{s}"))
                    .collect()
            };
            let mut chs: Vec<String> = Vec::new();
            for c in raw {
                let mut j = c.find('>').map(|i| i + 1).unwrap_or(0);
                // Пропустить подряд идущие теги и пробелы.
                loop {
                    let rest = c[j..].trim_start();
                    j = c.len() - rest.len();
                    if rest.starts_with('<') {
                        match rest.find('>') {
                            Some(e) => j += e + 1,
                            None => break,
                        }
                    } else {
                        break;
                    }
                }
                if marker_number(&c[j..]).is_some() && !chs.is_empty() {
                    chs.last_mut().unwrap().push_str(&c);
                } else {
                    chs.push(c);
                }
            }
            // ChapterZero=Y: первая часть — предисловие к книге
            // (без собственной главы); дописываем её в первую секцию
            // первой главы, как делал gen_henry.py для comm-henry.sb.
            if chapter_zero && chs.len() > 1 {
                let intro = mybible::strip_tags(&chs.remove(0));
                if !intro.is_empty() {
                    pending_intro = Some(intro);
                }
            }
            let base = by_ch.keys().next_back().copied().unwrap_or(0);
            for (ci, piece) in chs.iter().enumerate() {
                let ch_n = base + ci as u16 + 1;
                let marks = commentary_markers(piece);
                if marks.is_empty() {
                    // Без маркеров — весь кусок к стиху 0? Пропускаем:
                    // комментарии обязаны иметь привязку.
                    continue;
                }
                for (mi, (v, at)) in marks.iter().enumerate() {
                    let end = marks.get(mi + 1).map(|m| m.1).unwrap_or(piece.len());
                    let mut t = mybible::strip_tags(&piece[*at..end]);
                    if let Some(intro) = pending_intro.take() {
                        t = format!("{intro} {t}");
                    }
                    if !t.is_empty() {
                        by_ch
                            .entry(ch_n)
                            .or_default()
                            .entry(*v)
                            .or_default()
                            .push(t);
                    }
                }
            }
        }

        let mut book = usfm::Book {
            code,
            ..usfm::Book::default()
        };
        book.header.insert("id".into(), code.as_str().to_string());
        if !full.is_empty() {
            book.header.insert("h".into(), full);
        }
        for (ch_n, verses) in by_ch {
            let mut ch = Chapter {
                number: ch_n,
                blocks: vec![],
            };
            for (v, texts) in verses {
                ch.blocks.push(Block {
                    marker: "p".into(),
                    spans: vec![
                        Span::Verse(v),
                        Span::Text {
                            text: format!("{} ", texts.join(" ")),
                            style: String::new(),
                            attrs: String::new(),
                        },
                    ],
                });
            }
            book.chapters.push(ch);
        }
        books.push(book);
        let _ = i;
    }
    if books.is_empty() {
        return Err(err("в bibleqt.ini нет секций книг"));
    }
    Ok(books)
}
