//! Испытательные наборы Этапа 0, которым нужны файлы: список канона пользователя
//! и тексты Библии из `STUDYBIBLE_DATA` (по умолчанию `../StudyBible-data`).
//! Проверки по текстам пропускаются с сообщением, если каталога нет.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use studybible_convert::usfm;
use studybible_core::{BookCatalog, BookCode, VerseKey, Versification};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

pub fn texts_dir() -> Option<PathBuf> {
    let dir = std::env::var_os("STUDYBIBLE_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo().join("../StudyBible-data"))
        .join("sources");
    if dir.is_dir() {
        Some(dir)
    } else {
        eprintln!("SKIPPED: нет каталога текстов {}", dir.display());
        None
    }
}

fn vrs(name: &str) -> &'static Versification {
    Versification::builtin(name).unwrap()
}

fn tsv(rel: &str) -> Vec<Vec<String>> {
    let text = fs::read_to_string(repo().join("data").join(rel)).unwrap();
    text.lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.split('\t').map(String::from).collect())
        .collect()
}

/// Книги перевода: код → разобранный USFM.
fn load(dir: &Path, id: &str) -> HashMap<BookCode, usfm::Book> {
    fs::read_dir(dir.join(id))
        .unwrap()
        .filter_map(|e| {
            let p = e.unwrap().path();
            (p.extension()? == "usfm").then_some(p)
        })
        .map(|p| {
            let book = usfm::parse(&fs::read_to_string(&p).unwrap()).unwrap();
            (book.code, book)
        })
        .collect()
}

fn verse(books: &HashMap<BookCode, usfm::Book>, k: VerseKey) -> String {
    books[&k.book]
        .verse_text(k.chapter, k.verse)
        .unwrap_or_default()
}

#[test]
fn books_profile_matches_user_list() {
    let cat = BookCatalog::builtin();
    let md = fs::read_to_string(repo().join("data/canon/canon-66-knig.md")).unwrap();
    let mut seen = 0;
    for line in md
        .lines()
        .filter(|l| l.starts_with("| ") && l[2..].starts_with(|c: char| c.is_ascii_digit()))
    {
        let c: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        let n: u16 = c[0].parse().unwrap();
        let b = cat
            .books()
            .iter()
            .find(|b| b.order_list == Some(n))
            .unwrap_or_else(|| panic!("нет книги № {n}"));
        assert!(b.canonical, "{line}");
        use studybible_core::NameProfile::*;
        assert_eq!(
            (b.abbr(Alt), b.name(Alt), b.name(Synodal)),
            (c[1], c[2], c[3]),
            "{line}"
        );
        seen += 1;
    }
    assert_eq!(seen, 66);
    assert_eq!(cat.books().iter().filter(|b| !b.canonical).count(), 12);
}

#[test]
fn noncanonical_entries_exist_in_rso() {
    let cat = BookCatalog::builtin();
    let rso = vrs("rso");
    for row in tsv("profiles/noncanonical.tsv") {
        assert_eq!(row[1], "rso");
        match row[0].as_str() {
            "book" => {
                let code = BookCode::new(&row[2]).unwrap();
                assert!(!cat.by_code(code).unwrap().canonical, "{}", row[2]);
                assert!(rso.has_book(code), "в rso нет {}", row[2]);
            }
            "range" => {
                let (start, end) = row[2].split_once('-').unwrap();
                let s = VerseKey::parse(start).unwrap();
                let e = VerseKey::parse(&format!("{} {end}", s.book)).unwrap();
                assert!(rso.contains(s) && rso.contains(e), "в rso нет {}", row[2]);
            }
            "todo" => {}
            k => panic!("неизвестный вид {k}"),
        }
    }
}

#[test]
fn versification_fixture_matches_texts() {
    let Some(dir) = texts_dir() else { return };
    let (syn, kjv) = (load(&dir, "russyn"), load(&dir, "eng-kjv2006"));
    for r in tsv("tests/versification.tsv") {
        let s = verse(&syn, VerseKey::parse(&r[1]).unwrap());
        assert!(s.starts_with(&r[4]), "russyn {}: «{s}»", r[1]);
        let k = verse(&kjv, VerseKey::parse(&r[3]).unwrap());
        assert!(
            k.trim_start_matches(['¶', ' ']).starts_with(&r[5]),
            "KJV {}: «{k}»",
            r[3]
        );
    }
}

/// eBible russyn следует rsc, кроме Нав 24 и Притч 4, 13, где стоят вставки из Септуагинты по rso.
#[test]
fn russyn_follows_rsc_except_lxx_insertions() {
    let Some(dir) = texts_dir() else { return };
    let (rsc, rso) = (vrs("rsc"), vrs("rso"));
    let mut deviations = BTreeSet::new();
    for (code, book) in load(&dir, "russyn") {
        let sizes = book.chapter_sizes();
        assert_eq!(
            Some(sizes.len() as u16),
            rsc.chapter_count(code),
            "{code}: число глав"
        );
        for (i, &n) in sizes.iter().enumerate() {
            let c = i as u16 + 1;
            if Some(n) != rsc.last_verse(code, c) {
                assert_eq!(
                    Some(n),
                    rso.last_verse(code, c),
                    "{code} {c}: не rsc и не rso"
                );
                deviations.insert((code.to_string(), c));
            }
        }
    }
    let expected = [("JOS", 24), ("PRO", 4), ("PRO", 13)].map(|(b, c)| (b.to_string(), c));
    assert_eq!(deviations, BTreeSet::from(expected));
}
