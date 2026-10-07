//! Версификации — краевые случаи разбора `.vrs` и перевода стихов.

use studybible_core::versification::BUILTIN;
use studybible_core::{BookCode, VerseKey, Versification};

fn k(b: &str, c: u16, v: u16) -> VerseKey {
    VerseKey::new(BookCode::new(b).unwrap(), c, v)
}

#[test]
fn verse_key_parse() {
    assert_eq!(VerseKey::parse("GEN 1:1"), Some(k("GEN", 1, 1)));
    assert_eq!(VerseKey::parse("PSA 89:22"), Some(k("PSA", 89, 22)));
    // Буквенный сегмент отбрасывается.
    assert_eq!(VerseKey::parse("ESG 1:1a"), Some(k("ESG", 1, 1)));
    assert_eq!(VerseKey::parse("GEN 1:1 "), Some(k("GEN", 1, 1)));
    assert_eq!(VerseKey::parse("GEN 1"), None);
    assert_eq!(VerseKey::parse("GEN:1:1"), None);
    assert_eq!(VerseKey::parse("gen 1:1"), None); // коды uppercase
    assert_eq!(VerseKey::parse(""), None);
}

#[test]
fn builtin_all_load() {
    for name in BUILTIN {
        assert!(Versification::builtin(name).is_some(), "{name}");
    }
    assert!(Versification::builtin("неттакой").is_none());
}

#[test]
fn structure_checks() {
    let rsc = Versification::builtin("rsc").unwrap();
    assert_eq!(rsc.chapter_count(k("GEN", 0, 0).book), Some(50));
    assert_eq!(rsc.chapter_count(k("JUD", 0, 0).book), Some(1));
    assert_eq!(rsc.last_verse(k("GEN", 0, 0).book, 1), Some(31));
    assert!(rsc.contains(k("PSA", 150, 6)));
    assert!(!rsc.contains(k("PSA", 150, 7)));
    assert!(!rsc.contains(k("PSA", 151, 1))); // Пс 151 нет в rsc
    // Стих 0 не в диапазоне contains — надписания отдельно.
    assert!(!rsc.contains(k("PSA", 3, 0)));
    // Товита нет в протестантской rsc, есть в rso.
    assert!(!rsc.has_book(k("TOB", 0, 0).book));
    assert!(
        Versification::builtin("rso")
            .unwrap()
            .has_book(k("TOB", 0, 0).book)
    );
}

#[test]
fn mappings() {
    let rsc = Versification::builtin("rsc").unwrap();
    let org = Versification::builtin("org").unwrap();

    // Стих без явного соответствия — тот же номер.
    assert_eq!(rsc.to_org(k("GEN", 1, 1)), vec![k("GEN", 1, 1)]);

    // Пс 22:1 rsc → Пс 23:1 org.
    assert_eq!(rsc.to_org(k("PSA", 22, 1)), vec![k("PSA", 23, 1)]);
    // Обратно: Пс 23:1 org → Пс 22:1 rsc.
    assert_eq!(rsc.from_org(k("PSA", 23, 1)), vec![k("PSA", 22, 1)]);

    // Преобразование rsc → org напрямую.
    assert_eq!(rsc.convert(org, k("PSA", 22, 1)), vec![k("PSA", 23, 1)]);
    // Преобразование в ту же версификацию — идентичность.
    assert_eq!(rsc.convert(rsc, k("GEN", 1, 1)), vec![k("GEN", 1, 1)]);
}

#[test]
fn vul_dag_mappings_fixed() {
    // Вопрос 10: опечатки апстрима vul.vrs исправлены локально
    // (строки помечены «# исправлено StudyBible»).
    let vul = Versification::builtin("vul").unwrap();
    let org = Versification::builtin("org").unwrap();
    // Исправленные соответствия разобраны — в skipped их нет.
    assert!(
        !vul.skipped()
            .iter()
            .any(|s| s.contains("DAG 3:52") || s.contains("DAG 13") || s.contains("DAG 14"))
    );
    // DAG 3:52-53 → S3Y 1:30-31 (Песнь трёх отроков); стих 52
    // входит и в предыдущий диапазон 3:24-52 → S3Y 1:1-29.
    assert_eq!(
        vul.to_org(k("DAG", 3, 52)),
        vec![k("S3Y", 1, 29), k("S3Y", 1, 30)]
    );
    assert_eq!(vul.to_org(k("DAG", 3, 53)), vec![k("S3Y", 1, 31)]);
    // DAG 13 ↔ SUS 1 — постиховое соответствие 1:1-63.
    assert_eq!(vul.to_org(k("DAG", 13, 63)), vec![k("SUS", 1, 63)]);
    // DAN 13 — латинское имя Сусанны, у vul тоже отображается в SUS.
    assert_eq!(
        vul.from_org(k("SUS", 1, 63)),
        vec![k("DAN", 13, 63), k("DAG", 13, 63)]
    );
    // DAG 14 ↔ BEL 1 — 1:1-42.
    assert_eq!(vul.to_org(k("DAG", 14, 42)), vec![k("BEL", 1, 42)]);
    // Сквозная конверсия vul → org не теряет стихи Даниила-греческого.
    assert_eq!(vul.convert(org, k("DAG", 13, 63)), vec![k("SUS", 1, 63)]);
}

#[test]
fn parse_bad_vrs() {
    // Неверные строки в определении — ошибка, а не паника.
    assert!(Versification::parse("x", "NOTACODE 1:31").is_err());
    assert!(Versification::parse("x", "GEN 1:a").is_err());
    // Битое соответствие — не ошибка, а пропуск с записью в `skipped`.
    let bad = Versification::parse("x", "GEN 1:31\nGEN 1:31 = GEN").unwrap();
    assert_eq!(bad.skipped().len(), 1);
    assert!(bad.skipped()[0].contains("GEN 1:31 = GEN"));
    // Комментарии и пустые строки игнорируются.
    let v = Versification::parse("t", "# comment\n\nGEN 1:31 2:25\nPSA 1:6").unwrap();
    assert_eq!(v.last_verse(BookCode::new("GEN").unwrap(), 1), Some(31));
    assert_eq!(v.last_verse(BookCode::new("GEN").unwrap(), 2), Some(25));
    assert_eq!(v.last_verse(BookCode::new("PSA").unwrap(), 1), Some(6));
}
