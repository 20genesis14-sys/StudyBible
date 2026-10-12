//! Сборка модуля-слоя перекрёстных ссылок OpenBible (ADR 0023):
//! `cross_references.txt` (CC-BY) → `.sb` с `kind="layer"`,
//! `features="xrefs"`. Текст ссылок — языконезависимые OSIS-ссылки
//! (`Ps.104.30-Ps.104.31`), координаты — версификация `eng`.
//!
//! Использование:
//!   xref_layer <cross_references.txt> <слой.sb> [top N]

use std::collections::BTreeMap;
use std::path::Path;

use studybible_core::book::{BookCatalog, BookCode, BookOrder, NameProfile};
use studybible_core::versification::VerseKey;
use studybible_store::{Meta, ModuleWriter};

const TOP_N: usize = 8;

/// «Gen.1.1» → VerseKey (координаты источника — eng).
fn parse_ref(s: &str, cat: &BookCatalog) -> Option<VerseKey> {
    let (book, cv) = s.trim().split_once('.')?;
    let code = cat.by_osis(book)?.code;
    let (c, v) = cv.split_once('.')?;
    Some(VerseKey::new(code, c.parse().ok()?, v.parse().ok()?))
}

/// «Ps.148.4-Ps.148.5» или «Isa.40.28» → пара (начало, конец).
fn parse_to(s: &str, cat: &BookCatalog) -> Option<(VerseKey, VerseKey)> {
    let mut parts = s.trim().splitn(2, '-');
    let a = parse_ref(parts.next()?, cat)?;
    let b = match parts.next() {
        Some(t) => parse_ref(t, cat)?,
        None => a,
    };
    Some((a, b))
}

/// Ссылка в OSIS-аббревиатурах: «Ps 104:30», «Ps 104:30-31»
/// («-» внутри главы), «Obad 1:1 – Jonah 1:1» (через книгу/главу).
/// Формат читается парсером refs.dart (книга + глава:стих).
fn fmt_osis(a: VerseKey, b: VerseKey, cat: &BookCatalog) -> String {
    let os = |k: &VerseKey| cat.by_code(k.book).map(|x| x.osis).unwrap_or("?");
    if a.book == b.book && a.chapter == b.chapter {
        if a.verse == b.verse {
            format!("{} {}:{}", os(&a), a.chapter, a.verse)
        } else {
            format!("{} {}:{}-{}", os(&a), a.chapter, a.verse, b.verse)
        }
    } else {
        format!(
            "{} {}:{} \u{2013} {} {}:{}",
            os(&a),
            a.chapter,
            a.verse,
            os(&b),
            b.chapter,
            b.verse
        )
    }
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        return Err("xref_layer <cross_references.txt> <слой.sb> [top N]".into());
    }
    let top: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(TOP_N);
    let cat = BookCatalog::builtin();

    // Ссылки из файла: from → [(to_start, to_end, votes)].
    let text = std::fs::read_to_string(&args[0]).map_err(|e| format!("{}: {e}", args[0]))?;
    let mut refs: BTreeMap<VerseKey, Vec<(VerseKey, VerseKey, i64)>> = BTreeMap::new();
    for line in text.lines().skip(1) {
        let mut it = line.split('\t');
        let (Some(f), Some(t), Some(v)) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let (Some(fk), Some((ta, tb)), Ok(votes)) =
            (parse_ref(f, cat), parse_to(t, cat), v.trim().parse())
        else {
            continue;
        };
        refs.entry(fk).or_default().push((ta, tb, votes));
    }

    let meta = Meta {
        id: "openbible-xrefs".into(),
        title: "Cross-references".into(),
        language: "en".into(),
        direction: "ltr".into(),
        versification: "eng".into(),
        name_profile: "en".into(),
        book_order: "list".into(),
        version: "1.0".into(),
        license: "CC-BY".into(),
        attribution: "OpenBible.info cross-references".into(),
        source: "https://www.openbible.info/labs/cross-references/".into(),
        kind: "layer".into(),
        features: vec!["xrefs".into()],
        ..Default::default()
    };
    let path = Path::new(&args[1]);
    let mut w =
        ModuleWriter::create(path, &meta).map_err(|e| format!("{}: {e}", path.display()))?;
    // Каталог всех книг: book_id = порядковый номер канона list.
    let ordered = cat.ordered(BookOrder::List);
    for b in &ordered {
        let Some(ord) = b.order(BookOrder::List) else {
            continue;
        };
        w.add_book(b.code, ord, b.name(NameProfile::English), &BTreeMap::new())
            .map_err(|e| e.to_string())?;
    }

    let mut n = 0u64;
    let mut seq: u16 = 0;
    let mut cur: Option<(BookCode, u16)> = None;
    for (fk, mut lst) in refs {
        lst.sort_by_key(|a| std::cmp::Reverse(a.2));
        let texts: Vec<String> = lst
            .iter()
            .take(top)
            .map(|(ta, tb, _)| fmt_osis(*ta, *tb, cat))
            .collect();
        if texts.is_empty() {
            continue;
        }
        // seq — сквозной в пределах (книга, глава): PK spans.
        if cur != Some((fk.book, fk.chapter)) {
            cur = Some((fk.book, fk.chapter));
            seq = 0;
        }
        w.add_xref(fk.book, fk.chapter, fk.verse, seq, &texts.join("; "))
            .map_err(|e| e.to_string())?;
        // Структурные цели (таблица xrefs): те же top-N в координатах.
        w.add_xref_targets(fk.book, fk.chapter, fk.verse, &lst[..top.min(lst.len())])
            .map_err(|e| e.to_string())?;
        seq += 1;
        n += 1;
    }
    w.finish().map_err(|e| e.to_string())?;
    println!("{}: слой параллельных, {n} ссылок-x (top {top})", meta.id);
    Ok(())
}
