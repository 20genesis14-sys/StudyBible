//! Сборка слоя разметки Стронга из `bsb_tables.tsv` (ADR 0025):
//! `kind="layer"`, `features="strongs"` → `<target>-strongs.sb`.
//!
//! Таблица Berean несёт английские спаны в порядке текста перевода
//! (`BSB Sort` — сквозной счётчик, `Heb Sort` — индекс слова оригинала)
//! и классические номера Стронга. Слова слоя адресуются токенизатором
//! `w1` по тексту целевого модуля: спан строки занимает столько
//! индексов, сколько слов `w1` в нём; на каждое слово — своя строка
//! `links` (таблица сама привязанность — «золотая», `conf=10`).
//!
//! Использование:
//!   strongs_layer <bsb_tables.tsv> <цель.sb> <слой.sb>

use std::collections::BTreeMap;
use std::path::Path;

use studybible_core::book::BookCode;
use studybible_store::{Meta, Module, ModuleWriter};

/// Строка таблицы: английский спан + номер(а) Стронга с буквой языка.
struct Row {
    strong: String,
    span: String,
}

/// «Genesis 1:1» → (код книги, глава, стих).
fn parse_ref(s: &str) -> Option<(BookCode, u16, u16)> {
    let (name, cv) = s.trim().rsplit_once(' ')?;
    let (c, v) = cv.split_once(':')?;
    let code = match name {
        "Genesis" => "GEN",
        "Exodus" => "EXO",
        "Leviticus" => "LEV",
        "Numbers" => "NUM",
        "Deuteronomy" => "DEU",
        "Joshua" => "JOS",
        "Judges" => "JDG",
        "Ruth" => "RUT",
        "1 Samuel" => "1SA",
        "2 Samuel" => "2SA",
        "1 Kings" => "1KI",
        "2 Kings" => "2KI",
        "1 Chronicles" => "1CH",
        "2 Chronicles" => "2CH",
        "Ezra" => "EZR",
        "Nehemiah" => "NEH",
        "Esther" => "EST",
        "Job" => "JOB",
        "Psalm" | "Psalms" => "PSA",
        "Proverbs" => "PRO",
        "Ecclesiastes" => "ECC",
        "Song of Songs" | "Song of Solomon" => "SNG",
        "Isaiah" => "ISA",
        "Jeremiah" => "JER",
        "Lamentations" => "LAM",
        "Ezekiel" => "EZK",
        "Daniel" => "DAN",
        "Hosea" => "HOS",
        "Joel" => "JOL",
        "Amos" => "AMO",
        "Obadiah" => "OBA",
        "Jonah" => "JON",
        "Micah" => "MIC",
        "Nahum" => "NAM",
        "Habakkuk" => "HAB",
        "Zephaniah" => "ZEP",
        "Haggai" => "HAG",
        "Zechariah" => "ZEC",
        "Malachi" => "MAL",
        "Matthew" => "MAT",
        "Mark" => "MRK",
        "Luke" => "LUK",
        "John" => "JHN",
        "Acts" => "ACT",
        "Romans" => "ROM",
        "1 Corinthians" => "1CO",
        "2 Corinthians" => "2CO",
        "Galatians" => "GAL",
        "Ephesians" => "EPH",
        "Philippians" => "PHP",
        "Colossians" => "COL",
        "1 Thessalonians" => "1TH",
        "2 Thessalonians" => "2TH",
        "1 Timothy" => "1TI",
        "2 Timothy" => "2TI",
        "Titus" => "TIT",
        "Philemon" => "PHM",
        "Hebrews" => "HEB",
        "James" => "JAS",
        "1 Peter" => "1PE",
        "2 Peter" => "2PE",
        "1 John" => "1JN",
        "2 John" => "2JN",
        "3 John" => "3JN",
        "Jude" => "JUD",
        "Revelation" => "REV",
        _ => return None,
    };
    Some((BookCode::new(code)?, c.parse().ok()?, v.parse().ok()?))
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        return Err("strongs_layer <bsb_tables.tsv> <цель.sb> <слой.sb>".into());
    }

    // Читаем таблицу: (книга, глава, стих) → строки в порядке текста.
    let text = std::fs::read_to_string(&args[0]).map_err(|e| format!("{}: {e}", args[0]))?;
    let mut verses: BTreeMap<(BookCode, u16, u16), Vec<Row>> = BTreeMap::new();
    let mut cur: Option<(BookCode, u16, u16)> = None;
    for line in text.lines().skip(1) {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 19 {
            continue;
        }
        let lang = f[4];
        let num = match lang {
            "Hebrew" => f[10].trim(),
            "Greek" => f[11].trim(),
            _ => "",
        };
        let strong = if num.is_empty() {
            String::new()
        } else {
            let letter = if lang == "Hebrew" { "H" } else { "G" };
            num.split_whitespace()
                .map(|n| format!("{letter}{n}"))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let span = f.get(18).copied().unwrap_or("").to_string();
        // VerseId заполнен только в первой строке стиха — несём
        // текущую координату дальше.
        if let Some(k) = f.get(12).and_then(|r| parse_ref(r)) {
            cur = Some(k);
        }
        let Some(key) = cur else {
            continue;
        };
        // Строки-пустышки (ни спана, ни номера) и маркеры ячеек
        // номера стиха ('vvv') — заполнители таблицы, слов нет.
        let tr = span.trim();
        if strong.is_empty() && tr.is_empty() || tr == "vvv" {
            continue;
        }
        verses.entry(key).or_default().push(Row { strong, span });
    }
    eprintln!(
        "строк таблицы: {}",
        verses.values().map(Vec::len).sum::<usize>()
    );

    let target = Module::open(Path::new(&args[1])).map_err(|e| e.to_string())?;
    let tmeta = target.meta();
    let meta = Meta {
        id: format!("{}-strongs", tmeta.id),
        title: format!("{} — Strong's tagging", tmeta.title),
        language: tmeta.language.clone(),
        direction: tmeta.direction.clone(),
        versification: tmeta.versification.clone(),
        name_profile: tmeta.name_profile.clone(),
        book_order: tmeta.book_order.clone(),
        version: "0.1".into(),
        license: "CC-BY".into(),
        attribution: "Berean Standard Bible interlinear tables (berean.bible)".into(),
        source: "bsb_tables.tsv".into(),
        kind: "layer".into(),
        features: vec!["strongs".into()],
        ..Default::default()
    };
    let out = Path::new(&args[2]);
    // Журнал пропущенных спанов — рядом со слоем, для разбора.
    let mut miss_log = String::new();
    let mut w = ModuleWriter::create(out, &meta).map_err(|e| e.to_string())?;

    // Каталог книг цели — коды из её books-таблицы, чтобы links() слоя
    // резолвился по собственному каталогу.
    let tbooks = target.books().map_err(|e| e.to_string())?;
    for (ord, (code, title)) in tbooks.iter().enumerate() {
        w.add_book(
            *code,
            (ord + 1) as u16,
            title,
            &std::collections::BTreeMap::new(),
        )
        .map_err(|e| e.to_string())?;
    }

    // Группируем строки по главам — chapter() цели читается один раз
    // на главу, не на стих.
    type ChapKey = (BookCode, u16);
    type VerseKey3 = (BookCode, u16, u16);
    let mut by_ch: BTreeMap<ChapKey, Vec<(VerseKey3, &Vec<Row>)>> = BTreeMap::new();
    for (k, rows) in &verses {
        by_ch.entry((k.0, k.1)).or_default().push((*k, rows));
    }
    let mut links = 0u64;
    let mut miss_sync = 0u64; // спан сошёлся не на месте (resync)
    let mut miss_row = 0u64; // спан вообще не нашёлся — пропущен
    let mut miss_tail = 0u64; // спан ушёл за конец стиха
    let mut miss_verse = 0u64;
    for ((book, ch), list) in &by_ch {
        let Some(chapter) = target.chapter(*book, *ch).map_err(|e| e.to_string())? else {
            miss_verse += list.len() as u64;
            continue;
        };
        for ((_, _, vs), rows) in list {
            let Some(text) = chapter.verse_text(*vs) else {
                miss_verse += 1;
                continue;
            };
            let mwords = studybible_core::text::words(&text);
            let mut cursor = 0usize;
            for row in *rows {
                let sw = studybible_core::text::words(&row.span);
                if sw.is_empty() {
                    continue; // слово оригинала без перевода ('-')
                }
                // Позиция первого слова спана: жадный поиск вперёд от курсора
                // (таблица и текст модуля из разных экспортов — расходимся
                // на кавычках/тире/редких правках).
                let want = sw[0].to_lowercase();
                let mut pos = cursor;
                while pos < mwords.len() && mwords[pos].to_lowercase() != want {
                    pos += 1;
                }
                if pos >= mwords.len() {
                    miss_row += 1;
                    miss_log.push_str(&format!(
                        "{}\t{ch}:{vs}\t{}\t{}\n",
                        book.as_str(),
                        row.strong,
                        row.span.trim()
                    ));
                    continue;
                }
                if pos != cursor {
                    miss_sync += 1; // сошлось, но не на месте — заметить
                }
                for (i, _) in sw.iter().enumerate() {
                    let wi = pos + i;
                    if wi >= mwords.len() {
                        miss_tail += 1;
                        break;
                    }
                    if !row.strong.is_empty() {
                        w.add_link(
                            *book,
                            *ch,
                            &studybible_store::Link {
                                verse: *vs,
                                word: wi as u16,
                                r#ref: String::new(),
                                strong: row.strong.clone(),
                                conf: 10,
                                flags: String::new(),
                                source: "bsb_tables".into(),
                            },
                        )
                        .map_err(|e| e.to_string())?;
                        links += 1;
                    }
                }
                cursor = pos + sw.len();
            }
        }
    }
    w.set_meta("target_id", &tmeta.id)
        .map_err(|e| e.to_string())?;
    w.set_meta("target_hash", &tmeta.content_hash)
        .map_err(|e| e.to_string())?;
    w.set_meta("tokenizer", studybible_core::text::WORDS_VERSION)
        .map_err(|e| e.to_string())?;
    w.finish().map_err(|e| e.to_string())?;
    if !miss_log.is_empty() {
        let mf = out.with_extension("misses.tsv");
        std::fs::write(&mf, miss_log).map_err(|e| format!("{}: {e}", mf.display()))?;
        eprintln!("пропуски → {}", mf.display());
    }
    println!(
        "{}: links={links}, стихов без совпадения={miss_verse}, \
         resync={miss_sync}, спанов пропущено={miss_row}, за край={miss_tail}",
        meta.id
    );
    Ok(())
}
