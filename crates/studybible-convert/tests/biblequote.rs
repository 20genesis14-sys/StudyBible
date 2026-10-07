//! Тесты конвертера BibleQuote: фикстуры bibleqt.ini + htm в temp-каталоге,
//! кодировка cp1251.

use encoding_rs::WINDOWS_1251;
use std::io::Write;
use studybible_convert::biblequote;
use studybible_core::text::Span;

/// Записать текстовый файл в cp1251.
fn write1251(dir: &std::path::Path, name: &str, text: &str) {
    let (b, _, _) = WINDOWS_1251.encode(text);
    std::fs::write(dir.join(name), b).unwrap();
}

fn bq_dir() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let ini = "BibleName = Тестовый модуль\n\
               BibleShortName = TST\n\
               Bible = Y\n\
               ChapterSign = <h4>\n\
               VerseSign = <sup>\n\
               StrongNumbers = Y\n\
               BookQty = 2\n\
               \n\
               [Бытие]\n\
               PathName = first.htm\n\
               FullName = Бытие\n\
               ShortName = Быт\n\
               ChapterQty = 2\n\
               \n\
               [От Иоанна]\n\
               PathName = jhn.htm\n\
               FullName = Евангелие от Иоанна\n\
               ShortName = Ин\n\
               ChapterQty = 1\n";
    write1251(dir.path(), "bibleqt.ini", ini);
    write1251(
        dir.path(),
        "first.htm",
        "<h4>Глава 1</h4>\n<sup>1</sup>В начале<S>1254</S> сотворил <i>Бог</i> небо.\n\
         <sup>2</sup>Земля же была пуста.\n<h4>Глава 2</h4>\n<sup>1</sup>Источник.\n",
    );
    write1251(
        dir.path(),
        "jhn.htm",
        "<h4>Глава 1</h4>\n<sup>1</sup>В начале было Слово<S>3056</S>.\n",
    );
    dir
}

#[test]
fn parses_cp1251_books_strong() {
    let dir = bq_dir();
    let books = biblequote::parse_dir(dir.path()).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[1].code.as_str(), "JHN");
    let first = &books[0];
    assert_eq!(first.chapters.len(), 2);
    assert!(first.verse_text(1, 1).unwrap().contains("сотворил"));
    assert!(first.verse_text(1, 2).unwrap().contains("пуста"));
    // <S>1254</S> после «начале» → strong H (ВЗ), у JHN — G.
    let mut h = false;
    let mut g = false;
    for b in &first.chapters[0].blocks {
        for s in &b.spans {
            if let Span::Text { style, attrs, text } = s
                && style == "w"
                && text.contains("начале")
                && attrs.contains("H1254")
            {
                h = true;
            }
        }
    }
    for b in &books[1].chapters[0].blocks {
        for s in &b.spans {
            if let Span::Text { style, attrs, .. } = s
                && style == "w"
                && attrs.contains("G3056")
            {
                g = true;
            }
        }
    }
    assert!(h && g);
}

/// Тот же модуль, упакованный в .zip: Source::Zip читает ini и htm.
#[test]
fn parses_zip_module() {
    let dir = tempfile::tempdir().unwrap();
    let src = bq_dir();
    let zip_path = dir.path().join("mod.zip");
    let f = std::fs::File::create(&zip_path).unwrap();
    let mut z = zip::ZipWriter::new(f);
    let opt = zip::write::SimpleFileOptions::default();
    for name in ["bibleqt.ini", "first.htm", "jhn.htm"] {
        z.start_file(name, opt).unwrap();
        z.write_all(&std::fs::read(src.path().join(name)).unwrap())
            .unwrap();
    }
    z.finish().unwrap();

    let books = biblequote::parse_dir(&zip_path).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[0].verse_text(1, 2).unwrap(), "Земля же была пуста.");
}

/// UTF-8 с BOM и cp1251 без BOM определяются автоматически.
#[test]
fn encoding_utf8_bom_vs_cp1251() {
    let ini = "BibleName = Модуль\nBible = Y\nChapterSign = <h4>\nVerseSign = <sup>\nBookQty = 1\n\n\
               [Бытие]\nPathName = g.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 1\n";
    let htm = "<h4>1</h4>\n<sup>1</sup>Текст стиха.\n";

    // UTF-8 с BOM: ini и htm.
    let dir_utf = tempfile::tempdir().unwrap();
    let mut bom = b"\xef\xbb\xbf".to_vec();
    bom.extend_from_slice(ini.as_bytes());
    std::fs::write(dir_utf.path().join("bibleqt.ini"), &bom).unwrap();
    let mut bom2 = b"\xef\xbb\xbf".to_vec();
    bom2.extend_from_slice(htm.as_bytes());
    std::fs::write(dir_utf.path().join("g.htm"), &bom2).unwrap();
    let books = biblequote::parse_dir(dir_utf.path()).unwrap();
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[0].verse_text(1, 1).unwrap(), "Текст стиха.");

    // cp1251 без BOM (не валидный UTF-8 → windows-1251).
    let dir_1251 = tempfile::tempdir().unwrap();
    write1251(dir_1251.path(), "bibleqt.ini", ini);
    write1251(dir_1251.path(), "g.htm", htm);
    let books = biblequote::parse_dir(dir_1251.path()).unwrap();
    assert_eq!(books[0].verse_text(1, 1).unwrap(), "Текст стиха.");
}

/// BibleQuote 7: книги — повторяющиеся группы ключей без [секций]
/// (новая книга — от каждого PathName), как у реального Генри.
#[test]
fn ini7_key_groups() {
    let dir = tempfile::tempdir().unwrap();
    write1251(
        dir.path(),
        "bibleqt.ini",
        "BibleName = Ini7\nBible = Y\nChapterSign = <h4>\nVerseSign = <sup>\nBookQty = 2\n\n\
         PathName = g.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 1\n\n\
         PathName = j.htm\nFullName = Евангелие от Иоанна\nShortName = Ин\nChapterQty = 1\n",
    );
    write1251(dir.path(), "g.htm", "<h4>1</h4><sup>1</sup>Первая книга.");
    write1251(
        dir.path(),
        "j.htm",
        "<h4>1</h4><sup>1</sup>Последняя книга.",
    );
    let books = biblequote::parse_dir(dir.path()).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[1].code.as_str(), "JHN");
}

/// ChapterZero=Y: предисловие книги дописывается в первую секцию
/// первой главы, а не теряется.
#[test]
fn commentary_chapter_zero_intro() {
    let dir = tempfile::tempdir().unwrap();
    write1251(
        dir.path(),
        "bibleqt.ini",
        "BibleName = Комментарий\nBible = N\nChapterSign = <h4>\nChapterZero = Y\nBookQty = 1\n\n\
         [Бытие]\nPathName = g.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 1\n",
    );
    write1251(
        dir.path(),
        "g.htm",
        "<h4>Предисловие</h4>Слово введения.\n<h4>Глава 1</h4>\n<h4>Стих 1</h4>Комментарий.",
    );
    let books = biblequote::parse_commentary_dir(dir.path()).unwrap();
    let ch = &books[0].chapters[0];
    assert_eq!(ch.number, 1);
    let t = ch.verse_text(1).unwrap();
    assert!(t.contains("введения"), "{t:?}");
    assert!(t.contains("Комментарий"), "{t:?}");
}

/// Английские маркеры секций «Verses a-b» / «Verse a» — как русские.
#[test]
fn commentary_english_markers() {
    let dir = tempfile::tempdir().unwrap();
    write1251(
        dir.path(),
        "bibleqt.ini",
        "BibleName = Commentary\nBible = N\nChapterSign = <h4>\nBookQty = 1\n\n\
         [Genesis]\nPathName = g.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 1\n",
    );
    write1251(
        dir.path(),
        "g.htm",
        "<h4>Chapter 1</h4>\n<h4>Verses 1-5</h4>English comment.\n<h4>Verse 6</h4>Sixth.",
    );
    let books = biblequote::parse_commentary_dir(dir.path()).unwrap();
    let ch = &books[0].chapters[0];
    assert!(ch.verse_text(1).unwrap().contains("English comment"));
    assert!(ch.verse_text(6).unwrap().contains("Sixth"));
}

#[test]
fn unknown_book_is_error() {
    let dir = tempfile::tempdir().unwrap();
    write1251(
        dir.path(),
        "bibleqt.ini",
        "Bible = Y\nChapterSign = <h4>\nVerseSign = <sup>\nBookQty = 1\n\n\
         [Книга]\nPathName = x.htm\nFullName = Книга Неизвестная\nShortName = КН\nChapterQty = 1\n",
    );
    write1251(dir.path(), "x.htm", "<h4>1</h4><sup>1</sup>текст");
    let e = biblequote::parse_dir(dir.path()).unwrap_err();
    assert!(e.0.contains("Книга Неизвестная"), "{e}");
}

#[test]
fn commentary_sections_to_first_verse() {
    let dir = tempfile::tempdir().unwrap();
    write1251(
        dir.path(),
        "bibleqt.ini",
        "BibleName = Комментарий\nBible = N\nChapterSign = <h4>\nBookQty = 1\n\n\
         [Бытие]\nPathName = first.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 1\n",
    );
    write1251(
        dir.path(),
        "first.htm",
        "<h4>Глава 1</h4>\n<h4>Стихи 1-5</h4>Комментарий к первым пяти.\n\
         <h4>Стих 6</h4>Комментарий к шестому.\n",
    );
    let books = biblequote::parse_commentary_dir(dir.path()).unwrap();
    assert_eq!(books.len(), 1);
    let ch = &books[0].chapters[0];
    assert!(matches!(ch.blocks[0].spans[0], Span::Verse(1)));
    assert!(ch.verse_text(1).unwrap().contains("первым пяти"));
    assert!(ch.verse_text(6).unwrap().contains("шестому"));
}

/// Реальный модуль Генри (скачанный zip BibleQuote-Modules):
/// 66 книг, без дублей кодов и повторных стихов в главе.
/// SKIPPED, если источника нет.
#[test]
fn henry_zip_real() {
    let p =
        std::path::Path::new(r"D:\StudyBible-data\sources\biblequote\Commentary_Russian_Henry.zip");
    if !p.exists() {
        eprintln!("SKIPPED: нет {p:?}");
        return;
    }
    let books = biblequote::parse_commentary_dir(p).unwrap();
    assert_eq!(books.len(), 66);
    let mut seen_codes = std::collections::BTreeSet::new();
    let mut records = 0usize;
    for b in &books {
        assert!(seen_codes.insert(b.code), "дубль книги {}", b.code.as_str());
        for ch in &b.chapters {
            let mut seen = std::collections::BTreeSet::new();
            for blk in &ch.blocks {
                for s in &blk.spans {
                    if let Span::Verse(v) = s {
                        records += 1;
                        assert!(
                            seen.insert(*v),
                            "дубль {}:{}:{}",
                            b.code.as_str(),
                            ch.number,
                            v
                        );
                    }
                }
            }
        }
    }
    eprintln!("Henry: {records} записей");
    assert_eq!(records, 4248, "число комментариев-записей Генри");
}
