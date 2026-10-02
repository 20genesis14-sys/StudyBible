//! Разбор ссылок — краевые случаи сверх набора data/tests/references.tsv.

use studybible_core::reference::{ParseError, parse};
use studybible_core::{BookCatalog, NameProfile, Versification};

fn cat() -> &'static BookCatalog {
    BookCatalog::builtin()
}

fn syn(s: &str) -> Result<studybible_core::reference::Reference, ParseError> {
    parse(
        s,
        NameProfile::Synodal,
        Versification::builtin("rsc").unwrap(),
        cat(),
    )
}

#[test]
fn spelling_variants() {
    // Регистр, точки и пробелы в названии безразличны.
    assert_eq!(syn("Быт 1:1").unwrap().osis(cat()), "Gen.1.1");
    assert_eq!(syn("быт 1:1").unwrap().osis(cat()), "Gen.1.1");
    assert_eq!(syn("БЫТ. 1:1").unwrap().osis(cat()), "Gen.1.1");
    assert_eq!(syn("Бытие 1:1").unwrap().osis(cat()), "Gen.1.1");
    assert_eq!(syn("  Быт  1 : 1  ").unwrap().osis(cat()), "Gen.1.1");
    // Разделитель глава/стих — точка тоже.
    assert_eq!(syn("Быт 1.1").unwrap().osis(cat()), "Gen.1.1");
    // Длинное тире в диапазоне.
    assert_eq!(syn("Быт 1:1–3").unwrap().osis(cat()), "Gen.1.1-Gen.1.3");
    assert_eq!(syn("Быт 1:1 — 1:3").unwrap().osis(cat()), "Gen.1.1-Gen.1.3");
    // Многословные названия.
    assert_eq!(
        syn("Песнь песней Соломона 1:1").unwrap().osis(cat()),
        "Song.1.1"
    );
    assert_eq!(syn("Песн 1:1").unwrap().osis(cat()), "Song.1.1");
    assert_eq!(syn("1 Кор 3:16").unwrap().osis(cat()), "1Cor.3.16");
    assert_eq!(syn("1Кор.3:16").unwrap().osis(cat()), "1Cor.3.16");
    assert_eq!(syn("Деян 2:38").unwrap().osis(cat()), "Acts.2.38");
}

#[test]
fn whole_book_and_chapters() {
    // Только название книги — вся книга (глава не задана).
    let r = syn("Быт").unwrap();
    assert_eq!(r.start.chapter, None);
    assert_eq!(r.end, None);
    assert_eq!(r.osis(cat()), "Gen");

    // Диапазон глав.
    let r = syn("Мф 5-7").unwrap();
    assert_eq!(r.start.chapter, Some(5));
    assert_eq!(r.end.unwrap().chapter, Some(7));
    assert_eq!(r.osis(cat()), "Matt.5-Matt.7");

    // Глава со стихом до стиха следующей главы.
    let r = syn("Быт 1:31-2:3").unwrap();
    assert_eq!(r.osis(cat()), "Gen.1.31-Gen.2.3");

    // Одноглавые книги: число — стих, не глава.
    assert_eq!(syn("Иуд 5").unwrap().osis(cat()), "Jude.1.5");
    assert_eq!(syn("Иуд 3-6").unwrap().osis(cat()), "Jude.1.3-Jude.1.6");
    assert_eq!(syn("Авд 1:4").unwrap().osis(cat()), "Obad.1.4");
    assert_eq!(syn("2 Ин 8").unwrap().osis(cat()), "2John.1.8");
}

#[test]
fn psalm_shift_rsc_to_org() {
    // Пс 22 по rsc = Пс 23 по org.
    let r = syn("Пс 22:1").unwrap();
    assert_eq!(r.osis(cat()), "Ps.22.1");
    let org = r
        .convert(
            Versification::builtin("rsc").unwrap(),
            Versification::builtin("org").unwrap(),
        )
        .unwrap();
    assert_eq!(org.osis(cat()), "Ps.23.1");

    // Пс 23 org обратно в rsc → Пс 22.
    let r = parse(
        "Ps 23:1",
        NameProfile::English,
        Versification::builtin("org").unwrap(),
        cat(),
    )
    .unwrap();
    let back = r
        .convert(
            Versification::builtin("org").unwrap(),
            Versification::builtin("rsc").unwrap(),
        )
        .unwrap();
    assert_eq!(back.osis(cat()), "Ps.22.1");
}

#[test]
fn verse_bounds_stop_at_a_single_verse() {
    // Точка со стихом — только он. Раньше чтение шло до конца главы.
    assert_eq!(syn("Быт 1:1").unwrap().verse_bounds(1, 1), (1, 1));
    assert_eq!(syn("Иуд 5").unwrap().verse_bounds(1, 1), (5, 5));
    assert_eq!(syn("Быт 1:1-3").unwrap().verse_bounds(1, 1), (1, 3));

    // Глава без стиха и книга целиком — вся глава. `open` = 0 оставляет место надписанию.
    assert_eq!(syn("Быт 1").unwrap().verse_bounds(1, 1), (1, u16::MAX));
    assert_eq!(syn("Быт 1").unwrap().verse_bounds(1, 0), (0, u16::MAX));
    assert_eq!(syn("Быт").unwrap().verse_bounds(1, 1), (1, u16::MAX));
    assert_eq!(syn("Быт").unwrap().verse_bounds(50, 0), (0, u16::MAX));

    // Диапазон через границу главы и диапазон глав.
    let r = syn("Быт 1:31-2:3").unwrap();
    assert_eq!(r.verse_bounds(1, 1), (31, u16::MAX));
    assert_eq!(r.verse_bounds(2, 1), (1, 3));
    let r = syn("Мф 5-7").unwrap();
    assert_eq!(r.verse_bounds(5, 1), (1, u16::MAX));
    assert_eq!(r.verse_bounds(6, 1), (1, u16::MAX));
    assert_eq!(r.verse_bounds(7, 1), (1, u16::MAX));
}

#[test]
fn malformed_references() {
    assert!(matches!(syn(""), Err(ParseError::Empty)));
    assert!(matches!(syn("   "), Err(ParseError::Empty)));
    assert!(syn("Быт").is_ok()); // целая книга — ок
    assert!(matches!(
        syn("Неттакой 1:1"),
        Err(ParseError::UnknownBook(_))
    ));
    assert!(matches!(syn("Быт 0"), Err(ParseError::OutOfRange(_))));
    assert!(matches!(syn("Быт 0:1"), Err(ParseError::OutOfRange(_))));
    assert!(matches!(syn("Быт 1:0"), Err(ParseError::OutOfRange(_))));
    assert!(matches!(syn("Быт 51"), Err(ParseError::OutOfRange(_))));
    assert!(matches!(syn("Быт 1:32"), Err(ParseError::OutOfRange(_))));
    assert!(matches!(syn("Быт 1:2-1"), Err(ParseError::Syntax(_))));
    assert!(matches!(syn("Быт 3-2"), Err(ParseError::Syntax(_))));
    assert!(matches!(syn("Быт 1:"), Err(ParseError::Syntax(_))));
    assert!(syn("Быт :1").is_err()); // двоеточие остаётся в имени → UnknownBook
    assert!(matches!(syn("Быт 1-"), Err(ParseError::Syntax(_))));
    assert!(syn("Быт -1").is_err()); // «-» остаётся в имени → UnknownBook
    assert!(matches!(syn("Быт 1:1-"), Err(ParseError::Syntax(_))));
    assert!(matches!(syn("Быт abc"), Err(ParseError::UnknownBook(_)))); // без цифр — всё имя
    assert!(matches!(syn("Быт 1:1:1"), Err(ParseError::Syntax(_))));
    assert!(matches!(syn("Быт 1,2"), Err(ParseError::Syntax(_))));
    assert!(syn("1Цар").is_ok()); // целая книга — ок
    // Книга не в версификации: Товита нет в протестантской rsc.
    assert!(matches!(
        syn("Тов 1:1"),
        Err(ParseError::BookNotInVersification(_))
    ));
}

#[test]
fn profile_dependent_names() {
    let org = Versification::builtin("org").unwrap();
    // «1Цар» в АЛЬТ — 3Царств канонический? Нет: АЛЬТ «1 Цар.» = 1Kgs.
    let r = parse("1 Цар 1:1", NameProfile::Alt, org, cat()).unwrap();
    assert_eq!(r.osis(cat()), "1Kgs.1.1");
    // То же сокращение в синодальном профиле — 1Sam.
    let r = syn("1Цар 1:1").unwrap();
    assert_eq!(r.osis(cat()), "1Sam.1.1");
    // OSIS/коды работают в любом профиле.
    let r = parse("GEN 1:1", NameProfile::English, org, cat()).unwrap();
    assert_eq!(r.osis(cat()), "Gen.1.1");
    let r = syn("GEN 1:1").unwrap();
    assert_eq!(r.osis(cat()), "Gen.1.1");
}
