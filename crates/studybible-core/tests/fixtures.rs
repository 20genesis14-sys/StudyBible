//! Испытательные наборы `data/tests/` на настоящем коде ядра.

use std::collections::BTreeSet;

use studybible_core::reference::parse;
use studybible_core::{BookCatalog, NameProfile, VerseKey, Versification};

fn rows(tsv: &str) -> Vec<Vec<&str>> {
    tsv.lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.split('\t').collect())
        .collect()
}

fn vrs(name: &str) -> &'static Versification {
    Versification::builtin(name).unwrap_or_else(|| panic!("нет версификации {name}"))
}

#[test]
fn references() {
    let cat = BookCatalog::builtin();
    let org = vrs("org");
    for r in rows(include_str!("../../../data/tests/references.tsv")) {
        let (input, names, v, expect, expect_org) = (r[0], r[1], r[2], r[3], r[4]);
        let profile = match names {
            "syn" => NameProfile::Synodal,
            "alt" => NameProfile::Alt,
            "en" => NameProfile::English,
            n => panic!("профиль {n}"),
        };
        let reference =
            parse(input, profile, vrs(v), cat).unwrap_or_else(|e| panic!("{input}: {e}"));
        assert_eq!(reference.osis(cat), expect, "{input}");
        if expect_org != "-" {
            let converted = reference
                .convert(vrs(v), org)
                .unwrap_or_else(|| panic!("{input}: нет в org"));
            assert_eq!(converted.osis(cat), expect_org, "{input} → org");
        }
    }
}

#[test]
fn versification_mappings() {
    let eng = vrs("eng");
    for r in rows(include_str!("../../../data/tests/versification.tsv")) {
        let v = vrs(r[0]);
        let src = VerseKey::parse(r[1]).unwrap();
        let org: BTreeSet<VerseKey> = r[2]
            .split(',')
            .map(|s| VerseKey::parse(s).unwrap())
            .collect();
        let kjv = VerseKey::parse(r[3]).unwrap();
        assert!(v.contains(src), "{}: нет в {}", r[1], r[0]);
        assert_eq!(
            v.to_org(src).into_iter().collect::<BTreeSet<_>>(),
            org,
            "{} → org",
            r[1]
        );
        assert!(
            eng.to_org(kjv).iter().any(|k| org.contains(k)),
            "KJV {}",
            r[3]
        );
        assert!(
            v.convert(eng, src).contains(&kjv),
            "{} {} → eng {}",
            r[0],
            r[1],
            r[3]
        );
    }
}

#[test]
fn ambiguous_abbreviation_depends_on_profile() {
    let cat = BookCatalog::builtin();
    assert_eq!(
        cat.lookup(NameProfile::Synodal, "1Цар").unwrap().osis,
        "1Sam"
    );
    assert_eq!(cat.lookup(NameProfile::Alt, "1 Цар.").unwrap().osis, "1Kgs");
    assert_eq!(
        cat.lookup(NameProfile::Synodal, "Песнь песней Соломона")
            .unwrap()
            .osis,
        "Song"
    );
    assert_eq!(cat.lookup(NameProfile::English, "GEN").unwrap().osis, "Gen");
}

#[test]
fn errors() {
    let cat = BookCatalog::builtin();
    let rsc = vrs("rsc");
    let p = |s| parse(s, NameProfile::Synodal, rsc, cat);
    assert!(matches!(p(""), Err(studybible_core::ParseError::Empty)));
    assert!(matches!(
        p("Xyz 1:1"),
        Err(studybible_core::ParseError::UnknownBook(_))
    ));
    assert!(matches!(
        p("Ин 22:1"),
        Err(studybible_core::ParseError::OutOfRange(_))
    ));
    assert!(matches!(
        p("Ин 3:99"),
        Err(studybible_core::ParseError::OutOfRange(_))
    ));
    assert!(matches!(
        p("Ин 3:18-16"),
        Err(studybible_core::ParseError::Syntax(_))
    ));
    assert!(matches!(
        p("Тов 1:1"),
        Err(studybible_core::ParseError::BookNotInVersification(_))
    ));
    assert_eq!(
        parse("Тов 1:1", NameProfile::Synodal, vrs("rso"), cat)
            .unwrap()
            .osis(cat),
        "Tob.1.1"
    );
    assert_eq!(p("Иуд 5").unwrap().osis(cat), "Jude.1.5");
}

#[test]
fn canon_and_order() {
    let cat = BookCatalog::builtin();
    let list = cat.ordered(studybible_core::BookOrder::List);
    assert_eq!(list.len(), 66);
    assert!(list.iter().all(|b| b.canonical));
    let syn = cat.ordered(studybible_core::BookOrder::Synodal);
    assert_eq!(syn.len(), 77);
    let pos = |o: &str| syn.iter().position(|b| b.osis == o).unwrap();
    assert!(
        pos("Acts") < pos("Jas") && pos("Jude") < pos("Rom"),
        "соборные послания перед Павловыми"
    );
}
