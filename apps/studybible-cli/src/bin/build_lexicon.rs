//! Сборка лексикона ударений `lexicon.tsv.gz` (ADR 0017 «Фронтенд
//! языка»): пересечение словаря RUAccent `accents.json.gz` со
//! словоформами русских модулей .sb; омографы исключаются — их
//! разрешает нейросеть.
//!
//!   build_lexicon <accents.json.gz> <omographs.json.gz> <out.tsv.gz> <модуль.sb>...
//!
//! Из модулей берутся только русские (`meta.language` = ru) и только
//! Библии (`meta.kind` пуст/bible). Выход: `слово<TAB>с_ударением`
//! (U+0301 после ударной гласной), gzip, UTF-8, сортировка.

use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::{BufWriter, Read, Write};

use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use serde_json::Value;
use studybible_store::Module;

const VOWELS: &str = "аеёиоуыэюя";

/// Кириллические буквы (включая ё) и U+0301 — символ слова.
fn is_word_char(c: char) -> bool {
    c == '\u{0301}' || ('\u{0400}'..='\u{04FF}').contains(&c)
}

/// Словоформы модуля: строчные кириллические слова из текстовых
/// спанов всех глав, U+0301 снимается.
fn module_words(m: &Module, out: &mut HashSet<String>) -> rusqlite::Result<()> {
    let mut st = m.conn().prepare("SELECT text FROM spans WHERE kind='t'")?;
    let rows = st.query_map([], |r| r.get::<_, String>(0))?;
    let mut w = String::new();
    for r in rows {
        for c in r?.to_lowercase().chars() {
            if is_word_char(c) {
                w.push(c);
            } else {
                if !w.is_empty() {
                    out.insert(w.trim_matches('\u{0301}').replace('\u{0301}', ""));
                }
                w.clear();
            }
        }
        if !w.is_empty() {
            out.insert(w.trim_matches('\u{0301}').replace('\u{0301}', ""));
            w.clear();
        }
    }
    Ok(())
}

fn read_gz_json(path: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let mut s = String::new();
    GzDecoder::new(File::open(path)?).read_to_string(&mut s)?;
    Ok(serde_json::from_str(&s)?)
}

/// «з+емлю» RUAccent («+» перед ударной гласной) → «зе́млю»
/// (U+0301 после неё). None — «+» не один или не перед буквой.
fn to_u301(accented: &str) -> Option<String> {
    if accented.matches('+').count() != 1 {
        return None;
    }
    let i = accented.find('+')?;
    let after = &accented[i + 1..];
    let stressed = after.chars().next()?;
    if !is_word_char(stressed) || stressed == '\u{0301}' {
        return None;
    }
    Some(format!(
        "{}{}\u{0301}{}",
        &accented[..i],
        stressed,
        &after[stressed.len_utf8()..]
    ))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let (accents, omographs, out) = (
        args.next().expect("accents.json.gz"),
        args.next().expect("omographs.json.gz"),
        args.next().expect("out.tsv.gz"),
    );
    let modules: Vec<String> = args.collect();
    assert!(!modules.is_empty(), "нужен хотя бы один модуль .sb");

    let mut words = HashSet::new();
    for path in &modules {
        let m = Module::open(std::path::Path::new(path))?;
        let meta = m.meta();
        let kind = if meta.kind.is_empty() {
            "bible"
        } else {
            &meta.kind
        };
        if !meta.language.starts_with("ru") || kind != "bible" {
            eprintln!("пропуск {} (lang={}, kind={kind})", path, meta.language);
            continue;
        }
        let before = words.len();
        module_words(&m, &mut words)?;
        eprintln!("{}: +{} словоформ", meta.id, words.len() - before);
    }
    eprintln!("всего словоформ: {}", words.len());

    let omographs: HashSet<String> = read_gz_json(&omographs)?
        .as_object()
        .expect("omographs — объект")
        .keys()
        .cloned()
        .collect();

    let accents = read_gz_json(&accents)?;
    let mut lexicon = BTreeMap::new();
    let mut skipped_omo = 0usize;
    let mut skipped_bad = 0usize;
    for (word, v) in accents.as_object().expect("accents — объект") {
        if !words.contains(word) {
            continue;
        }
        if omographs.contains(word) {
            skipped_omo += 1;
            continue;
        }
        // Односложные не берём: ударять их не нужно — речь рубленая.
        if word.chars().filter(|c| VOWELS.contains(*c)).count() <= 1 {
            continue;
        }
        // Несколько вариантов ударения — пропускаем (нейросеть решит).
        let Some(acc) = v.as_str().and_then(to_u301) else {
            skipped_bad += 1;
            continue;
        };
        lexicon.insert(word.clone(), acc);
    }
    eprintln!(
        "лексикон: {} слов (омографов пропущено {skipped_omo}, битых {skipped_bad}); \
         покрытие {}/{} словоформ",
        lexicon.len(),
        words.iter().filter(|w| lexicon.contains_key(*w)).count(),
        words.len(),
    );

    let mut w = GzEncoder::new(BufWriter::new(File::create(&out)?), Compression::default());
    for (k, v) in &lexicon {
        writeln!(w, "{k}\t{v}")?;
    }
    w.finish()?;
    Ok(())
}
