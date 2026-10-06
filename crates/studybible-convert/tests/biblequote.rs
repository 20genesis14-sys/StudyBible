//! Тесты конвертера BibleQuote: фикстуры bibleqt.ini + htm в temp-каталоге,
//! кодировка cp1251.

use encoding_rs::WINDOWS_1251;
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
    for b in &books {
        assert!(seen_codes.insert(b.code), "дубль книги {}", b.code.as_str());
        for ch in &b.chapters {
            let mut seen = std::collections::BTreeSet::new();
            for blk in &ch.blocks {
                for s in &blk.spans {
                    if let Span::Verse(v) = s {
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
}
